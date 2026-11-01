import AVFoundation
import FluidAudio
import Foundation

/// A stretch of call audio and who was speaking, from the voice model.
struct VoiceSegment: Equatable {
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
}

/// A person Warble knows by voice.
struct Voiceprint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var embedding: [Float]
    var updated: Date = Date()
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
            voices[index].embedding = embedding
            voices[index].updated = Date()
        } else {
            voices.append(Voiceprint(name: trimmed, embedding: embedding))
        }
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
    private let chunkSeconds: Double = 15
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

    /// Downloads the voice models the first time (about 30 MB), then loads them.
    func prepare(known: [Voiceprint]) async throws {
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let diarizer = DiarizerManager()
            diarizer.initialize(models: models)
            if !known.isEmpty {
                diarizer.initializeKnownSpeakers(known.map {
                    Speaker(id: $0.name, name: $0.name, currentEmbedding: $0.embedding, isPermanent: true)
                })
            }
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
                             end: base + Double($0.endTimeSeconds))
            }
            guard !segments.isEmpty else { return }
            Task { @MainActor in onSegments?(segments) }
        }
    }
}
