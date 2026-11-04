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

    /// Every recording of them Warble keeps.
    var prints: [[Float]] {
        let kept = (samples ?? []).filter { !$0.isEmpty }
        return kept.isEmpty ? [embedding] : kept
    }

    /// The most recordings of one person kept; the oldest goes first.
    static let maxSamples = 8

    /// Adds how they sounded on another call.
    mutating func learn(_ print: [Float]) {
        guard !print.isEmpty, embedding.isEmpty || print.count == embedding.count else { return }
        var kept = embedding.isEmpty ? [] : prints
        kept.append(print)
        if kept.count > Self.maxSamples { kept.removeFirst(kept.count - Self.maxSamples) }
        samples = kept
        embedding = Self.average(kept)
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

    func remember(name: String, embedding: [Float]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !embedding.isEmpty else { return }
        if let index = voices.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            // Added to what Warble already knows of them, not in place of it.
            voices[index].learn(embedding)
        } else {
            voices.append(Voiceprint(name: trimmed, embedding: embedding, samples: [embedding]))
        }
        save()
    }

    /// Someone you named, or Warble clearly recognised, as they sounded on a
    /// whole call. Skipped if it doesn't sound like what's on file for them,
    /// so one mix-up can't spoil their voice.
    func reinforce(name: String, embedding: [Float]) {
        guard !embedding.isEmpty,
              let index = voices.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              VoiceMatcher.distance(embedding, to: voices[index]) <= VoiceMatcher.learnDistance else { return }
        voices[index].learn(embedding)
        save()
    }

    func forget(_ voice: Voiceprint) {
        voices.removeAll { $0.id == voice.id }
        save()
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

    /// A whole-call recording of someone only joins what's on file for them
    /// if it's at least this close (so a mix-up doesn't spoil their voice).
    static let learnDistance: Float = 0.5

    /// How far a voice is from a remembered person: the nearest of their
    /// recordings from past calls, or their average, whichever is closer.
    static func distance(_ embedding: [Float], to person: Voiceprint) -> Float {
        let each = person.prints.map { distance(embedding, $0) }.min() ?? 2
        return min(each, distance(embedding, person.embedding))
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
    /// big call into one of the first four.
    static let sameCallDistance: Float = 0.45
    /// Naming someone from an earlier call only after this call has ended,
    /// when you never saw them on the card, needs a very close match.
    static let afterCallDistance: Float = 0.3
    /// The nearest person on the call must beat the next nearest by this much.
    static let sameCallMargin: Float = 0.1

    /// Mid-call, the voice engine sometimes starts a new voice for someone
    /// already on the call. Prefer the people on this call, and only name
    /// someone who isn't on it when they're a much closer match.
    static func matchInCall(_ embedding: [Float], onCall: [Voiceprint], saved: [Voiceprint]) -> String? {
        let present = Set(onCall.map { $0.name.lowercased() })
        let others = saved.filter { !present.contains($0.name.lowercased()) }
        let rankedOnCall = onCall.map { (name: $0.name, distance: distance(embedding, to: $0)) }
            .sorted { $0.distance < $1.distance }
        let nearestOnCall = rankedOnCall.first
        let runnerUp = rankedOnCall.dropFirst()
            .first { $0.name.caseInsensitiveCompare(nearestOnCall?.name ?? "") != .orderedSame }
        let clearWinner = runnerUp.map { $0.distance - (nearestOnCall?.distance ?? 0) >= sameCallMargin } ?? true
        let nearestOther = others.map { distance(embedding, to: $0) }.min() ?? 2
        if let nearestOnCall, nearestOnCall.distance <= sameCallDistance, clearWinner,
           !(nearestOther <= maxDistance && nearestOther + 0.15 < nearestOnCall.distance) {
            return nearestOnCall.name
        }
        return match(embedding, known: saved)
    }
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

/// Works out who is speaking in the other side of a call using FluidAudio's
/// on-device speaker models (pyannote segmentation + WeSpeaker voice embeddings).
/// Audio is processed in chunks while the call goes on, so new voices are
/// spotted during the call. Known voices come back with their names as IDs.
final class SpeakerIdentifier: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Shorter chunks show who's talking sooner during the call; much shorter
    /// than this and voices are told apart less reliably.
    private let chunkSeconds: Double = 6
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
    static let newVoiceDistance: Float = 0.5
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
            if Double(pending.count) >= chunkSeconds * Self.sampleRate { flushLocked() }
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
            flushLocked()
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

    private func flushLocked() {
        guard !pending.isEmpty, let diarizer else { return }
        let chunk = pending
        let offset = Double(processedSamples) / Self.sampleRate
        let base = audioStartOffset ?? 0
        processedSamples += pending.count
        pending.removeAll(keepingCapacity: true)
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
