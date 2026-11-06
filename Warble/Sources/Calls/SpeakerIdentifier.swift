import AVFoundation
import FluidAudio
import Foundation

/// A stretch of call audio and who was speaking, from the voice model.
struct VoiceSegment: Equatable {
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
    /// The voice engine's fingerprint of this stretch, if it gave one.
    var embedding: [Float] = []
}

/// A person Warble knows by voice.
struct Voiceprint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Their voice on average (kept in step with `samples`).
    var embedding: [Float]
    var updated: Date = Date()
    /// How they sounded on each of their recent calls. Teams and Zoom audio
    /// varies from call to call, so one recording of someone isn't enough to
    /// know them again; several are. Nil for voices saved before build 40.
    var samples: [[Float]]? = nil
    /// A label for each of `samples`, in the same order, so one recording can
    /// be taken back out again (when you undo a name). Nil for voices saved
    /// before build 43; labels are made up for those when first needed.
    var sampleIDs: [UUID]? = nil

    /// Every recording of them Warble keeps.
    var prints: [[Float]] {
        let kept = (samples ?? []).filter { !$0.isEmpty }
        return kept.isEmpty ? [embedding] : kept
    }

    /// The most recordings of one person kept; the oldest goes first.
    static let maxSamples = 8

    /// Adds how they sounded on another call. Returns the new recording's
    /// label (to undo it with `unlearn`), or nil if it couldn't be added.
    @discardableResult
    mutating func learn(_ print: [Float]) -> UUID? {
        guard !print.isEmpty, embedding.isEmpty || print.count == embedding.count else { return nil }
        var kept = embedding.isEmpty ? [] : labelled()
        let label = UUID()
        kept.append((label, print))
        if kept.count > Self.maxSamples { kept.removeFirst(kept.count - Self.maxSamples) }
        set(kept)
        return label
    }

    /// Takes one recording back out. False if they don't have it, or it's the
    /// only one left (then forget the whole voice instead).
    @discardableResult
    mutating func unlearn(_ label: UUID) -> Bool {
        var kept = labelled()
        guard kept.count > 1, let index = kept.firstIndex(where: { $0.id == label }) else { return false }
        kept.remove(at: index)
        set(kept)
        return true
    }

    /// Whether one of their recordings has this label.
    func has(_ label: UUID) -> Bool {
        sampleIDs?.contains(label) ?? false
    }

    /// Takes in every recording of someone else (the same person under
    /// another name), keeping the newest if there are too many.
    mutating func absorb(_ other: Voiceprint) {
        guard other.embedding.count == embedding.count || embedding.isEmpty else { return }
        var kept = labelled() + other.labelled()
        if kept.count > Self.maxSamples { kept.removeFirst(kept.count - Self.maxSamples) }
        set(kept)
    }

    /// The recordings with their labels; old voices get labels made up here.
    func labelled() -> [(id: UUID, print: [Float])] {
        let all = prints
        let ids = sampleIDs ?? []
        return all.enumerated().map { index, print in (index < ids.count ? ids[index] : UUID(), print) }
    }

    private mutating func set(_ kept: [(id: UUID, print: [Float])]) {
        samples = kept.map(\.print)
        sampleIDs = kept.map(\.id)
        embedding = Self.average(kept.map(\.print))
        updated = Date()
    }

    static func average(_ prints: [[Float]]) -> [Float] {
        guard let size = prints.first?.count, size > 0 else { return [] }
        var sum = [Float](repeating: 0, count: size)
        for print in prints where print.count == size {
            let unit = VoiceSplitter.unit(print)
            for i in sum.indices { sum[i] += unit[i] }
        }
        return VoiceSplitter.unit(sum)
    }
}

/// Saves the voices Warble has learned, so people are recognised on future calls.
@MainActor
final class VoiceprintStore: ObservableObject {
    @Published private(set) var voices: [Voiceprint] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = support.appendingPathComponent("Warble", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("voiceprints.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([Voiceprint].self, from: data) {
            voices = decoded
        }
    }

