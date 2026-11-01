import AppKit
import Combine
import Foundation

/// Runs a dictation from key press to typed text:
/// listen → basic cleanup → AI cleanup → type into the focused app → learn from corrections.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case listening
        case processing
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { phaseChangedAt = Date() } }
    }
    private var phaseChangedAt = Date()
    @Published private(set) var level: Double = 0
    @Published private(set) var liveText = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var isHandsFree = false
    @Published private(set) var lastResult = ""
    @Published private(set) var lastError: String?
    /// When set, the result goes here instead of being typed (used by the "Try it" box).
    var testSink: ((String) -> Void)?

    private let appState: AppState
    private let lexicon: LexiconStore
    private let appleEngine = SpeechEngine()
    private let parakeetEngine = ParakeetDictationEngine()
    /// Chosen in Settings; fixed for the length of each dictation.
    private var usingParakeet = false
    private var engine: DictationSpeechEngine { usingParakeet ? parakeetEngine : appleEngine }
    private let hotkey = HotkeyMonitor()
    private let correctionWatcher = CorrectionWatcher()
    private var hud: DictationHUD?
    private var pressedAt: Date?
    /// When hands-free dictation began, to ignore stray key presses just after.
    private var handsFreeSince: Date?
    /// Set while the key is down to stop hands-free dictation.
    private var stopPressedAt: Date?
    private var targetBundleID: String?
    private var cancellables: Set<AnyCancellable> = []
    /// Text typed live into the app during the current dictation.
    private var typer = LivePhraseTyper()
    private var typedSoFar: String { typer.typedSoFar }
    private var isLiveTyping = false

    /// A press shorter than this starts hands-free mode instead of push-to-talk.
    private let tapThreshold: TimeInterval = 0.35

    init(appState: AppState, lexicon: LexiconStore) {
        self.appState = appState
        self.lexicon = lexicon

        for engine in [appleEngine, parakeetEngine] as [DictationSpeechEngine] {
            engine.onPartial = { [weak self] text in self?.liveText = text }
            engine.onLevel = { [weak self] level in self?.level = level }
            engine.onFinalSegment = { [weak self] phrase in self?.typeFinal(phrase) }
            engine.onVolatileSegment = { [weak self] words in self?.typeVolatile(words) }
            engine.onPreparing = { [weak self] message in self?.phase = .preparing(message) }
        }

        hotkey.onPress = { [weak self] in self?.keyPressed() }
        hotkey.onRelease = { [weak self] in self?.keyReleased() }

        appState.$dictationEnabled
            .combineLatest(appState.$dictationKey)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, key in
                guard let self else { return }
                if enabled {
                    self.hotkey.start(key: key)
                } else {
                    self.hotkey.stop()
                    if self.phase != .idle { Task { await self.cancel() } }
                }
            }
            .store(in: &cancellables)

        $phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.updateHUD(for: phase) }
            .store(in: &cancellables)
    }

    var isActive: Bool { phase != .idle }

    // MARK: - Shortcut behaviour
    // Hold the key to talk and release to finish, or tap it once to keep
    // listening hands-free and tap again to finish.

    private func keyPressed() {
        if phase == .listening && isHandsFree {
            // Stop when the key comes back up, and ignore stray presses in the first
            // moment (macOS can report the Fn/Globe key again when it shows its own
            // pop-ups), so a tap to start can't immediately stop dictation.
            guard Date().timeIntervalSince(handsFreeSince ?? .distantPast) > 0.6 else { return }
            stopPressedAt = Date()
            return
        }
        if isStuck {
            Task { await cancel() }
            return
        }
        guard phase == .idle else { return }
        pressedAt = Date()
        isHandsFree = false
        Task { await start(handsFree: false) }
    }

    private func keyReleased() {
        if stopPressedAt != nil {
            stopPressedAt = nil
            if phase == .listening { Task { await finish() } }
            return
        }
        guard let pressedAt else { return }
        self.pressedAt = nil
        if Date().timeIntervalSince(pressedAt) < tapThreshold {
            // A quick tap: keep listening until the next tap.
            isHandsFree = true
            handsFreeSince = Date()
            return
        }
        if !isHandsFree, phase == .listening || isPreparing {
            Task { await finish() }
        }
    }

    private var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    // MARK: - Public controls (menu bar and settings)

    func toggleHandsFree() {
        if phase == .idle {
            Task { await start(handsFree: true) }
        } else if phase == .listening {
            Task { await finish() }
        } else if isStuck {
            Task { await cancel() }
        }
    }

    /// True when starting or finishing has taken far longer than it should.
    /// Clicking the menu bar icon or pressing the key then resets dictation.
    private var isStuck: Bool {
        guard phase != .idle, phase != .listening else { return false }
        if case .preparing(let message) = phase, message.contains("download") { return false }
        return Date().timeIntervalSince(phaseChangedAt) > 10
    }

    func start(handsFree: Bool) async {
        guard phase == .idle else { return }
        lastError = nil
        liveText = ""
        // For the shortcut key, hold-or-tap is decided by keyPressed/keyReleased;
        // don't overwrite it here, as the key may already have been released.
        if handsFree {
            isHandsFree = true
            handsFreeSince = Date()
        }
        targetBundleID = TextInserter.frontmostBundleID
        typer = LivePhraseTyper()
        isLiveTyping = appState.liveTyping && testSink == nil && TextInserter.focusedFieldSupportsLiveEditing()
        phase = .preparing("Starting…")
        usingParakeet = appState.recognitionModel == .parakeet
        do {
            do {
                try await engine.start(hints: lexicon.recognitionHints)
            } catch where usingParakeet {
                // If Parakeet can't load (say, the download failed), use Apple's engine this time.
                usingParakeet = false
                try await engine.start(hints: lexicon.recognitionHints)
            }
            startedAt = Date()
            phase = .listening
            // The key may have been released while the engine was starting.
            if !handsFree && pressedAt == nil && !isHandsFree {
                await finish()
            }
        } catch {
            lastError = error.localizedDescription
            phase = .idle
        }
    }

    func finish() async {
        guard phase == .listening else { return }
        phase = .processing
        // Finishing normally takes well under a second. If the speech engine
        // stalls, cancel it and keep what was heard, so Warble never gets stuck.
        let stopping = engine
        let heard = liveText
        let raw: String
        if let finished = await withDeadline(seconds: 6, { await stopping.stop() }) {
            raw = finished
        } else {
            await stopping.cancel()
            raw = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        startedAt = nil
        isHandsFree = false
        guard !raw.isEmpty else {
            phase = .idle
            return
        }
        let cleaned = await cleanUp(raw)

        if isLiveTyping && !typedSoFar.isEmpty {
            // Words are already in the field; swap in the tidied version if it differs.
            isLiveTyping = false
            let typed = typedSoFar
            phase = .idle
            try? await Task.sleep(for: .milliseconds(300))
            let replaced = TextInserter.replaceTyped(typed, with: cleaned)
            let inField = replaced ? cleaned : typed
            lastResult = inField
            watchForCorrections(inField)
            return
        }

        isLiveTyping = false
        lastResult = cleaned
        phase = .idle
        deliver(cleaned)
    }

    /// Types words into the app while you're still speaking.
    private func typeVolatile(_ words: String) {
        guard isLiveTyping else { return }
        let piece = typer.volatile(words, replacements: lexicon.replacements)
        if !piece.isEmpty { TextInserter.type(piece) }
    }

    /// Finishes off a phrase once the speech engine is sure of it.
    private func typeFinal(_ phrase: String) {
        guard isLiveTyping else { return }
        switch typer.final(phrase, replacements: lexicon.replacements) {
        case .type(let text)?:
            TextInserter.type(text)
        case .replace(let old, let new)?:
            if !TextInserter.replaceTyped(old, with: new) {
                typer.replacementFailed(old: old, new: new)
            }
        case nil:
            break
        }
    }

    func cancel() async {
        isLiveTyping = false
        startedAt = nil
        isHandsFree = false
        pressedAt = nil
        stopPressedAt = nil
        phase = .idle
        await engine.cancel()
    }

    // MARK: - Cleanup and delivery

    private func cleanUp(_ raw: String) async -> String {
        let basic = TextCleaner.clean(raw, replacements: lexicon.replacements)
        guard appState.cleanupEnabled else { return basic }
        let style = WritingStyle.forApp(bundleID: targetBundleID)
        let terms = lexicon.recognitionHints
        // Apple Intelligence usually answers in about a second, but can be slow the
        // first time after an update or restart. Never wait more than a few seconds.
        let smartResult = await withDeadline(seconds: 6) {
            await SmartCleanup.clean(basic, terms: terms, style: style)
        }
        if let smart = smartResult ?? nil {
            // Re-apply known spellings in case the model changed them.
            return TextCleaner.applyReplacements(smart, lexicon.replacements)
        }
        return basic
    }

    private func deliver(_ text: String) {
        if let testSink {
            testSink(text)
            return
        }
        TextInserter.insert(text)
        watchForCorrections(text)
    }

    private func watchForCorrections(_ text: String) {
        correctionWatcher.watch(inserted: text) { [weak self] original, edited in
            self?.lexicon.learnFromCorrection(original: original, edited: edited)
        }
    }

    // MARK: - Floating pop-up

    private func updateHUD(for phase: Phase) {
        if phase == .idle {
            hud?.hide()
        } else {
            if hud == nil { hud = DictationHUD(controller: self) }
            hud?.show()
        }
    }
}
