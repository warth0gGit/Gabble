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
    /// What happened to the last tidy-up, shown on the Dictation page.
    @Published private(set) var lastCleanup: CleanupOutcome?
    /// A one-off note about the last dictation, e.g. that Parakeet was still loading.
    @Published private(set) var lastNote: String?
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
    /// Counts dictations. Work that finishes after its dictation was reset or
    /// replaced (a slow speech engine or tidy-up) checks this and stands down,
    /// so it can never type into the wrong place or change the new dictation.
    private var session = 0
    /// True while a speech engine is starting, so a second start can't overlap it.
    private var engineStarting = false
    /// Apple Intelligence, warmed up while you talk.
    private var cleanupSession: CleanupSession?

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

        // Load Parakeet as soon as Warble opens (and when it's chosen), so the
        // first dictation doesn't have to fall back to Apple's engine.
        appState.$recognitionModel
            .receive(on: RunLoop.main)
            .sink { model in
                if model == .parakeet { ParakeetStatus.shared.warmUp() }
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
        if isStuck || isPreparing && Date().timeIntervalSince(phaseChangedAt) > 1 {
            // Pressing again while Warble is still getting ready, or when it has
            // stalled, resets dictation.
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
        } else if isStuck || isPreparing {
            Task { await cancel() }
        }
    }

    /// True when starting or finishing has taken far longer than it should.
    /// Clicking the menu bar icon or pressing the key then resets dictation.
    private var isStuck: Bool {
        guard phase != .idle, phase != .listening else { return false }
        if case .preparing(let message) = phase, message.contains("download") { return false }
        // Finishing can legitimately take a while on a long dictation: the speech
        // engine has up to 6 s, then Apple Intelligence up to 20 s.
        let limit: TimeInterval = phase == .processing ? 30 : 10
        return Date().timeIntervalSince(phaseChangedAt) > limit
    }

    func start(handsFree: Bool) async {
        guard phase == .idle, !engineStarting else { return }
        session += 1
        let mine = session
        lastError = nil
        lastNote = nil
        liveText = ""
        // For the shortcut key, hold-or-tap is decided by keyPressed/keyReleased;
        // don't overwrite it here, as the key may already have been released.
        if handsFree {
            isHandsFree = true
            handsFreeSince = Date()
        }
        targetBundleID = TextInserter.frontmostBundleID
        // Electron apps (Claude, Slack, Teams) only let Warble read their text
        // boxes once asked; that's what lets it learn from your corrections there.
        TextInserter.enableAccessibilityForFrontmostApp()
        typer = LivePhraseTyper()
        isLiveTyping = appState.liveTyping && testSink == nil && TextInserter.focusedFieldSupportsLiveEditing()
        phase = .preparing("Starting…")
        usingParakeet = appState.recognitionModel == .parakeet
        if appState.cleanupEnabled && SmartCleanup.isAvailable {
            let cleanup = CleanupSession()
            cleanup.prewarm()
            cleanupSession = cleanup
        } else {
            cleanupSession = nil
        }
        engineStarting = true
        do {
            do {
                try await engine.start(hints: lexicon.recognitionHints)
            } catch where usingParakeet {
                // If Parakeet isn't loaded yet or can't load, use Apple's engine this time.
                usingParakeet = false
                if error is ParakeetNotReady {
                    lastNote = "Parakeet was still loading, so Apple's speech engine was used for this dictation."
                }
                try await engine.start(hints: lexicon.recognitionHints)
            }
            engineStarting = false
            guard mine == session else {
                // Dictation was reset while the engine was starting.
                await engine.cancel()
                return
            }
            startedAt = Date()
            phase = .listening
            // The key may have been released while the engine was starting.
            if !handsFree && pressedAt == nil && !isHandsFree {
                await finish()
            }
        } catch {
            engineStarting = false
            guard mine == session else { return }
            lastError = error.localizedDescription
            phase = .idle
        }
    }

    func finish() async {
        guard phase == .listening else { return }
        let mine = session
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
        // Reset (by the key or the menu bar icon) while the engine was finishing.
        guard mine == session else { return }
        startedAt = nil
        isHandsFree = false
        guard !raw.isEmpty else {
            phase = .idle
            return
        }
        let cleaned = await cleanUp(raw)
        guard mine == session else { return }

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
        session += 1
        cleanupSession = nil
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
        let warmed = cleanupSession
        cleanupSession = nil
        guard appState.cleanupEnabled else {
            lastCleanup = nil
            return basic
        }
        guard SmartCleanup.isAvailable else {
            lastCleanup = .skipped(reason: SmartCleanup.unavailableReason ?? "Apple Intelligence isn't available.")
            return basic
        }
        let style = WritingStyle.forApp(bundleID: targetBundleID)
        let terms = lexicon.recognitionHints
        let cleanup = warmed ?? CleanupSession()
        // Apple Intelligence usually answers in a second or two, more for a long
        // ramble. Never wait longer than the deadline: fall back to the basic tidy-up.
        let words = basic.split(whereSeparator: \.isWhitespace).count
        let limit = SmartCleanup.deadline(forWords: words)
        let began = Date()
        let result = await withDeadline(seconds: limit) {
            await cleanup.clean(basic, terms: terms, style: style)
        }
        switch result {
        case .success(let smart)?:
            lastCleanup = .smart(seconds: Date().timeIntervalSince(began))
            // Re-apply known spellings in case the model changed them.
            return TextCleaner.applyReplacements(smart, lexicon.replacements)
        case .failure(let failure)?:
            lastCleanup = .skipped(reason: failure.reason)
        case nil:
            lastCleanup = .skipped(reason: "Apple Intelligence took longer than \(Int(limit)) seconds.")
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
