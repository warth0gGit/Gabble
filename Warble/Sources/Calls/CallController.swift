import AppKit
import Combine
import Foundation

/// Runs call transcription: notices a call, asks "Transcribe this call?",
/// records and transcribes both sides, and saves the transcript when the call ends.
@MainActor
final class CallController: ObservableObject {
    enum State: Equatable {
        case idle
        case asking(appName: String)
        case recording(appName: String)
        case saving
        case saved(URL)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript: CallTranscript?
    @Published private(set) var liveMe = ""
    @Published private(set) var liveOthers = ""
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var lastError: String?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private let appState: AppState
    private let lexicon: LexiconStore
    private let detector = CallDetector()
    private var recorder: CallRecorder?
    private var pendingCall: CallDetector.ActiveCall?
    private var panel: CallPanel?
    private var hideTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, lexicon: LexiconStore) {
        self.appState = appState
        self.lexicon = lexicon

        detector.onCallStarted = { [weak self] call in self?.callStarted(call) }
        detector.onCallEnded = { [weak self] call in self?.callEnded(call) }

        appState.$callApps
            .combineLatest(appState.$promptForCalls)
            .receive(on: RunLoop.main)
            .sink { [weak self] apps, enabled in
                guard let self else { return }
                self.detector.enabledApps = apps
                if enabled { self.detector.start() } else { self.detector.stop() }
            }
            .store(in: &cancellables)

        $state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.updatePanel(for: state) }
            .store(in: &cancellables)
    }

    // MARK: - Detector events

    private func callStarted(_ call: CallDetector.ActiveCall) {
        guard state == .idle || isSavedState else { return }
        pendingCall = call
        state = .asking(appName: call.app.name)
    }

    private func callEnded(_ call: CallDetector.ActiveCall) {
        switch state {
        case .recording:
            Task { await stopAndSave() }
        case .asking:
            pendingCall = nil
            state = .idle
        default:
            break
        }
    }

    private var isSavedState: Bool {
        if case .saved = state { return true }
        return false
    }

    // MARK: - User actions

    func acceptPrompt() {
        guard let call = pendingCall else { return }
        Task { await startRecording(app: call.app) }
    }

    func declinePrompt() {
        pendingCall = nil
        state = .idle
    }

    func stopRecording() {
        Task { await stopAndSave() }
    }

    func startRecording(app: CallApp) async {
        lastError = nil
        let recorder = CallRecorder(app: app, recordingsFolder: Self.recordingsFolder)
        recorder.onUpdate = { [weak self] transcript, me, others in
            self?.transcript = transcript
            self?.liveMe = me
            self?.liveOthers = others
        }
        self.recorder = recorder
        transcript = recorder.transcript
        recordingStarted = Date()
        state = .recording(appName: app.name)
        do {
            try await recorder.start(hints: lexicon.recognitionHints)
        } catch {
            lastError = Self.friendly(error)
            _ = await recorder.stop()
            self.recorder = nil
            recordingStarted = nil
            state = .idle
            showErrorBriefly()
        }
    }

    private func stopAndSave() async {
        guard let recorder else { return }
        state = .saving
        var finished = await recorder.stop()
        self.recorder = nil
        recordingStarted = nil
        liveMe = ""
        liveOthers = ""
        finished.segments = finished.segments.map { segment in
            var s = segment
            s.text = TextCleaner.applyReplacements(s.text, lexicon.replacements)
            return s
        }
        transcript = finished
        guard !finished.segments.isEmpty else {
            state = .idle
            return
        }
        do {
            let url = try save(finished)
            lexicon.harvest(from: finished.plainText)
            state = .saved(url)
            scheduleHide(after: 8)
        } catch {
            lastError = "Couldn't save the transcript: \(error.localizedDescription)"
            state = .idle
            showErrorBriefly()
        }
    }

    // MARK: - Saving

    static var recordingsFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Warble/Recordings", isDirectory: true)
    }

    var callsFolder: URL {
        URL(fileURLWithPath: appState.masterFolderPath).appendingPathComponent("Calls", isDirectory: true)
    }

    private func save(_ transcript: CallTranscript) throws -> URL {
        let folder = callsFolder.appendingPathComponent(transcript.category, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(transcript.fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(transcript.fileName.replacingOccurrences(of: ".md", with: " \(n).md"))
            n += 1
        }
        try transcript.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The most recent saved transcripts, newest first.
    func recentTranscripts(limit: Int = 10) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: callsFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
        let dated = files.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: - Pop-up

    private func updatePanel(for state: State) {
        if state == .idle && lastError == nil {
            panel?.hide()
            return
        }
        if panel == nil { panel = CallPanel(controller: self) }
        panel?.show()
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if case .saved = self.state { self.state = .idle }
        }
    }

    private func showErrorBriefly() {
        panel?.show()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.lastError = nil
            if self.state == .idle { self.panel?.hide() }
        }
    }

    func dismissError() {
        lastError = nil
        if state == .idle { panel?.hide() }
    }

    private static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.lowercased().contains("declined") || text.lowercased().contains("not authorized")
            || text.lowercased().contains("tcc") {
            return "Warble needs the Screen & System Audio Recording permission to hear the call. Open Warble → Permissions."
        }
        return text
    }
}
