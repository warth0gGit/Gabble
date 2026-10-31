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

    @Published private(set) var phase: Phase = .idle
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
    private let engine = SpeechEngine()
    private let hotkey = HotkeyMonitor()
    private let correctionWatcher = CorrectionWatcher()
    private var hud: DictationHUD?
    private var pressedAt: Date?
    private var targetBundleID: String?
    private var cancellables: Set<AnyCancellable> = []

    /// A press shorter than this starts hands-free mode instead of push-to-talk.
    private let tapThreshold: TimeInterval = 0.35

    init(appState: AppState, lexicon: LexiconStore) {
        self.appState = appState
        self.lexicon = lexicon

        engine.onPartial = { [weak self] text in self?.liveText = text }
        engine.onLevel = { [weak self] level in self?.level = level }
        engine.onPreparing = { [weak self] message in self?.phase = .preparing(message) }

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
            Task { await finish() }
            return
        }
        guard phase == .idle else { return }
        pressedAt = Date()
        Task { await start(handsFree: false) }
    }

    private func keyReleased() {
        guard let pressedAt else { return }
        self.pressedAt = nil
        if Date().timeIntervalSince(pressedAt) < tapThreshold {
            isHandsFree = true
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
        }
    }

    func start(handsFree: Bool) async {
        guard phase == .idle else { return }
        lastError = nil
        liveText = ""
        isHandsFree = handsFree
        targetBundleID = TextInserter.frontmostBundleID
        phase = .preparing("Starting…")
        do {
            try await engine.start(hints: lexicon.recognitionHints)
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
        let raw = await engine.stop()
        startedAt = nil
        isHandsFree = false
        guard !raw.isEmpty else {
            phase = .idle
            return
        }
        let cleaned = await cleanUp(raw)
        lastResult = cleaned
        phase = .idle
        deliver(cleaned)
    }

    func cancel() async {
        await engine.cancel()
        startedAt = nil
        isHandsFree = false
        pressedAt = nil
        phase = .idle
    }

    // MARK: - Cleanup and delivery

    private func cleanUp(_ raw: String) async -> String {
        let basic = TextCleaner.clean(raw, replacements: lexicon.replacements)
        guard appState.cleanupEnabled else { return basic }
        let style = WritingStyle.forApp(bundleID: targetBundleID)
        if let smart = await SmartCleanup.clean(basic, terms: lexicon.recognitionHints, style: style) {
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