    /// Remembers how someone you named sounds. Returns a label for this
    /// recording, so the naming can be undone with `unlearn`.
    @discardableResult
    func remember(name: String, embedding: [Float]) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !embedding.isEmpty else { return nil }
        let label: UUID?
        if let index = position(of: trimmed) {
            // Added to what Warble already knows of them, not in place of it.
            label = voices[index].learn(embedding)
        } else {
            let id = UUID()
            voices.append(Voiceprint(name: trimmed, embedding: embedding, samples: [embedding], sampleIDs: [id]))
            label = id
        }
        save()
        return label
    }

    /// Someone you named, or Warble clearly recognised, as they sounded on a
    /// whole call. Skipped unless it clearly sounds like them and not like
    /// anyone else on file (`VoiceMatcher.shouldLearn`), so one mix-up can't
    /// spoil their voice, or someone else's. Returns the recording's label,
    /// to undo it with `unlearn`.
    /// - Parameter confidence: how the name was given on the call. Pass
    ///   `.confirmed` only when you named them; a tentative name is never learned.
    @discardableResult
    func reinforce(name: String, embedding: [Float], confidence: NameConfidence = .recognised) -> UUID? {
        guard !embedding.isEmpty,
              let index = position(of: name),
              VoiceMatcher.shouldLearn(embedding, as: name, known: voices, confidence: confidence) else { return nil }
        let label = voices[index].learn(embedding)
        save()
        return label
    }

    /// Undoes `remember` or `reinforce`: that recording is taken back out, so
    /// a name given by mistake doesn't teach Warble the wrong voice. If it was
    /// all Warble knew of that person, the person is forgotten.
    func unlearn(_ label: UUID) {
        guard let index = voices.firstIndex(where: { $0.has(label) }) else { return }
        if !voices[index].unlearn(label) {
            voices.remove(at: index)
        }
        save()
    }

    /// Gives someone a new name. If someone already has that name, they're
    /// the same person and the two are joined.
    func rename(from old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = position(of: old) else { return }
        if let other = position(of: trimmed), other != index {
            return merge(old, into: trimmed)
        }
        voices[index].name = trimmed
        save()
    }

    /// Two names on file are the same person: `source`'s recordings join `target`'s.
    func merge(_ source: String, into target: String) {
        guard let from = position(of: source), let to = position(of: target), from != to else { return }
        voices[to].absorb(voices[from])
        voices.remove(at: from)
        save()
    }

    func forget(_ voice: Voiceprint) {
        voices.removeAll { $0.id == voice.id }
        save()
    }

    private func position(of name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return voices.firstIndex { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(voices) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Decides whether a voice heard on a call is someone Warble already knows.
/// Strict on purpose: a wrong name is worse than asking "Who's this?".
/// Pure, unit tested.
enum VoiceMatcher {
    /// The furthest (cosine distance) a voice can be from a remembered one to match.
    static let maxDistance: Float = 0.45
    /// …and it must be at least this much closer to them than to anyone else on file.
    static let margin: Float = 0.1

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 2 }
        return 1 - dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// A whole-call recording of someone you named only joins what's on file
    /// for them if it's at least this close (so a mix-up doesn't spoil their voice).
    static let learnDistance: Float = 0.5

    /// Whether a whole-call recording should be learned as `name`. It must be
    /// nearer them than anyone else on file by the usual margin (otherwise,
    /// say, AJ lumped into Matt's voice would teach Warble that Matt sounds
    /// like AJ, and next time neither would be recognised). Names you gave
    /// may be up to `learnDistance` away; names Warble gave itself must pass
    /// the strict test (`maxDistance`), so it can't slowly teach itself a
    /// wrong voice. Tentative names are never learned.
    static func shouldLearn(_ embedding: [Float], as name: String, known: [Voiceprint],
                            confidence: NameConfidence) -> Bool {
        let limit: Float
        switch confidence {
        case .confirmed: limit = learnDistance
        case .recognised: limit = maxDistance
        case .tentative: return false
        }
        guard let nearest = match(embedding, known: known, within: limit) else { return false }
        return nearest.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// How far a voice is from a remembered person: from their average over
    /// all the calls Warble has heard them on. Measured on the same people
    /// on calls months apart: going by whichever single recording was
    /// nearest let about four times as many strangers come within
    /// `maxDistance` of someone with several recordings (1.1% against 0.24%
    /// per person on file), while the real person was barely any nearer
    /// (furthest 0.37 either way). So the average decides.
    static func distance(_ embedding: [Float], to person: Voiceprint) -> Float {
        distance(embedding, person.embedding)
    }

    /// The name of the remembered person this voice clearly is, or nil.
    static func match(_ embedding: [Float], known: [Voiceprint], within limit: Float = maxDistance) -> String? {
        let ranked = known.map { (name: $0.name, distance: distance(embedding, to: $0)) }
            .sorted { $0.distance < $1.distance }
        guard let best = ranked.first, best.distance <= limit else { return nil }
        if let second = ranked.dropFirst().first(where: { $0.name.caseInsensitiveCompare(best.name) != .orderedSame }),
           second.distance - best.distance < margin {
            return nil
        }
        return best.name
    }

    /// How far a voice can drift from someone already named on this call and
    /// still be them. The voice engine has already judged this voice to be
    /// new (further than newVoiceDistance from everyone), so only a clearly
    /// closer match overrules it; a looser value folded a fifth person on a
    /// big call into one of the first four. Measured: at 0.45 about one
    /// rejoin in seven was the wrong person; at 0.4 one in thirteen.
    static let sameCallDistance: Float = 0.4
    /// Naming someone from an earlier call only after this call has ended,
    /// when you never saw them on the card, needs a very close match.
    static let afterCallDistance: Float = 0.3
    /// The nearest person on the call must beat the next nearest by this much.
    static let sameCallMargin: Float = 0.1

    /// Mid-call, the voice engine sometimes starts a new voice for someone
    /// already on the call. Prefer the people on this call, and only name
    /// someone who isn't on it when they're a much closer match.
    /// - Parameters:
    ///   - embedding: the voice's first few seconds (compared with the
    ///     people on this call, who are fingerprinted the same way).
    ///   - heard: everything the voice has said so far, if Warble has more
    ///     than the first few seconds. Used for the people from earlier
    ///     calls: more speech tells them apart much better (see docs).
    static func matchInCall(_ embedding: [Float], onCall: [Voiceprint], saved: [Voiceprint],
                            heard: [Float]? = nil) -> String? {
        let whole = heard ?? embedding
        let present = Set(onCall.map { $0.name.lowercased() })
        let others = saved.filter { !present.contains($0.name.lowercased()) }
        let rankedOnCall = onCall.map { (name: $0.name, distance: distance(embedding, to: $0)) }
            .sorted { $0.distance < $1.distance }
        let nearestOnCall = rankedOnCall.first
        let runnerUp = rankedOnCall.dropFirst()
            .first { $0.name.caseInsensitiveCompare(nearestOnCall?.name ?? "") != .orderedSame }
        let clearWinner = runnerUp.map { $0.distance - (nearestOnCall?.distance ?? 0) >= sameCallMargin } ?? true
        // Compared like with like: the people on this call were fingerprinted
        // from their first few seconds, so the people on file are measured
        // from this voice's first few seconds too (a print of more speech
        // sits nearer everyone, which would unfairly favour them).
        let nearestOther = others.map { distance(embedding, to: $0) }.min() ?? 2
        if let nearestOnCall, nearestOnCall.distance <= sameCallDistance, clearWinner,
           !(nearestOther <= maxDistance && nearestOther + 0.15 < nearestOnCall.distance) {
            return nearestOnCall.name
        }
        return match(whole, known: saved)
    }

    // MARK: - Suggestions and how sure Warble is

    /// Someone further than `maxDistance` but within this is shown with a
    /// question mark ("Matt?") rather than named outright or asked about cold.
    /// Measured on calls months apart with 25 people on file: at 0.5 (and a
    /// 0.1 lead) about 1 newcomer in 20-40 is shown as someone they aren't,
    /// and a known person heard over a poorer line is shown as "Name?" about
    /// one time in five instead of being asked about. At 0.55 with a 0.05
    /// lead it caught a few more, but showed 1 newcomer in 7 as someone else.
    static let tentativeDistance: Float = 0.5
    /// …and must still be this much nearer than the next person.
    static let tentativeMargin: Float = 0.1
    /// The furthest a person on file can be and still be offered as a one-tap
    /// suggestion on "Who's this?". Beyond this a voice is nearly always
    /// someone else (see docs), so offering them would only mislead.
    static let candidateDistance: Float = 0.65

    /// The people on file this voice sounds most like, nearest first, for
    /// one-tap suggestions on "Who's this?". Only people within
    /// `candidateDistance`; each name once.
    static func candidates(_ embedding: [Float], known: [Voiceprint], limit: Int = 3) -> [(name: String, distance: Float)] {
        var seen = Set<String>()
        return ranked(embedding, known)
            .filter { $0.distance <= candidateDistance && seen.insert($0.name.lowercased()).inserted }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// Who this voice is, and how sure Warble is: `.recognised` when it
    /// passes the strict test (`match`), `.tentative` when it's clearly nearer
    /// one person than the next but not close enough to be sure, nil when it
    /// could be anyone. A tentative guess needs someone to be nearer than: with
    /// only one person to compare against, "nearer them than anyone else"
    /// means nothing, so an unsure voice is asked about instead.
    static func guess(_ embedding: [Float], known: [Voiceprint]) -> VoiceGuess? {
        let ranked = ranked(embedding, known)
        guard let best = ranked.first else { return nil }
        let runnerUp = ranked.dropFirst().first { $0.name.caseInsensitiveCompare(best.name) != .orderedSame }
        let lead = (runnerUp?.distance ?? 2) - best.distance
        if best.distance <= maxDistance, lead >= margin {
            return VoiceGuess(name: best.name, distance: best.distance, confidence: .recognised)
        }
        if let runnerUp, best.distance <= tentativeDistance, runnerUp.distance - best.distance >= tentativeMargin {
            return VoiceGuess(name: best.name, distance: best.distance, confidence: .tentative)
        }
        return nil
    }

    /// As `matchInCall`, with how sure Warble is: `.recognised` for what
    /// `matchInCall` names, `.tentative` for someone on file (not already on
    /// this call) whom `guess` is unsure of, otherwise nil (ask).
    static func guessInCall(_ embedding: [Float], onCall: [Voiceprint], saved: [Voiceprint],
                            heard: [Float]? = nil) -> VoiceGuess? {
        let whole = heard ?? embedding
        if let name = matchInCall(embedding, onCall: onCall, saved: saved, heard: heard) {
            let distance = min(ranked(embedding, onCall).first { $0.name == name }?.distance ?? 2,
                               ranked(whole, saved).first { $0.name == name }?.distance ?? 2)
            return VoiceGuess(name: name, distance: distance, confidence: .recognised)
        }
        // Not sure enough to name them: at most a tentative guess at someone
        // on file who isn't already on this call. Never a guess at someone on
        // the call: measured, a new voice 0.4-0.5 from someone already named
        // on the call was them only 0-7% of the time (the voice engine had
        // already judged it a different person), so "Jordan?" would nearly
        // always be wrong.
        let present = Set(onCall.map { $0.name.lowercased() })
        guard var guess = guess(whole, known: saved), !present.contains(guess.name.lowercased()) else { return nil }
        guess.confidence = .tentative
        return guess
    }

    /// The most talk to wait for before asking about a voice that sounds a
    /// bit like someone (see `shouldWaitBeforeAsking`).
    static let waitBeforeAskingAtMost: TimeInterval = 20

    /// Whether to hold off "Who's this?" for a voice that couldn't be named
    /// yet, because its next check may well name it. True only when it sounds
    /// a bit like someone on file or on this call (`candidates` isn't empty)
    /// and its next check (the first of `rechecks` after `lastChecked`) is due
    /// by `atMost` seconds of talk; otherwise ask now. A voice that sounds
    /// like nobody is asked about straight away, as before. Pure, unit tested.
    /// - Parameters:
    ///   - candidates: `candidates(...)` for this voice, from everything it has said so far.
    ///   - talk: seconds this voice has talked so far.
    ///   - lastChecked: its talk total when it was last checked (nil: never).
    ///   - rechecks: the talk totals at which a voice is checked again (the controller's `recheckAfter`).
    static func shouldWaitBeforeAsking(candidates: [(name: String, distance: Float)], talk: TimeInterval,
                                       lastChecked: TimeInterval?, rechecks: [TimeInterval],
                                       atMost limit: TimeInterval = waitBeforeAskingAtMost) -> Bool {
        guard !candidates.isEmpty, talk < limit else { return false }
        let last = lastChecked ?? 0
        guard let next = rechecks.filter({ $0 > last }).min() else { return false }
        return next <= limit
    }

    /// Everyone on file, nearest first.
    private static func ranked(_ embedding: [Float], _ known: [Voiceprint]) -> [(name: String, distance: Float)] {
        known.map { (name: $0.name, distance: distance(embedding, to: $0)) }.sorted { $0.distance < $1.distance }
    }
}

/// How sure Warble is of the name it shows for a voice on a call.
enum NameConfidence: String, Codable, Equatable {
    /// You named them (or joined the voice to someone) on this call.
    case confirmed
    /// Warble recognised them clearly, from an earlier call or from earlier in this one.
    case recognised
    /// Sounds like them, but Warble isn't sure: shown as "Matt?".
    case tentative
}

/// Warble's best guess at who a voice is.
struct VoiceGuess: Equatable {
    var name: String
    /// How far the voice is from them (cosine distance; smaller is closer).
    var distance: Float
    var confidence: NameConfidence
}

/// Matches transcript phrases to voices. Pure, unit tested.
enum SpeakerAssigner {
    /// The voice that overlaps a phrase the most, or nil if none does.
    static func speaker(for range: ClosedRange<TimeInterval>, in segments: [VoiceSegment]) -> String? {
        var best: (id: String, overlap: TimeInterval)?
        for segment in segments {
            let overlap = min(range.upperBound, segment.end) - max(range.lowerBound, segment.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (segment.speakerID, overlap)
            }
        }
        if let best { return best.id }
        // No overlap: use the nearest voice within two seconds.
        let nearest = segments.min { distance($0, range) < distance($1, range) }
        if let nearest, distance(nearest, range) < 2 { return nearest.speakerID }
        return nil
    }

    private static func distance(_ s: VoiceSegment, _ r: ClosedRange<TimeInterval>) -> TimeInterval {
        if s.end < r.lowerBound { return r.lowerBound - s.end }
        if s.start > r.upperBound { return s.start - r.upperBound }
        return 0
    }

    /// Total speaking time per voice.
    static func talkTime(_ segments: [VoiceSegment]) -> [String: TimeInterval] {
        segments.reduce(into: [:]) { totals, s in totals[s.speakerID, default: 0] += s.end - s.start }
    }
}

/// How much waiting audio goes to the voice engine at a time. Pure, unit tested.
enum LiveChunks {
    /// Seconds of audio the engine looks at in one go (see `SpeakerIdentifier`).
    static let seconds: Double = 10

    /// How many of `pending` samples to send now: during the call only whole
    /// chunks of `chunk` samples, at the end of the call everything.
    static func samplesToSend(pending: Int, chunk: Int, wholeChunksOnly: Bool) -> Int {
        guard pending > 0, chunk > 0 else { return 0 }
        return wholeChunksOnly ? pending / chunk * chunk : pending
    }
}

/// Works out who is speaking in the other side of a call using FluidAudio's
/// on-device speaker models (pyannote segmentation + WeSpeaker voice embeddings).
/// Audio is processed in chunks while the call goes on, so new voices are
/// spotted during the call. Known voices come back with their names as IDs.
final class SpeakerIdentifier: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// How much call audio the voice engine looks at in one go. Its models
    /// always take ten seconds (a shorter chunk is padded with silence), and
    /// measured on real calls ten seconds of audio beat six: fewer people
    /// asked about twice (0.8 vs 1.7 a call), fewer known people asked about
    /// at all, a third less speech left unnamed, and the slowest names came
    /// in about twice as fast, for about two seconds' more delay on average
    /// before a stretch of speech gets its name.
    private let chunkSeconds: Double = LiveChunks.seconds
    /// Audio kept while the models download, at most ten minutes.
    private let maxPendingSeconds: Double = 600

    /// Called on the main actor with new voice segments, timed from `origin`.
    var onSegments: (@MainActor ([VoiceSegment]) -> Void)?

    private let origin: Date
    private let queue = DispatchQueue(label: "warble.speaker-id")
    private let lock = NSLock()
    private var diarizer: DiarizerManager?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!
    private var pending: [Float] = []
    private var processedSamples = 0
    private var audioStartOffset: TimeInterval?
    private var failed = false

    /// - Parameter origin: the moment transcript times are measured from.
    init(origin: Date) {
        self.origin = origin
    }

    /// How different (cosine distance) a voice must be from everyone heard so
    /// far on this call to count as a new person. FluidAudio's own default
    /// (0.84) is so loose that colleagues on a Teams call merged into one, and
    /// at 0.6 a man talking for minutes was taken for a woman already named
    /// (and her fingerprint drifted to his voice). Splitting one person into
    /// two is fixable (matchInCall rejoins them, or you rename); a merge isn't.
    /// Measured on real conference calls squeezed through a phone-quality
    /// codec (docs: speaker-id technical findings): 0.45 put the least speech
    /// under a wrong name end to end; 0.5 merged more people, 0.4 split
    /// people so often that rejoining them went wrong more.
    static let newVoiceDistance: Float = 0.45
    /// A voice's fingerprint is only refined with audio this close to it.
    static let refineDistance: Float = 0.3

    /// Downloads the voice models the first time (about 30 MB), then loads them.
    /// People you've named before are not loaded in here: Warble matches them
    /// itself with a stricter test (VoiceMatcher), because a remembered voice
    /// inside the voice engine soaked up every similar voice on the call.
    func prepare() async throws {
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let diarizer = DiarizerManager()
            diarizer.initialize(models: models)
            diarizer.speakerManager.speakerThreshold = Self.newVoiceDistance
            diarizer.speakerManager.embeddingThreshold = Self.refineDistance
            lock.lock()
            self.diarizer = diarizer
            if Double(pending.count) >= chunkSeconds * Self.sampleRate { flushLocked(wholeChunksOnly: true) }
            lock.unlock()
        } catch {
            lock.lock()
            failed = true
            pending = []
            lock.unlock()
            throw error
        }
    }

    /// Feeds call audio in any format, from any thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, buffer.frameLength > 0 else { return }
        if audioStartOffset == nil { audioStartOffset = max(0, Date().timeIntervalSince(origin)) }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        if diarizer == nil, Double(pending.count) > maxPendingSeconds * Self.sampleRate {
            // The models still aren't ready; give up rather than use lots of memory.
            failed = true
            pending = []
            return
        }
        if Double(pending.count) >= chunkSeconds * Self.sampleRate {
            flushLocked(wholeChunksOnly: true)
        }
    }

    /// Processes whatever audio is left and waits for it. Call when the call ends.
    func finish() async {
        lock.lock()
        flushLocked()
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// The voice fingerprint of a speaker heard in this call, to remember them.
    func embedding(for speakerID: String) async -> [Float]? {
        lock.lock()
        let diarizer = self.diarizer
        lock.unlock()
        guard let diarizer else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Float]?, Never>) in
            queue.async {
                continuation.resume(returning: diarizer.speakerManager.getSpeaker(for: speakerID)?.currentEmbedding)
            }
        }
    }

    /// Sends waiting audio to the voice engine. During the call only whole
    /// chunks go: the engine works in chunks of exactly this length, and a
    /// few samples over would be analysed on their own as a chunk of their
    /// own (twice the work, and those samples wasted). The rest waits for
    /// the next chunk; at the end of the call everything goes.
    private func flushLocked(wholeChunksOnly: Bool = false) {
        guard !pending.isEmpty, let diarizer else { return }
        let count = LiveChunks.samplesToSend(pending: pending.count, chunk: Int(chunkSeconds * Self.sampleRate),
                                             wholeChunksOnly: wholeChunksOnly)
        guard count > 0 else { return }
        let chunk = Array(pending.prefix(count))
        let offset = Double(processedSamples) / Self.sampleRate
        let base = audioStartOffset ?? 0
        processedSamples += count
        pending.removeFirst(count)
        let onSegments = self.onSegments
        queue.async {
            // Very short chunks (under a second) aren't worth analysing.
            guard Double(chunk.count) >= Self.sampleRate else { return }
            guard let result = try? diarizer.performCompleteDiarization(chunk, atTime: offset) else { return }
            let segments = result.segments.map {
                VoiceSegment(speakerID: $0.speakerId,
                             start: base + Double($0.startTimeSeconds),
                             end: base + Double($0.endTimeSeconds),
                             embedding: $0.embedding)
            }
            guard !segments.isEmpty else { return }
            Task { @MainActor in onSegments?(segments) }
        }
    }
}
