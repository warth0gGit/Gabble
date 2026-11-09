import FluidAudio
import Foundation

/// After a call, the voice engine goes over the whole recording of the other
/// side in one go. That tells people apart much better than the live check,
/// which only ever hears ten seconds at a time. The names you gave during the
/// call are then put on the right voices (see VoiceReview).
final class OfflineVoices: @unchecked Sendable {
    static let shared = OfflineVoices()

    private final class Loaded: @unchecked Sendable {
        let manager: OfflineDiarizerManager
        init(_ manager: OfflineDiarizerManager) { self.manager = manager }
    }

    private let lock = NSLock()
    private var loading: Task<Loaded?, Never>?

    /// Downloads the models the first time (done while a call is recorded, so
    /// they're ready when it ends), then loads them.
    func prepare() {
        _ = models()
    }

    private func models() -> Task<Loaded?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let loading { return loading }
        let task = Task.detached(priority: .utility) { () -> Loaded? in
            let manager = OfflineDiarizerManager()
            do {
                try await manager.prepareModels()
                return Loaded(manager)
            } catch {
                return nil
            }
        }
        loading = task
        return task
    }

    /// Who spoke when in a recording, timed from the start of the file, and
    /// each voice's fingerprint, or nil.
    func voices(in file: URL) async -> (segments: [VoiceSegment], fingerprints: [String: [Float]])? {
        guard let loaded = await models().value else {
            // Try again next time (e.g. no internet for the first download).
            lock.lock()
            loading = nil
            lock.unlock()
            return nil
        }
        guard let result = try? await loaded.manager.process(file) else { return nil }
        let segments = result.segments.map {
            VoiceSegment(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        return (segments, result.speakerDatabase ?? [:])
    }
}

/// Puts the names from the live call on the voices found in the recording.
/// Pure, unit tested.
enum VoiceReview {
    /// Each person's first this-many seconds on the live call count extra:
    /// that's when you named them, so it's the surest guide to their voice.
    static let namingSeconds: TimeInterval = 30
    static let namingWeight: Double = 4
    /// Voices with less talk than this don't count when comparing the two.
    static let minimumTalk: TimeInterval = 10
    /// A voice in the recording this close to a named one is the same person
    /// the recording split in two, and gets their name too.
    static let samePersonDistance: Float = 0.4

    /// The recording's voices, named, or nil to keep the live result. Each
    /// name goes to the voice it overlaps most (one name per voice), so two
    /// people the live check lumped together under one name can't both keep
    /// it: the one who isn't that person is left as "Speaker N" rather than
    /// given the wrong name. If the recording finds fewer people than the call
    /// had names, it has merged voices, and the live result is kept.
    static func relabel(review: [VoiceSegment], live: [VoiceSegment], names: [String: String],
                        fingerprints: [String: [Float]] = [:]) -> (segments: [VoiceSegment], names: [String: String])? {
        guard !review.isEmpty else { return nil }
        let reviewTalk = SpeakerAssigner.talkTime(review)

        // How long each name spoke on the live call, and its first stretch.
        var nameTalk: [String: TimeInterval] = [:]
        var weighted: [(name: String, start: TimeInterval, end: TimeInterval, weight: Double)] = []
        for segment in live.sorted(by: { $0.start < $1.start }) {
            guard let name = names[segment.speakerID] else { continue }
            let before = nameTalk[name] ?? 0
            nameTalk[name] = before + (segment.end - segment.start)
            weighted.append((name, segment.start, segment.end, before < namingSeconds ? namingWeight : 1))
        }
        let namedPeople = nameTalk.filter { $0.value >= minimumTalk }.count
        let reviewPeople = reviewTalk.filter { $0.value >= minimumTalk }.count
        guard reviewPeople >= namedPeople else { return nil }

        var score: [String: [String: Double]] = [:]   // review voice -> name -> weighted overlap
        var shared: [String: [String: Double]] = [:]  // the same, in plain seconds
        for r in review {
            for l in weighted {
                let overlap = min(r.end, l.end) - max(r.start, l.start)
                if overlap > 0 {
                    score[r.speakerID, default: [:]][l.name, default: 0] += overlap * l.weight
                    shared[r.speakerID, default: [:]][l.name, default: 0] += overlap
                }
            }
        }
        let pairs = score.flatMap { voice, byName in byName.map { (voice: voice, name: $0.key, score: $0.value) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.voice < $1.voice }
        var assigned: [String: String] = [:]
        var used = Set<String>()
        for pair in pairs where assigned[pair.voice] == nil && !used.contains(pair.name) {
            // Enough of that voice's time must really be this person.
            guard pair.score >= 3, pair.score >= 0.25 * (reviewTalk[pair.voice] ?? 0) else { continue }
            assigned[pair.voice] = pair.name
            used.insert(pair.name)
        }
        // A voice left over that's mostly one named person's time: if it sounds
        // like the voice that got their name, the recording split one person
        // in two, so it gets the name too. If it sounds different (or there's
        // no fingerprint to tell), it's someone the live check lumped in, and
        // stays "Speaker N".
        let voiceOf = Dictionary(assigned.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for (voice, byName) in shared where assigned[voice] == nil {
            guard let best = byName.max(by: { $0.value < $1.value }),
                  best.value >= 0.6 * (reviewTalk[voice] ?? 0),
                  let named = voiceOf[best.key],
                  let mine = fingerprints[voice], let theirs = fingerprints[named],
                  VoiceMatcher.distance(mine, theirs) <= samePersonDistance else { continue }
            assigned[voice] = best.key
        }
        // Everyone named on the call for long enough must still have a voice.
        guard nameTalk.filter({ $0.value >= minimumTalk }).keys.allSatisfy(used.contains) else { return nil }

        let segments = review.map { r -> VoiceSegment in
            var s = r
            s.speakerID = "review-" + r.speakerID
            return s
        }
        var newNames: [String: String] = [:]
        for (voice, name) in assigned { newNames["review-" + voice] = name }
        return (segments, newNames)
    }

    /// How each of the recording's voices sounded, in the same terms as the
    /// live check and the people Warble remembers: the live fingerprints of
    /// the stretches that fall inside that voice's turns, weighted by length.
    /// The recording separates people better than the live check, so this is
    /// a cleaner picture of each person than the live voices give, both for
    /// knowing them and for learning their voice. Voices with less than
    /// `atLeast` seconds of clear speech are left out.
    static func prints(review: [VoiceSegment], live: [VoiceSegment],
                       atLeast seconds: TimeInterval = 15) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        var totals: [String: TimeInterval] = [:]
        for l in live where !l.embedding.isEmpty && l.end - l.start >= VoiceSplitter.judgeSeconds {
            var inside: [String: TimeInterval] = [:]
            for r in review {
                let overlap = min(r.end, l.end) - max(r.start, l.start)
                if overlap > 0 { inside[r.speakerID, default: 0] += overlap }
            }
            // Only a live stretch that's almost all one of the recording's voices.
            guard let best = inside.max(by: { $0.value < $1.value }),
                  best.value >= 0.8 * (l.end - l.start) else { continue }
            let unit = VoiceSplitter.unit(l.embedding)
            var sum = sums[best.key] ?? [Float](repeating: 0, count: unit.count)
            guard sum.count == unit.count else { continue }
            for i in sum.indices { sum[i] += unit[i] * Float(best.value) }
            sums[best.key] = sum
            totals[best.key, default: 0] += best.value
        }
        return sums.filter { (totals[$0.key] ?? 0) >= seconds }.mapValues { VoiceSplitter.unit($0) }
    }
}

/// What the voice checks heard and decided on one call, saved next to the
/// call's recordings (voices.json), so a call that went wrong can be gone
/// over afterwards and the settings checked against Jonny's real calls
/// rather than test recordings. Holds voice fingerprints, like the voices
/// Warble remembers, and never leaves the Mac.
struct VoiceLog: Codable, Equatable {
    struct Stretch: Codable, Equatable {
        var voice: String
        var start: TimeInterval
        var end: TimeInterval
        var print: [Float]
        /// The voice the engine gave it. Where `voice` is neither this nor a
        /// split of it ("S3#2" of "S3"), Warble took a new engine voice to be
        /// someone heard earlier. Missing in older logs.
        var engine: String?

        init(_ segment: VoiceSegment) {
            voice = segment.speakerID
            start = segment.start
            end = segment.end
            print = segment.embedding
            engine = segment.engineID
        }
    }

    /// One thing the voice checks did during the call (checked a voice,
    /// asked about it, were told its name...), if the controller noted it.
    struct Decision: Codable, Equatable {
        /// Seconds into the call.
        var at: TimeInterval
        var voice: String
        /// What happened, e.g. "check", "ask", "named", "joined", "skipped".
        var event: String
        var name: String?
        var distance: Float?
        var confidence: NameConfidence?
    }

    var version = 2
    /// The settings the call was checked with.
    var settings: [String: Double]
    /// Every stretch of the others' speech as the live check heard it.
    var live: [Stretch]
    /// The names the live voices had when the call ended.
    var liveNames: [String: String]
    /// The voices found by going over the recording afterwards, if that worked.
    var review: [Stretch]?
    /// The names the saved transcript uses.
    var names: [String: String]
    /// The label of each whole-call recording learned after the call, by
    /// voice, so a name given by mistake can be fully undone afterwards
    /// (`VoiceprintStore.unlearn`). Nil in logs from before build 43.
    var learned: [String: UUID]?
    /// What the voice checks did during the call, oldest first, if noted.
    var decisions: [Decision]?

    init(live: [VoiceSegment], liveNames: [String: String], review: [VoiceSegment]?, names: [String: String],
         settings: [String: Double], learned: [String: UUID]? = nil, decisions: [Decision]? = nil) {
        self.live = live.map(Stretch.init)
        self.liveNames = liveNames
        self.review = review?.map(Stretch.init)
        self.names = names
        self.settings = settings
        self.learned = learned
        self.decisions = decisions
    }

    /// The settings in force now.
    static var currentSettings: [String: Double] {
        [
            "chunkSeconds": LiveChunks.seconds,
            "newVoiceDistance": Double(SpeakerIdentifier.newVoiceDistance),
            "refineDistance": Double(SpeakerIdentifier.refineDistance),
            "maxDistance": Double(VoiceMatcher.maxDistance),
            "margin": Double(VoiceMatcher.margin),
            "learnDistance": Double(VoiceMatcher.learnDistance),
            "sameCallDistance": Double(VoiceMatcher.sameCallDistance),
            "sameCallMargin": Double(VoiceMatcher.sameCallMargin),
            "afterCallDistance": Double(VoiceMatcher.afterCallDistance),
            "tentativeDistance": Double(VoiceMatcher.tentativeDistance),
            "tentativeMargin": Double(VoiceMatcher.tentativeMargin),
            "candidateDistance": Double(VoiceMatcher.candidateDistance),
            "waitBeforeAskingAtMost": VoiceMatcher.waitBeforeAskingAtMost,
            "splitterSameDistance": Double(VoiceSplitter.sameDistance),
            "sameAsEarlierDistance": Double(VoiceSplitter.sameAsEarlierDistance),
            "sameAsEarlierMargin": Double(VoiceSplitter.sameAsEarlierMargin),
        ]
    }

    /// Saves the log in `folder` as voices.json, off the main thread.
    func save(in folder: URL) {
        let log = self
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(log) else { return }
            try? data.write(to: folder.appendingPathComponent("voices.json"), options: .atomic)
        }
    }
}
