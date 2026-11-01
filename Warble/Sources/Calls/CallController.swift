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

    /// A voice Warble doesn't know yet, waiting for "Who is talking?".
    struct UnknownVoice: Equatable {
        var speakerID: String
        var sample: String
    }
    @Published private(set) var askingWho: UnknownVoice?
    /// Voices Warble has learned, kept between calls.
    let voices = VoiceprintStore()
    private var voiceSegments: [VoiceSegment] = []
    private var namesThisCall: [String: String] = [:]
    private var skippedVoices: Set<String> = []
    /// How long someone must talk before Warble asks who they are.
    private let askAfterSeconds: TimeInterval = 5

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
            .sink { [weak self] _ in self?.updatePanel() }
            .store(in: &cancellables)
        $askingWho
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updatePanel() }
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
        recorder.onVoices = { [weak self] segments in self?.heard(segments) }
        voiceSegments = []
        namesThisCall = [:]
        skippedVoices = []
        askingWho = nil
        self.recorder = recorder
        transcript = recorder.transcript
        recordingStarted = Date()
        state = .recording(appName: app.name)
        do {
            try await recorder.start(hints: lexicon.recognitionHints, knownVoices: voices.voices)
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
        askingWho = nil
        finished.relabel { [self] segment in label(for: segment) }
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

    // MARK: - Voices

    private func heard(_ segments: [VoiceSegment]) {
        voiceSegments.append(contentsOf: segments)
        askAboutNextUnknownVoice()
    }

    private func isKnown(_ speakerID: String) -> Bool {
        namesThisCall[speakerID] != nil || voices.voices.contains { $0.name == speakerID }
    }

    private func askAboutNextUnknownVoice() {
        guard isRecording, askingWho == nil else { return }
        let talk = SpeakerAssigner.talkTime(voiceSegments)
        let firstHeard = voiceSegments.map(\.speakerID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard let id = firstHeard.first(where: {
            !isKnown($0) && !skippedVoices.contains($0) && (talk[$0] ?? 0) >= askAfterSeconds
        }) else { return }
        askingWho = UnknownVoice(speakerID: id, sample: sample(for: id))
    }

    /// Something the voice said recently, to help you recognise them.
    private func sample(for speakerID: String) -> String {
        let theirs = (transcript?.segments ?? []).filter { segment in
            segment.speaker == CallRecorder.othersLabel
                && SpeakerAssigner.speaker(for: CallTranscript.spokenRange(of: segment), in: voiceSegments) == speakerID
        }
        return theirs.suffix(2).map(\.text).joined(separator: " ")
    }

    /// Saves the name for the voice being asked about, and remembers it for future calls.
    func nameVoice(_ name: String) {
        guard let asking = askingWho else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return skipVoice() }
        namesThisCall[asking.speakerID] = trimmed
        askingWho = nil
        let speakers = recorder?.speakers
        Task { [weak self] in
            if let embedding = await speakers?.embedding(for: asking.speakerID) {
                self?.voices.remember(name: trimmed, embedding: embedding)
            }
            self?.askAboutNextUnknownVoice()
        }
    }

    func skipVoice() {
        guard let asking = askingWho else { return }
        skippedVoices.insert(asking.speakerID)
        askingWho = nil
        askAboutNextUnknownVoice()
    }

    /// The name to show for a transcript line.
    func label(for segment: CallTranscript.Segment) -> String {
        guard segment.speaker == CallRecorder.othersLabel,
              let id = SpeakerAssigner.speaker(for: CallTranscript.spokenRange(of: segment), in: voiceSegments)
        else { return segment.speaker }
        if let name = namesThisCall[id] { return name }
        if voices.voices.contains(where: { $0.name == id }) { return id }
        let unknown = voiceSegments.map(\.speakerID).reduce(into: [String]()) {
            if !$0.contains($1) && !isKnown($1) { $0.append($1) }
        }
        let number = (unknown.firstIndex(of: id) ?? 0) + 2
        return "Speaker \(number)"
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

    /// The pop-up shows only when there's something to answer or see:
    /// "Transcribe this call?", "Identify Speaker", a saved transcript, or a problem.
    /// While a call is being transcribed the menu bar icon shows it instead.
    private var needsPanel: Bool {
        if lastError != nil && state == .idle { return true }
        if askingWho != nil { return true }
        switch state {
        case .asking, .saved: return true
        default: return false
        }
    }

    private func updatePanel() {
        guard needsPanel else {
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
            self.updatePanel()
        }
    }

    private func showErrorBriefly() {
        panel?.show()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.lastError = nil
            self.updatePanel()
        }
    }

    func dismissError() {
        lastError = nil
        updatePanel()
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
