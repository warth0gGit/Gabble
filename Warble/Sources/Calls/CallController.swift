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
        /// The full name behind the chip's short one ("Jordan Smith").
        var fullName: String? = nil
        /// Warble is guessing: shown as "Jordan?".
        var isTentative = false
        /// Voices that sound different but share this name ("Jordan ×2"); 1 normally.
        var shared = 1
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
    /// Calls whose summary is Apple's draft, waiting for Claude.
    let summaryQueue = SummaryQueue()
    private let calendar = CalendarLookup()
    private var meeting: MeetingInfo?
    /// The saved call waiting to be filed (or re-filed).
    private var lastSaved: (url: URL, transcript: CallTranscript, features: CallFeatures)?

    /// A voice Warble doesn't know yet, waiting for "Who is talking?".
    struct UnknownVoice: Equatable {
        var speakerID: String
        var sample: String
        /// A name said around when they started talking ("Thanks, Matt"), offered as a suggestion.
        var hint: String? = nil
        /// One-tap answers, best first (see `NameSuggestion.build`).
        var suggestions: [NameSuggestion] = []
        /// When Warble started asking, so the pill only pulses for a moment.
        var askedAt = Date()
    }
    @Published private(set) var askingWho: UnknownVoice?
    /// How sure Warble is of each voice's name on this call. A `.tentative`
    /// name shows as "Jordan?" and is never learned until you confirm it.
    @Published private(set) var nameConfidence: [String: NameConfidence] = [:]
    /// The last name you gave on this call, so it can be undone (and what
    /// Warble learned from it taken back out) until you name someone else.
    struct Naming: Equatable {
        var id = UUID()
        var voiceIDs: [String]
        var name: String
        var previousNames: [String: String]
        var previousConfidence: [String: NameConfidence]
        /// The voice recording Warble learned from this naming, once saved.
        var learned: UUID?
    }
    @Published private(set) var lastNaming: Naming?
    /// Namings undone before Warble finished learning from them.
    private var undoneNamings: Set<UUID> = []
    /// Voices you said to ask about after the call instead.
    @Published private(set) var deferredVoices: Set<String> = []
    /// "Don't ask during this call."
    @Published private(set) var askingPaused = false
    /// Turns an unanswered "Who's this?" into "ask me after the call".
    private var askTimeout: Task<Void, Never>?
    /// How long "Who's this?" waits for an answer before moving on.
    static let askTimeoutSeconds: TimeInterval = 60
    /// Voices Warble has learned, kept between calls.
    let voices = VoiceprintStore()
    /// Every stretch of the other side's speech this call, checked so people
    /// the voice engine lumped together are told apart (see VoiceSplitter).
    private var splitter = VoiceSplitter()
    private var voiceSegments: [VoiceSegment] { splitter.segments }
    private var namesThisCall: [String: String] = [:]
    private var skippedVoices: Set<String> = []
    /// Voices already compared with the people Warble knows (matched or not).
    private var voicesChecked: Set<String> = []
    private var voicesBeingChecked: Set<String> = []
    /// How much each voice had said when it was last compared.
    private var checkedAtTalk: [String: TimeInterval] = [:]
    /// A voice nobody recognised is compared again once it has said this
    /// much: five seconds of someone is often too little to know them by,
    /// and each extra stretch of speech makes them easier to tell apart
    /// (measured: about 80% of people known at 5 s, 94% at 15 s; see docs).
    private static let recheckAfter: [TimeInterval] = [8, 12, 20, 30, 45, 60, 90]
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
            .sink { [weak self] _ in
                // A shrunk card stays shrunk: the pill says "Who's this?" instead.
                self?.updatePanel()
            }
            .store(in: &cancellables)
        CallNotifier.shared.activate()

        summaryQueue.callsFolder = { [weak self] in
            self?.callsFolder ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
        summaryQueue.onReplaced = { [weak self] entry, summary in self?.summaryReplaced(entry, summary) }
    }

    /// Too busy for Warble to ask Claude about older calls.
    var isBusyForSummaries: Bool {
        switch state {
        case .recording, .saving: return true
        default: return false
        }
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
        splitter = VoiceSplitter()
        namesThisCall = [:]
        nameConfidence = [:]
        lastNaming = nil
        undoneNamings = []
        deferredVoices = []
        askingPaused = false
        askTimeout?.cancel()
        skippedVoices = []
        voicesChecked = []
        voicesBeingChecked = []
        checkedAtTalk = [:]
        askingWho = nil
        panelMinimized = false
        savedStats = nil
        hideTask?.cancel()
        self.recorder = recorder
        // Ready for going over the whole recording when the call ends.
        OfflineVoices.shared.prepare()
        transcript = recorder.transcript
        recordingStarted = Date()
        meeting = calendar.meeting(at: Date(), appName: app.name)
        state = .recording(appName: app.name)
        if appState.recognitionModel == .parakeet {
            // Have Parakeet ready by the time the call ends.
            ParakeetStatus.shared.warmUp()
        }
        do {
            try await recorder.start(hints: lexicon.recognitionHints)
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
            voices: voiceSegments, asking: askingWho?.speakerID, name: { [self] in voiceName($0) },
            confidence: nameConfidence, conflicted: conflictedNames())
        if updated != liveSpeakers { liveSpeakers = updated }
    }

    /// Names (lowercased) that two clearly different voices share on this
    /// call, e.g. AJ and Matt both matched to Jordan. Voices you joined
    /// yourself don't count.
    private func conflictedNames() -> Set<String> {
        var groups: [String: [String]] = [:]
        for (id, name) in namesThisCall { groups[name.lowercased(), default: []].append(id) }
        var conflicted = Set<String>()
        for (name, ids) in groups where ids.count > 1 {
            guard !ids.allSatisfy({ nameConfidence[$0] == .confirmed }) else { continue }
            let prints = ids.compactMap { splitter.fingerprint(for: $0) }
            outer: for i in prints.indices {
                for j in prints.indices where j > i && VoiceMatcher.distance(prints[i], prints[j]) > VoiceMatcher.tentativeDistance {
                    conflicted.insert(name)
                    break outer
                }
            }
        }
        return conflicted
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
                             name: (String) -> String,
                             confidence: [String: NameConfidence] = [:],
                             conflicted: Set<String> = []) -> [LiveSpeaker] {
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
        // On a big call show only the people heard most recently (and the voice
        // being asked about), in the order they joined, plus "+N" for the rest.
        var shown = order
        if order.count > maxChips {
            let lastHeard = voices.reduce(into: [String: TimeInterval]()) { $0[$1.speakerID] = max($0[$1.speakerID] ?? 0, $1.end) }
            var keep = Set(order.sorted { (lastHeard[$0] ?? 0) > (lastHeard[$1] ?? 0) }.prefix(maxChips))
            if let asking, order.contains(asking), !keep.contains(asking) {
                if let drop = order.filter({ keep.contains($0) }).min(by: { (lastHeard[$0] ?? 0) < (lastHeard[$1] ?? 0) }) {
                    keep.remove(drop)
                }
                keep.insert(asking)
            }
            shown = order.filter { keep.contains($0) }
        }
        // One person the voice engine split in two shows as one chip.
        var seenNames = Set<String>()
        shown = shown.filter { id in
            id == asking || name(id).hasPrefix("Speaker ") || seenNames.insert(name(id).lowercased()).inserted
        }
        let latestName = latest.map(name)
        let short = chipNames(order.map(name))
        for id in shown {
            let full = name(id)
            let sameName = order.filter { $0 != asking && name($0).lowercased() == full.lowercased() }
            list.append(LiveSpeaker(id: id, name: id == asking ? "New voice" : short[full] ?? full,
                                    isNew: id == asking,
                                    isSpeaking: othersTalking && (id == latest || (id != asking && full == latestName && latest != asking)),
                                    fullName: id == asking ? nil : full,
                                    isTentative: id != asking && sameName.contains { confidence[$0] == .tentative },
                                    shared: id != asking && conflicted.contains(full.lowercased()) ? max(2, sameName.count) : 1))
        }
        let hidden = Set(order.filter { !shown.contains($0) }.map { name($0).lowercased() })
            .subtracting(shown.map { name($0).lowercased() })
        if !hidden.isEmpty {
            list.append(LiveSpeaker(id: "more", name: "+\(hidden.count)"))
        }
        return list
    }

    /// Most chips for people on the other side; more are summed up as "+N".
    static let maxChips = 4

    /// First names for the chips ("Jala"), with a surname initial when two
    /// people share a first name ("Jonathan Y", "Jonathan S"). Labels like
    /// "Speaker 2" stay as they are. Pure, unit tested.
    static func chipNames(_ names: [String]) -> [String: String] {
        func parts(_ name: String) -> [String] { name.split(separator: " ").map(String.init) }
        func isLabel(_ name: String) -> Bool { parts(name).count < 2 || parts(name).last.map { Int($0) != nil } == true }
        var firstCounts: [String: Int] = [:]
        for name in Set(names) where !isLabel(name) { firstCounts[parts(name)[0].lowercased(), default: 0] += 1 }
        var result: [String: String] = [:]
        for name in names {
            guard !isLabel(name) else { result[name] = name; continue }
            let p = parts(name)
            result[name] = (firstCounts[p[0].lowercased()] ?? 0) > 1 ? "\(p[0]) \(p.last!.prefix(1))" : p[0]
        }
        return result
    }

    private func stopAndSave() async {
        guard let recorder else { return }
        // Take everything about this call now. Saving can take a while (Parakeet
        // re-reads the whole recording), and with back-to-back calls the next
        // call can start meanwhile; it must find Warble ready, not busy.
        self.recorder = nil
        stopSpeakerMeter()
        let heard = VoiceBox(splitter)
        // Guesses ("Jordan?") are never learned, never attract other voices
        // and aren't handed to the review; they only label the transcript
        // when there's no review to go by.
        let guessedIDs = Set(nameConfidence.filter { $0.value == .tentative }.map(\.key))
        var names = namesThisCall.filter { !guessedIDs.contains($0.key) }
        let guesses = namesThisCall.filter { guessedIDs.contains($0.key) }
        let namedLive = Set(namesThisCall.filter { nameConfidence[$0.key] == .confirmed }.values.map { $0.lowercased() })
        let checked = voicesChecked
        lastNaming = nil
        askTimeout?.cancel()
        recorder.onVoices = { segments in heard.splitter.add(segments) }
        recorder.onUpdate = nil
        let callMeeting = meeting
        meeting = nil
        askingWho = nil
        recordingStarted = nil
        liveMe = ""
        liveOthers = ""
        panelMinimized = false
        savingRereads = appState.recognitionModel == .parakeet
        summaryWillFollow = CallSummariser.canSummarise
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
        var voicesHeard = heard.splitter.segments
        // Voices that only became clear at the end of the call get the same strict check.
        let talk = SpeakerAssigner.talkTime(voicesHeard)
        let known = voices.voices
        if !known.isEmpty || !names.isEmpty {
            // The people named on this call, so a leftover piece of their voice
            // joins them instead of being matched to someone from another call.
            var onCall: [Voiceprint] = []
            for (otherID, name) in names {
                if let other = await Self.fingerprint(otherID, heard.splitter, recorder.speakers) {
                    onCall.append(Voiceprint(name: name, embedding: other))
                }
            }
            for id in Set(voicesHeard.map(\.speakerID)) where names[id] == nil && !checked.contains(id) && !guessedIDs.contains(id) && (talk[id] ?? 0) >= 3 {
                guard let embedding = await Self.fingerprint(id, heard.splitter, recorder.speakers) else { continue }
                if let name = VoiceMatcher.matchInCall(embedding, onCall: onCall, saved: []) {
                    names[id] = name
                } else if let name = VoiceMatcher.match(embedding, known: known, within: VoiceMatcher.afterCallDistance) {
                    // Nobody saw this name during the call, so only a very close match counts.
                    names[id] = name
                }
            }
        }
        // Go over the whole recording of the other side, which tells people
        // apart better than the live check, and put the names on its voices.
        var reviewPrints: [String: [Float]]?
        let liveNames = names
        var reviewHeard: [VoiceSegment]?
        if let others = recorder.recordings.first(where: { $0.speaker == CallRecorder.othersLabel }) {
            let minutes = finished.duration / 60
            let file = others.file
            if let found = await withDeadline(seconds: 30 + minutes * 4, { await OfflineVoices.shared.voices(in: file) }) ?? nil {
                let shifted = found.segments.map { segment -> VoiceSegment in
                    var s = segment
                    s.start += others.startOffset
                    s.end += others.startOffset
                    return s
                }
                if let reviewed = VoiceReview.relabel(review: shifted, live: voicesHeard, names: names,
                                                      fingerprints: found.fingerprints) {
                    voicesHeard = reviewed.segments
                    names = reviewed.names
                    reviewHeard = reviewed.segments
                    // Each of the recording's voices, in the same terms as the
                    // people Warble knows. A voice nobody named that clearly
                    // is someone from an earlier call gets their name.
                    let prints = VoiceReview.prints(review: reviewed.segments, live: heard.splitter.segments)
                    reviewPrints = prints
                    var used = Set(names.values.map { $0.lowercased() })
                    for (voice, print) in prints where names[voice] == nil {
                        if let name = VoiceMatcher.match(print, known: known, within: VoiceMatcher.afterCallDistance),
                           used.insert(name.lowercased()).inserted {
                            names[voice] = name
                        }
                    }
                }
            }
        }
        // How each person named sounded over this whole call joins what
        // Warble knows of them, so they're recognised on the next call even if
        // Teams makes them sound a bit different (one recording wasn't enough).
        // The recording's voices are used when there are any: they keep
        // people apart better than the live check.
        // How each voice sounds, for spotting two people under one name and
        // for learning names you confirm in "Check who spoke".
        var checkPrints: [String: [Float]] = reviewPrints ?? [:]
        for id in Set(voicesHeard.map(\.speakerID)) where checkPrints[id] == nil {
            if let print = heard.splitter.callPrint(for: id, atLeast: 2) ?? heard.splitter.fingerprint(for: id) {
                checkPrints[id] = print
            }
        }
        // A name two clearly different voices ended up with isn't learned
        // until you say which voice is them.
        let finalTalk = SpeakerAssigner.talkTime(voicesHeard)
        let sharedNames = SpeakerCheck.sharedNames(order: Array(finalTalk.keys), names: names, prints: checkPrints)
        var learned = Set<String>()
        var learnedAtSave: [String: UUID] = [:]
        for id in names.keys.sorted(by: { (finalTalk[$0] ?? 0) > (finalTalk[$1] ?? 0) }) {
            guard let name = names[id], !learned.contains(name.lowercased()), !sharedNames.contains(name.lowercased()),
                  let print = reviewPrints?[id] ?? heard.splitter.callPrint(of: name, names: liveNames) else { continue }
            learned.insert(name.lowercased())
            if let label = voices.reinforce(name: name, embedding: print) { learnedAtSave[id] = label }
        }
        // With no review, a guessed voice keeps its guess in the transcript, marked "?".
        if reviewHeard == nil {
            for (id, name) in guesses where names[id] == nil { names[id] = name + "?" }
        }
        // What the voice checks heard and decided, kept with the recordings.
        VoiceLog(live: heard.splitter.segments, liveNames: liveNames, review: reviewHeard, names: names,
                 settings: VoiceLog.currentSettings).save(in: recorder.folder)
        // Your mic picks up the others through your speakers; drop those echoes.
        finished.segments = EchoFilter.removeEchoes(from: finished.segments)
        finished.relabel { [self] segment in label(for: segment, voices: voicesHeard, names: names) }
        // Word List fixes, then the light tidy-up (on every call, however short).
        finished.segments = finished.segments.compactMap { segment in
            var s = segment
            s.text = TextCleaner.tidyCall(TextCleaner.applyReplacements(s.text, lexicon.replacements))
            return s.text.isEmpty ? nil : s
        }
        finished.meeting = callMeeting ?? calendar.meeting(at: finished.started, appName: finished.appName)
        // "Check who spoke": only when a voice is unnamed, guessed or shared.
        let othersRecording = recorder.recordings.first { $0.speaker == CallRecorder.othersLabel }
        let lines = finished.segments
        var checkRows = SpeakerCheck.rows(voices: voicesHeard, names: names, namedLive: namedLive,
                                          prints: checkPrints) { id in
            Self.quote(of: id, in: lines, voices: voicesHeard)
        }
        let namesOnCall = Set(checkRows.compactMap { $0.name?.lowercased() })
        for index in checkRows.indices where checkRows[index].status == .unnamed || checkRows[index].status == .guess {
            guard let print = checkPrints[checkRows[index].id] else { continue }
            let candidates = VoiceMatcher.candidates(print, known: voices.voices, limit: 3)
                .filter { !namesOnCall.contains($0.name.lowercased()) || $0.name.caseInsensitiveCompare(checkRows[index].name ?? "") == .orderedSame }
            checkRows[index].suggestions = NameSuggestion.build(hint: nil, candidates: candidates, onCall: [])
        }
        let check: SpeakerCheck? = checkRows.contains(where: \.needsCheck)
            ? SpeakerCheck(rows: checkRows, url: URL(fileURLWithPath: "/"), started: finished.started,
                           othersFile: othersRecording?.file, othersOffset: othersRecording?.startOffset ?? 0,
                           voices: voicesHeard, prints: checkPrints, learnedAtSave: learnedAtSave)
            : nil
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
            // With speakers to check on the card, the summary waits for Done
            // or Later (or three minutes), so it uses the right names.
            let holdSummary = finished.summary == .pending && check != nil && shownHere
            if finished.summary == .pending && !holdSummary { summarise(finished, savedAt: url) }
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
            if var check {
                check.url = url
                speakerCheck = check
                if holdSummary { holdSummaryForCheck(finished, savedAt: url) }
            } else {
                speakerCheck = nil
            }
            if let sure {
                filedNote = "Filed in \(sure.folder) (\(sure.reason))."
                state = .saved(url)
                if speakerCheck == nil { scheduleHide(after: 10) } else { hideTask?.cancel() }
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

    // MARK: - Check who spoke

    /// The last saved call's "Check who spoke", while it has rows to show.
    @Published private(set) var speakerCheck: SpeakerCheck?
    /// The summary waiting for the check to be done.
    private var heldSummary: (transcript: CallTranscript, url: URL)?
    private var heldSummaryTask: Task<Void, Never>?
    /// The check changed names after the summary was written.
    private var checkChangedAfterSummary = false
    /// Plays the 4-second clips.
    let clips = ClipPlayer()

    /// A line a voice said, for recognising them. Pure.
    nonisolated static func quote(of id: String, in lines: [CallTranscript.Segment], voices: [VoiceSegment]) -> String {
        let theirs = lines.filter { line in
            line.speaker != CallRecorder.meLabel
                && SpeakerAssigner.speaker(for: CallTranscript.spokenRange(of: line), in: voices) == id
        }
        guard let best = theirs.max(by: { $0.text.count < $1.text.count }) else { return "" }
        return best.text.count > 90 ? String(best.text.prefix(88)) + "…" : best.text
    }

    private func holdSummaryForCheck(_ transcript: CallTranscript, savedAt url: URL) {
        heldSummary = (transcript, url)
        heldSummaryTask?.cancel()
        heldSummaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.releaseHeldSummary()
        }
    }

    /// Starts the summary that was waiting, with the names as they are now.
    private func releaseHeldSummary() {
        heldSummaryTask?.cancel()
        guard let held = heldSummary else { return }
        heldSummary = nil
        if let saved = lastSaved, saved.transcript.started == held.transcript.started {
            summarise(saved.transcript, savedAt: saved.url)
        } else {
            summarise(held.transcript, savedAt: held.url)
        }
    }

    /// Plays (or stops) a row's clip.
    func playClip(_ rowID: String) {
        guard let check = speakerCheck, let row = check.rows.first(where: { $0.id == rowID }),
              let clip = row.clip, let file = check.othersFile else { return }
        if clips.playing == rowID { return clips.stop() }
        clips.play(rowID, file: file, from: clip.lowerBound - check.othersOffset, length: clip.upperBound - clip.lowerBound)
    }

    /// "This is Jordan" / "It's Matt Kern" / a typed name / "Not AJ?" → name:
    /// the row gets that name and is marked confirmed (learned on Done).
    func checkName(_ rowID: String, as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var check = speakerCheck,
              let index = check.rows.firstIndex(where: { $0.id == rowID }) else { return }
        let changed = check.rows[index].name?.caseInsensitiveCompare(trimmed) != .orderedSame
        check.rows[index].name = trimmed
        check.rows[index].confirmed = true
        // Once the rows sharing a name are each told apart, they aren't shared any more.
        let shared = SpeakerCheck.sharedNames(order: check.rows.map(\.id),
                                              names: Dictionary(uniqueKeysWithValues: check.rows.compactMap { row in row.name.map { (row.id, $0) } }),
                                              prints: check.prints)
        for i in check.rows.indices where check.rows[i].status == .shared
            && !shared.contains((check.rows[i].name ?? "").lowercased()) {
            check.rows[i].status = check.rows[i].confirmed ? .namedLive : .recognised
            check.rows[i].part = nil
        }
        speakerCheck = check
        if changed { applyCheckNames() }
    }

    /// "Same as…": the row is the same person as another row.
    func checkSame(_ rowID: String, as otherID: String) {
        guard let name = speakerCheck?.rows.first(where: { $0.id == otherID })?.name else { return }
        checkName(rowID, as: name)
    }

    /// Rewrites the saved note with the check's names.
    private func applyCheckNames() {
        guard let check = speakerCheck, var saved = lastSaved, saved.transcript.started == check.started else { return }
        check.relabel(&saved.transcript) { [self] id in voiceName(id, voices: check.voices, names: [:]) }
        do {
            let url = try save(saved.transcript)
            if url != saved.url { try? FileManager.default.removeItem(at: saved.url) }
            saved.url = url
            lastSaved = saved
            if transcript?.started == saved.transcript.started { transcript = saved.transcript }
            if heldSummary == nil { checkChangedAfterSummary = true }
        } catch {
            lastError = "Couldn't update the speaker names: \(error.localizedDescription)"
        }
    }

    /// Done: Warble learns the voices you confirmed (and takes back out what
    /// it learned for a name you corrected). Rows you left alone aren't
    /// learned. Then the summary is written (again, if names changed after it).
    func finishCheck() {
        guard var check = speakerCheck else { return }
        clips.stop()
        for row in check.rows where row.confirmed {
            guard let name = row.name, let print = check.prints[row.id] else { continue }
            if let label = check.learnedAtSave[row.id] { voices.unlearn(label) }
            if let label = voices.remember(name: name, embedding: print) { check.learnedAtSave[row.id] = label }
        }
        check.finished = true
        speakerCheck = check
        endCheck()
    }

    /// Later: nothing more is learned now; the check stays on the Calls page.
    func postponeCheck() {
        clips.stop()
        speakerCheck?.finished = true
        endCheck()
    }

    private func endCheck() {
        if heldSummary != nil {
            releaseHeldSummary()
        } else if checkChangedAfterSummary, let saved = lastSaved, saved.transcript.summary != .none {
            summarise(saved.transcript, savedAt: saved.url)
        }
        checkChangedAfterSummary = false
        if case .saved = state { scheduleHide(after: 3) }
        updatePanel()
    }

    /// Opens the last call's check again (from the Calls page).
    func reopenCheck() {
        guard speakerCheck != nil else { return }
        speakerCheck?.finished = false
    }

    // MARK: - Voices

    private func heard(_ segments: [VoiceSegment]) {
        splitter.add(segments)
        checkNewVoicesAgainstKnownPeople()
        askAboutNextUnknownVoice()
    }

    /// Named, and not just a guess. A guessed ("Jordan?") voice keeps being
    /// checked as it says more, so the guess can firm up.
    private func isKnown(_ speakerID: String) -> Bool {
        namesThisCall[speakerID] != nil && nameConfidence[speakerID] != .tentative
    }

    /// Once a new voice has said enough, compares it with the people Warble
    /// knows. Only a clear match is named; anyone else gets "Who's this?".
    private func checkNewVoicesAgainstKnownPeople() {
        guard let speakers = recorder?.speakers else { return }
        let talk = SpeakerAssigner.talkTime(voiceSegments)
        for id in Set(voiceSegments.map(\.speakerID)) where !voicesBeingChecked.contains(id) && !isKnown(id) {
            let spoken = talk[id] ?? 0
            guard spoken >= askAfterSeconds else { continue }
            if voicesChecked.contains(id) {
                // Not recognised last time: try again once they've said more.
                let last = checkedAtTalk[id] ?? 0
                guard Self.recheckAfter.contains(where: { $0 > last && spoken >= $0 }) else { continue }
            }
            checkedAtTalk[id] = spoken
            guard !voices.voices.isEmpty || !namesThisCall.isEmpty else { voicesChecked.insert(id); continue }
            voicesBeingChecked.insert(id)
            let known = voices.voices
            // A shaky guess mustn't attract other voices to its name.
            let named = namesThisCall.filter { nameConfidence[$0.key] != .tentative }
            let prints = splitter
            Task { [weak self] in
                let embedding = await Self.fingerprint(id, prints, speakers)
                // Everything this voice has said so far, for comparing with
                // people from earlier calls.
                let heardSoFar = prints.callPrint(for: id, atLeast: 2)
                // The people already named on this call, as they sound today.
                var onCall: [Voiceprint] = []
                for (otherID, name) in named where otherID != id {
                    if let other = await Self.fingerprint(otherID, prints, speakers) {
                        onCall.append(Voiceprint(name: name, embedding: other))
                    }
                }
                guard let self else { return }
                self.voicesBeingChecked.remove(id)
                self.voicesChecked.insert(id)
                let undecided = self.namesThisCall[id] == nil || self.nameConfidence[id] == .tentative
                if let embedding, undecided, self.checkedAtTalk[id] != .infinity,
                   let guess = VoiceMatcher.guessInCall(embedding, onCall: onCall, saved: known, heard: heardSoFar) {
                    self.namesThisCall[id] = guess.name
                    self.nameConfidence[id] = guess.confidence
                    // Recognised (or at least a good guess) now they've said more: no need to ask.
                    if self.askingWho?.speakerID == id { self.askingWho = nil }
                    self.refreshLiveSpeakers()
                }
                self.askAboutNextUnknownVoice()
            }
        }
    }

    private func askAboutNextUnknownVoice() {
        guard isRecording, askingWho == nil, !askingPaused else { return }
        let talk = SpeakerAssigner.talkTime(voiceSegments)
        let firstHeard = voiceSegments.map(\.speakerID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard let id = firstHeard.first(where: {
            namesThisCall[$0] == nil && voicesChecked.contains($0) && !skippedVoices.contains($0) && (talk[$0] ?? 0) >= askAfterSeconds
        }) else { return }
        ask(about: id)
    }

    /// Shows "Who's this?" for a voice, then fills in one-tap suggestions:
    /// a name heard said, the people on file it sounds most like, and (only
    /// when the voices really are close) someone already on this call.
    private func ask(about id: String, excluding excluded: String? = nil) {
        let hint = nameHint(for: id).flatMap { $0.caseInsensitiveCompare(excluded ?? "") == .orderedSame ? nil : $0 }
        askingWho = UnknownVoice(speakerID: id, sample: sample(for: id), hint: hint,
                                 suggestions: NameSuggestion.build(hint: hint, candidates: [], onCall: []))
        restartAskTimeout()
        guard let speakers = recorder?.speakers else { return }
        let prints = splitter
        let known = voices.voices
        let named = namesThisCall.filter { $0.key != id && nameConfidence[$0.key] != .tentative }
        Task { [weak self] in
            guard let embedding = await Self.fingerprint(id, prints, speakers) else { return }
            var onCall: [(name: String, voiceID: String, distance: Float)] = []
            for (otherID, name) in named {
                if let other = await Self.fingerprint(otherID, prints, speakers) {
                    onCall.append((name, otherID, VoiceMatcher.distance(embedding, other)))
                }
            }
            let onCallNames = Set(named.values.map { $0.lowercased() })
            let candidates = VoiceMatcher.candidates(embedding, known: known, limit: 3).filter {
                // Someone already on this call is only offered as "Same person as…".
                !onCallNames.contains($0.name.lowercased())
                    && $0.name.caseInsensitiveCompare(excluded ?? "") != .orderedSame
            }
            let close = onCall.filter {
                $0.distance <= VoiceMatcher.tentativeDistance && $0.name.caseInsensitiveCompare(excluded ?? "") != .orderedSame
            }
            guard let self, self.askingWho?.speakerID == id else { return }
            self.askingWho?.suggestions = NameSuggestion.build(hint: hint, candidates: candidates,
                                                               onCall: close.map { ($0.name, $0.voiceID, $0.distance) })
        }
    }

    /// Starts (again) the minute "Who's this?" waits before moving on.
    func restartAskTimeout() {
        askTimeout?.cancel()
        guard let id = askingWho?.speakerID else { return }
        askTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.askTimeoutSeconds))
            guard !Task.isCancelled, let self, self.askingWho?.speakerID == id else { return }
            self.deferVoice()
        }
    }

    /// A name said just before this voice first spoke, or by the voice itself.
    private func nameHint(for speakerID: String) -> String? {
        guard let first = voiceSegments.first(where: { $0.speakerID == speakerID })?.start else { return nil }
        let lines = transcript?.segments ?? []
        let own = lines.filter { segment in
            segment.speaker == CallRecorder.othersLabel
                && SpeakerAssigner.speaker(for: CallTranscript.spokenRange(of: segment), in: voiceSegments) == speakerID
        }.prefix(3).map(\.text)
        let before = lines.filter { segment in
            let spoken = CallTranscript.spokenRange(of: segment)
            return spoken.upperBound <= first + 1 && spoken.upperBound >= first - 20
        }.map(\.text)
        return NameHints.guess(own: Array(own), before: before, taken: Array(Set(namesThisCall.values)))
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
        guard !trimmed.isEmpty else { return deferVoice() }
        askingWho = nil
        askTimeout?.cancel()
        assign([asking.speakerID], name: trimmed, learnFrom: asking.speakerID)
    }

    /// A one-tap suggestion on "Who's this?": a name, or "Same person as AJ"
    /// (joins the new voice to that voice on this call).
    func choose(_ suggestion: NameSuggestion) {
        if let other = suggestion.joins, let name = namesThisCall[other] {
            nameVoice(name)
        } else {
            nameVoice(suggestion.name)
        }
    }

    /// Kept for older callers: joins the voice being asked about to someone on the call.
    func joinAskingVoice(to speakerID: String) {
        guard let name = namesThisCall[speakerID] else { return }
        nameVoice(name)
    }

    /// "Yes, it's Jordan" on a "Jordan?" chip: the guess becomes a name you
    /// gave, and Warble learns the voice.
    func confirmVoice(_ speakerID: String) {
        guard isRecording, let name = namesThisCall[speakerID] else { return }
        let guessed = namesThisCall.filter {
            $0.value.caseInsensitiveCompare(name) == .orderedSame && nameConfidence[$0.key] == .tentative
        }.map(\.key)
        guard !guessed.isEmpty else { return }
        let latest = voiceSegments.last { guessed.contains($0.speakerID) }?.speakerID ?? guessed[0]
        assign(guessed.sorted(), name: name, learnFrom: latest)
    }

    /// Gives `ids` a name you chose, learns the voice (from `learnFrom`) and
    /// keeps what's needed to undo it.
    private func assign(_ ids: [String], name: String, learnFrom: String) {
        var naming = Naming(voiceIDs: ids, name: name, previousNames: [:], previousConfidence: [:], learned: nil)
        for id in ids {
            naming.previousNames[id] = namesThisCall[id]
            naming.previousConfidence[id] = nameConfidence[id]
            namesThisCall[id] = name
            nameConfidence[id] = .confirmed
            skippedVoices.remove(id)
            deferredVoices.remove(id)
        }
        lastNaming = naming
        refreshLiveSpeakers()
        let namingID = naming.id
        let speakers = recorder?.speakers
        let prints = splitter
        Task { [weak self] in
            // How this voice sounded on this call, not the engine's blend, so
            // the right voice is remembered for next time.
            if let speakers, let embedding = await Self.fingerprint(learnFrom, prints, speakers),
               let self, let label = self.voices.remember(name: name, embedding: embedding) {
                if self.undoneNamings.contains(namingID) {
                    self.voices.unlearn(label)   // undone while it was being learned
                } else if self.lastNaming?.id == namingID {
                    self.lastNaming?.learned = label
                }
            }
            self?.askAboutNextUnknownVoice()
        }
    }

    /// Undo for the last name you gave: the voices go back to what they were
    /// and what Warble learned from it is taken back out. A voice left with
    /// no name is asked about again.
    func undoLastNaming() {
        guard let naming = lastNaming else { return }
        lastNaming = nil
        for id in naming.voiceIDs {
            namesThisCall[id] = naming.previousNames[id]
            nameConfidence[id] = naming.previousConfidence[id]
        }
        if let label = naming.learned { voices.unlearn(label) } else { undoneNamings.insert(naming.id) }
        refreshLiveSpeakers()
        if let id = naming.voiceIDs.first(where: { namesThisCall[$0] == nil }), isRecording {
            askTimeout?.cancel()
            askingWho = nil
            ask(about: id, excluding: naming.name)
        }
    }

    /// "No, someone else" on a chip: the person talking now isn't them.
    /// For a guess ("Jordan?"), the whole voice loses the guessed name and
    /// Warble asks who it is. For a name you gave or Warble was sure of,
    /// their recent speech becomes a voice of its own and Warble asks who it
    /// is; everything said before keeps the old name (check it after the
    /// call). Either way the rejected name isn't suggested.
    func relabelVoice(_ speakerID: String) {
        guard isRecording, !["you", "others", "more"].contains(speakerID) else { return }
        // One person can be several voices; use the one heard most recently.
        let name = voiceName(speakerID)
        let latest = voiceSegments.last { voiceName($0.speakerID) == name }?.speakerID ?? speakerID
        askTimeout?.cancel()
        askingWho = nil
        if nameConfidence[latest] == .tentative {
            namesThisCall[latest] = nil
            nameConfidence[latest] = nil
            voicesChecked.insert(latest)
            checkedAtTalk[latest] = .infinity   // you said who it isn't; ask, don't guess
            skippedVoices.remove(latest)
            ask(about: latest, excluding: name)
        } else if let split = splitter.splitRecent(of: latest) {
            voicesChecked.insert(split)
            checkedAtTalk[split] = .infinity
            ask(about: split, excluding: name)
        } else {
            skippedVoices.remove(latest)
            ask(about: latest, excluding: name)
        }
        refreshLiveSpeakers()
    }

    /// "Name the one talking now" on a "Jordan ×2" chip: asks who the voice
    /// heard most recently under that name is.
    func askAboutSharedName(_ speakerID: String) {
        guard isRecording else { return }
        let name = voiceName(speakerID)
        guard let latest = voiceSegments.last(where: { voiceName($0.speakerID) == name })?.speakerID else { return }
        askTimeout?.cancel()
        askingWho = nil
        ask(about: latest)
    }

    /// How long ago a voice last spoke, or nil if Warble can't tell.
    func secondsSinceHeard(_ speakerID: String) -> TimeInterval? {
        guard let started = recordingStarted,
              let end = voiceSegments.filter({ $0.speakerID == speakerID }).map(\.end).max() else { return nil }
        return max(0, Date().timeIntervalSince(started) - end)
    }

    /// A voice's fingerprint from this call: Warble's own (see VoiceSplitter),
    /// else the voice engine's.
    nonisolated static func fingerprint(_ id: String, _ splitter: VoiceSplitter,
                                        _ speakers: SpeakerIdentifier) async -> [Float]? {
        if let print = splitter.fingerprint(for: id) { return print }
        return await speakers.embedding(for: id)
    }

    /// "Ask me after the call" (also Esc, or a minute with no answer): this
    /// voice is named in the after-call check instead.
    func deferVoice() {
        guard let asking = askingWho else { return }
        askTimeout?.cancel()
        skippedVoices.insert(asking.speakerID)
        deferredVoices.insert(asking.speakerID)
        askingWho = nil
        askAboutNextUnknownVoice()
    }

    func skipVoice() { deferVoice() }

    /// "Don't ask during this call": every voice left is named after the call.
    func pauseAsking() {
        askingPaused = true
        deferVoice()
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
        var unknown: [String] = []
        for speaker in heard.map(\.speakerID)
        where !unknown.contains(speaker) && names[speaker] == nil {
            unknown.append(speaker)
        }
        let number = (unknown.firstIndex(of: id) ?? 0) + 2
        return "Speaker \(number)"
    }

    // MARK: - Summary

    /// Whether to write a summary, so the note can say one is on its way (or why not).
    private func initialSummaryState(for transcript: CallTranscript) -> CallSummaryState {
        guard CallSummariser.isWorthSummarising(transcript) else { return .none }
        guard CallSummariser.canSummarise else {
            return .failed(SmartCleanup.unavailableReason ?? "Apple Intelligence isn't available on this Mac.")
        }
        return .pending
    }

    /// Writes the summary in the background, then adds it to the saved note.
    /// The transcript is already saved, and filing carries on meanwhile.
    private func summarise(_ transcript: CallTranscript, savedAt url: URL) {
        let terms = lexicon.recognitionHints
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                await CallSummariser.summarise(transcript, terms: terms)
            }.value
            guard let self else { return }
            let written = self.addSummary(outcome.state, to: transcript, savedAt: url)
            // Claude couldn't answer (e.g. its usage limit): Apple's draft is in
            // the note for now, and Warble asks Claude again later.
            if outcome.retryWithClaude, let written {
                self.summaryQueue.add(transcript, terms: terms, savedAt: written, problem: outcome.claudeProblem)
            }
        }
    }

    /// Adds the summary to the saved note, and says where the note is.
    @discardableResult
    private func addSummary(_ result: CallSummaryState, to call: CallTranscript, savedAt url: URL) -> URL? {
        // Usually the call is still the last one saved; it may have been moved
        // to another folder since, so use where it is now.
        let corrections = result.summary?.corrections ?? []
        if var saved = lastSaved, saved.transcript.started == call.started, saved.transcript.appName == call.appName {
            saved.transcript.summary = result
            saved.transcript.apply(corrections)
            lastSaved = saved
            if transcript?.started == call.started { transcript = saved.transcript }
            guard (try? saved.transcript.markdown.write(to: saved.url, atomically: true, encoding: .utf8)) != nil else { return nil }
            return saved.url
        }
        // A newer call has been saved since. Find this one's note by name.
        guard let current = locate(url) else { return nil }
        var updated = call
        updated.summary = result
        updated.apply(corrections)
        let folder = current.deletingLastPathComponent().standardizedFileURL.path
        let calls = callsFolder.standardizedFileURL.path
        if folder.hasPrefix(calls + "/") { updated.category = String(folder.dropFirst(calls.count + 1)) }
        guard (try? updated.markdown.write(to: current, atomically: true, encoding: .utf8)) != nil else { return nil }
        return current
    }

    /// Claude has replaced Apple's draft in a note (see SummaryQueue). If it's
    /// the call on the card, keep its summary in step, so renaming or filing
    /// it doesn't bring the draft back.
    private func summaryReplaced(_ entry: SummaryQueue.Entry, _ summary: CallSummary) {
        guard var saved = lastSaved, saved.transcript.started == entry.started,
              saved.transcript.appName == entry.appName else { return }
        saved.transcript.summary = .done(summary)
        saved.transcript.apply(summary.corrections)
        if let moved = summaryQueue.locate(entry) { saved.url = moved }
        lastSaved = saved
        if transcript?.started == entry.started { transcript = saved.transcript }
    }

    /// Where a saved note is now: the same place, or another folder under Calls.
    private func locate(_ url: URL) -> URL? {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let enumerator = FileManager.default.enumerator(at: callsFolder, includingPropertiesForKeys: nil) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first { $0.lastPathComponent == url.lastPathComponent }
    }

    // MARK: - Filing

    /// Gives the last saved call your own name ("Orchestrate sandbox review");
    /// the note becomes "2026-11-03 1229 Orchestrate sandbox review.md".
    func renameCall(_ name: String) {
        guard var saved = lastSaved else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != saved.transcript.customName else { return }
        saved.transcript.customName = trimmed
        do {
            let url = try save(saved.transcript)
            if url != saved.url { try? FileManager.default.removeItem(at: saved.url) }
            lastSaved = (url, saved.transcript, saved.features)
            transcript = saved.transcript
            state = .saved(url)
        } catch {
            lastError = "Couldn't rename the transcript: \(error.localizedDescription)"
            showErrorBriefly()
        }
    }

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
    var splitter: VoiceSplitter
    init(_ splitter: VoiceSplitter) { self.splitter = splitter }
}
