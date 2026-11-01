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
        /// Saved in Unfiled; asking where it should go.
        case filing(URL)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript: CallTranscript?
    @Published private(set) var liveMe = ""
    @Published private(set) var liveOthers = ""
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var lastError: String?
    /// Where the last call was filed and why, e.g. "Filed in 1-1s/Sarah (same person)".
    @Published private(set) var filedNote: String?
    /// Folders to offer when asking where a call should go.
    @Published private(set) var filingSuggestions: [FilingSuggestion] = []

    /// A person on the call, for the live speaker chips.
    struct LiveSpeaker: Identifiable, Equatable {
        var id: String
        var name: String
        var isYou = false
        /// The voice Warble is asking about ("Who's this?").
        var isNew = false
        var isSpeaking = false
    }
    /// You, then everyone heard on the other side, with who's talking now.
    @Published private(set) var liveSpeakers: [LiveSpeaker] = []
    /// The live card shrunk to a small pill.
    @Published var panelMinimized = false

    /// The steps shown while a finished call is saved.
    enum SavingStep: Int, Comparable {
        case rereading, tidying, saving
        static func < (a: SavingStep, b: SavingStep) -> Bool { a.rawValue < b.rawValue }
    }
    @Published private(set) var savingStep: SavingStep?
    @Published private(set) var savingRereads = false
    @Published private(set) var summaryWillFollow = false

    /// What the "Transcript saved" card shows.
    struct SavedStats: Equatable {
        var minutes: Int
        var speakers: Int
        var words: Int
        var summaryPending: Bool
    }
    @Published private(set) var savedStats: SavedStats?
    private var meterTask: Task<Void, Never>?
    /// The call whose save the card is showing, if any.
    private var savingCall: UUID?
    /// A call that started while the last one was still being stopped.
    private var queuedCall: CallDetector.ActiveCall?
    /// Remembers where calls go, so it can file them without asking.
    let filing = FilingStore()
    private let calendar = CalendarLookup()
    private var meeting: MeetingInfo?
    /// The saved call waiting to be filed (or re-filed).
    private var lastSaved: (url: URL, transcript: CallTranscript, features: CallFeatures)?

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
            .sink { [weak self] asking in
                // A new voice always opens the full card, even if it was shrunk.
                if asking != nil { self?.panelMinimized = false }
                self?.updatePanel()
            }
            .store(in: &cancellables)
        CallNotifier.shared.activate()
    }

    // MARK: - Detector events

    private func callStarted(_ call: CallDetector.ActiveCall) {
        // Back-to-back calls: the last call may still be saving or waiting to be
        // filed. Ask about the new one straight away; the last one finishes saving
        // in the background (and stays in Unfiled if it was waiting to be filed).
        if isRecording {
            // The call being recorded has just ended in the same moment; ask
            // about this one as soon as that recording has stopped.
            queuedCall = call
            return
        }
        guard state == .idle || state == .saving || isSavedState else { return }
        hideTask?.cancel()
        lastError = nil
        savingCall = nil
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
        switch state {
        case .saved, .filing: return true
        default: return false
        }
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

    /// Starts transcribing the call app that's using the microphone now, from
    /// the menu bar, in case Warble didn't ask (for example a call that
    /// followed straight on from another).
    func transcribeActiveCall() {
        guard !isRecording, let call = detector.activeCall else { return }
        pendingCall = nil
        Task { await startRecording(app: call.app) }
    }

    /// Whether "Transcribe this call" makes sense right now.
    var canTranscribeActiveCall: Bool {
        !isRecording && detector.activeCall != nil
    }

    func startRecording(app: CallApp) async {
        lastError = nil
        savingCall = nil
        queuedCall = nil
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
        panelMinimized = false
        savedStats = nil
        hideTask?.cancel()
        self.recorder = recorder
        transcript = recorder.transcript
        recordingStarted = Date()
        meeting = calendar.meeting(at: Date(), appName: app.name)
        state = .recording(appName: app.name)
        if appState.recognitionModel == .parakeet {
            // Have Parakeet ready by the time the call ends.
            ParakeetStatus.shared.warmUp()
        }
        do {
            try await recorder.start(hints: lexicon.recognitionHints, knownVoices: voices.voices)
            startSpeakerMeter()
        } catch {
            lastError = Self.friendly(error)
            _ = await recorder.stop()
            self.recorder = nil
            recordingStarted = nil
            state = .idle
            showErrorBriefly()
        }
    }

    // MARK: - Who's talking now

    private func startSpeakerMeter() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshLiveSpeakers()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopSpeakerMeter() {
        meterTask?.cancel()
        meterTask = nil
        liveSpeakers = []
    }

    private func refreshLiveSpeakers() {
        guard let recorder, isRecording else { return }
        let updated = Self.liveSpeakers(
            meTalking: recorder.meMeter.isSpeaking(),
            meLevel: recorder.meMeter.level, meThreshold: recorder.meMeter.threshold,
            othersTalking: recorder.othersMeter.isSpeaking(),
            voices: voiceSegments, asking: askingWho?.speakerID, name: { [self] in voiceName($0) })
        if updated != liveSpeakers { liveSpeakers = updated }
    }

    /// The speaker chips. Pure, so it can be tested.
    /// - Voices that have spoken less than two seconds aren't shown yet (they're
    ///   often noise), unless Warble is asking about them.
    /// - Without headphones the other side's voices reach your microphone too,
    ///   so "You" only lights up over them when you're clearly louder.
    /// - Which person on the other side is talking comes from voice recognition,
    ///   which runs a few seconds behind; the most recently heard voice is shown.
    static func liveSpeakers(meTalking: Bool, meLevel: Double, meThreshold: Double, othersTalking: Bool,
                             voices: [VoiceSegment], asking: String?,
                             name: (String) -> String) -> [LiveSpeaker] {
        let youTalking = meTalking && !(othersTalking && meLevel < meThreshold * 3)
        var list = [LiveSpeaker(id: "you", name: "You", isYou: true, isSpeaking: youTalking)]
        let talk = SpeakerAssigner.talkTime(voices)
        var order: [String] = []
        for segment in voices where !order.contains(segment.speakerID) {
            if (talk[segment.speakerID] ?? 0) >= 2 || segment.speakerID == asking { order.append(segment.speakerID) }
        }
        guard !order.isEmpty else {
            list.append(LiveSpeaker(id: "others", name: "Others", isSpeaking: othersTalking))
            return list
        }
        let latest = voices.filter { order.contains($0.speakerID) }.max { $0.end < $1.end }?.speakerID
        for id in order {
            list.append(LiveSpeaker(id: id, name: id == asking ? "New voice" : name(id),
                                    isNew: id == asking, isSpeaking: othersTalking && id == latest))
        }
        return list
    }

    private func stopAndSave() async {
        guard let recorder else { return }
        // Take everything about this call now. Saving can take a while (Parakeet
        // re-reads the whole recording), and with back-to-back calls the next
        // call can start meanwhile; it must find Warble ready, not busy.
        self.recorder = nil
        stopSpeakerMeter()
        let heard = VoiceBox(voiceSegments)
        let names = namesThisCall
        recorder.onVoices = { segments in heard.segments.append(contentsOf: segments) }
        recorder.onUpdate = nil
        let callMeeting = meeting
        meeting = nil
        askingWho = nil
        recordingStarted = nil
        liveMe = ""
        liveOthers = ""
        panelMinimized = false
        savingRereads = appState.recognitionModel == .parakeet
        summaryWillFollow = SmartCleanup.isAvailable
            && SummaryChunker.wordCount(recorder.transcript.plainText) >= SummaryChunker.minimumWords
        savingStep = savingRereads ? .rereading : .tidying
        state = .saving
        let token = UUID()
        savingCall = token
        // Whether the card is still showing this call's save (not a newer call).
        var shownHere: Bool { state == .saving && savingCall == token }
        if let next = queuedCall {
            queuedCall = nil
            callStarted(next)
        }

        var finished = await recorder.stop()
        if appState.recognitionModel == .parakeet, await ParakeetService.shared.isReady {
            // Parakeet re-reads a call at well over 100× real time, so this is
            // normally seconds. Never let it hold up saving: keep the live
            // transcript if it takes far longer than it should.
            let minutes = Date().timeIntervalSince(finished.started) / 60
            let current = finished
            let recordings = recorder.recordings
            if let better = await withDeadline(seconds: 60 + minutes * 10, {
                await self.retranscribe(current, recordings: recordings)
            }) {
                finished = better
            }
        }
        if savingRereads { await showStep(.tidying, for: token) }
        let voicesHeard = heard.segments
        finished.relabel { [self] segment in label(for: segment, voices: voicesHeard, names: names) }
        // Word List fixes, then the light tidy-up (on every call, however short).
        finished.segments = finished.segments.compactMap { segment in
            var s = segment
            s.text = TextCleaner.tidyCall(TextCleaner.applyReplacements(s.text, lexicon.replacements))
            return s.text.isEmpty ? nil : s
        }
        finished.meeting = callMeeting ?? calendar.meeting(at: finished.started, appName: finished.appName)
        guard !finished.segments.isEmpty else {
            if shownHere {
                transcript = finished
                savingStep = nil
                lastError = "Warble didn't hear anything on that call, so there was nothing to save."
                state = .idle
                showErrorBriefly()
            }
            return
        }
        await showStep(.saving, for: token)
        let features = CallFeatures(seriesID: finished.meeting?.seriesID, meetingTitle: finished.meeting?.title,
                                    people: finished.people, date: finished.started)
        let sure = filing.autoFolder(for: features)
        finished.category = sure?.folder ?? "Unfiled"
        finished.summary = initialSummaryState(for: finished)
        do {
            let url = try save(finished)
            lexicon.harvest(from: finished.plainText)
            if let sure { filing.learn(features, folder: sure.folder) }
            if finished.summary == .pending { summarise(finished, savedAt: url) }
            let stats = SavedStats(minutes: max(1, Int((finished.duration / 60).rounded())),
                                   speakers: finished.speakers.count,
                                   words: SummaryChunker.wordCount(finished.plainText),
                                   summaryPending: finished.summary == .pending)
            notifySaved(finished, stats: stats, url: url, filed: sure?.folder)
            // A newer call has taken over the card: this one stays where it was
            // saved (Unfiled if Warble wasn't sure), and the notification says so.
            guard shownHere else { return }
            await showStep(nil, for: token)
            guard shownHere else { return }
            lastSaved = (url, finished, features)
            transcript = finished
            savedStats = stats
            if let sure {
                filedNote = "Filed in \(sure.folder) (\(sure.reason))."
                state = .saved(url)
                scheduleHide(after: 10)
            } else {
                filedNote = nil
                filingSuggestions = filing.suggestions(for: features)
                hideTask?.cancel()
                state = .filing(url)
            }
        } catch {
            let message = "Couldn't save the transcript: \(error.localizedDescription)"
            guard shownHere else {
                CallNotifier.shared.saveFailed(message)
                return
            }
            savingStep = nil
            lastError = message
            state = .idle
            showErrorBriefly()
        }
    }

    /// Moves the end-of-call checklist on, pausing briefly so each step can be
    /// seen ticking off (the work itself is usually instant).
    private func showStep(_ step: SavingStep?, for token: UUID) async {
        guard state == .saving, savingCall == token else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard state == .saving, savingCall == token else { return }
        savingStep = step
    }

    private func notifySaved(_ call: CallTranscript, stats: SavedStats, url: URL, filed folder: String?) {
        let name = call.meeting?.title ?? "\(call.shortAppName) call"
        let people = stats.speakers == 1 ? "1 speaker" : "\(stats.speakers) speakers"
        let place = folder.map { "Filed in \($0)." } ?? "Saved in Unfiled."
        CallNotifier.shared.transcriptSaved(
            title: "Call transcript saved",
            body: "\(name): \(stats.minutes) min, \(people). \(place)",
            url: url)
    }

    /// Swaps the live transcript for Parakeet's re-read of the recordings.
    /// If Parakeet isn't available, the live transcript is kept.
    private func retranscribe(_ transcript: CallTranscript,
                              recordings: [CallRetranscriber.Recording]) async -> CallTranscript {
        var segments: [CallTranscript.Segment] = []
        do {
            for recording in recordings {
                segments += try await CallRetranscriber.segments(for: recording, terms: lexicon.recognitionHints)
            }
        } catch {
            return transcript
        }
        guard !segments.isEmpty else { return transcript }
        var updated = transcript
        updated.segments = segments
        return updated
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

    /// The name to show for a transcript line, using that call's own voices and names.
    private func label(for segment: CallTranscript.Segment, voices heard: [VoiceSegment],
                       names: [String: String]) -> String {
        guard segment.speaker == CallRecorder.othersLabel,
              let id = SpeakerAssigner.speaker(for: CallTranscript.spokenRange(of: segment), in: heard)
        else { return segment.speaker }
        return voiceName(id, voices: heard, names: names)
    }

    /// A voice's name on the call being transcribed now.
    private func voiceName(_ id: String) -> String {
        voiceName(id, voices: voiceSegments, names: namesThisCall)
    }

    /// A voice's name: given on that call, remembered from earlier calls, or "Speaker 2".
    private func voiceName(_ id: String, voices heard: [VoiceSegment], names: [String: String]) -> String {
        if let name = names[id] { return name }
        if voices.voices.contains(where: { $0.name == id }) { return id }
        let known = Set(voices.voices.map(\.name))
        var unknown: [String] = []
        for speaker in heard.map(\.speakerID)
        where !unknown.contains(speaker) && names[speaker] == nil && !known.contains(speaker) {
            unknown.append(speaker)
        }
        let number = (unknown.firstIndex(of: id) ?? 0) + 2
        return "Speaker \(number)"
    }

    // MARK: - Summary

    /// Whether to write a summary, so the note can say one is on its way (or why not).
    private func initialSummaryState(for transcript: CallTranscript) -> CallSummaryState {
        guard CallSummariser.isWorthSummarising(transcript) else { return .none }
        guard SmartCleanup.isAvailable else {
            return .failed(SmartCleanup.unavailableReason ?? "Apple Intelligence isn't available on this Mac.")
        }
        return .pending
    }

    /// Writes the summary in the background, then adds it to the saved note.
    /// The transcript is already saved, and filing carries on meanwhile.
    private func summarise(_ transcript: CallTranscript, savedAt url: URL) {
        let terms = lexicon.recognitionHints
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await CallSummariser.summarise(transcript, terms: terms)
            }.value
            self?.addSummary(result, to: transcript, savedAt: url)
        }
    }

    private func addSummary(_ result: CallSummaryState, to call: CallTranscript, savedAt url: URL) {
        // Usually the call is still the last one saved; it may have been moved
        // to another folder since, so use where it is now.
        if var saved = lastSaved, saved.transcript.started == call.started, saved.transcript.appName == call.appName {
            saved.transcript.summary = result
            lastSaved = saved
            if transcript?.started == call.started { transcript = saved.transcript }
            try? saved.transcript.markdown.write(to: saved.url, atomically: true, encoding: .utf8)
            return
        }
        // A newer call has been saved since. Find this one's note by name.
        guard let current = locate(url) else { return }
        var updated = call
        updated.summary = result
        let folder = current.deletingLastPathComponent().standardizedFileURL.path
        let calls = callsFolder.standardizedFileURL.path
        if folder.hasPrefix(calls + "/") { updated.category = String(folder.dropFirst(calls.count + 1)) }
        try? updated.markdown.write(to: current, atomically: true, encoding: .utf8)
    }

    /// Where a saved note is now: the same place, or another folder under Calls.
    private func locate(_ url: URL) -> URL? {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let enumerator = FileManager.default.enumerator(at: callsFolder, includingPropertiesForKeys: nil) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first { $0.lastPathComponent == url.lastPathComponent }
    }

    // MARK: - Filing

    /// Moves the last saved call into `folder` (a path under Calls, e.g.
    /// "1-1s/Sarah Jones") and remembers the choice for next time.
    func file(into folder: String) {
        guard let saved = lastSaved else { return }
        let cleaned = FolderName.clean(folder)
        guard !cleaned.isEmpty else { return leaveUnfiled() }
        if cleaned == saved.transcript.category {
            filing.learn(saved.features, folder: cleaned)
            filedNote = "Filed in \(cleaned)."
            state = .saved(saved.url)
            scheduleHide(after: 6)
            return
        }
        var moved = saved.transcript
        moved.category = cleaned
        do {
            let url = try save(moved)
            if url != saved.url { try? FileManager.default.removeItem(at: saved.url) }
            filing.learn(saved.features, folder: cleaned)
            lastSaved = (url, moved, saved.features)
            transcript = moved
            filedNote = "Filed in \(cleaned). Warble will remember this."
            state = .saved(url)
            scheduleHide(after: 8)
        } catch {
            lastError = "Couldn't move the transcript: \(error.localizedDescription)"
            state = .idle
            showErrorBriefly()
        }
    }

    /// Keeps the last call in Unfiled.
    func leaveUnfiled() {
        guard let saved = lastSaved else { state = .idle; return }
        if saved.transcript.category != "Unfiled" {
            file(into: "Unfiled")
            return
        }
        filedNote = "Left in Unfiled."
        state = .saved(saved.url)
        scheduleHide(after: 6)
    }

    /// Asks again where the last call should go ("Change folder").
    func changeFolder() {
        guard let saved = lastSaved else { return }
        hideTask?.cancel()
        filingSuggestions = filing.suggestions(for: saved.features)
            .filter { $0.folder != saved.transcript.category }
        state = .filing(saved.url)
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

    /// The card in the top-right corner: "Transcribe this call?", the live card
    /// while a call is transcribed (with "Who's this?"), the end-of-call steps,
    /// the saved transcript, or a problem.
    private var needsPanel: Bool {
        if lastError != nil && state == .idle { return true }
        if askingWho != nil { return true }
        switch state {
        case .asking, .recording, .saving, .saved, .filing: return true
        case .idle: return false
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

    /// Shows a problem in the card. It stays until you click OK, so it can't
    /// be missed.
    private func showErrorBriefly() {
        hideTask?.cancel()
        updatePanel()
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

/// Voice segments for a call that is finishing, so late arrivals from its
/// speaker recognition don't mix with the next call's.
@MainActor
final class VoiceBox {
    var segments: [VoiceSegment]
    init(_ segments: [VoiceSegment]) { self.segments = segments }
}
