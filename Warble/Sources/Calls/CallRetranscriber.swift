import AVFoundation
import FluidAudio
import Foundation

/// When Parakeet is the chosen engine, re-reads each side of a call from its
/// recording once the call ends. Parakeet hears the whole recording at once,
/// which is more accurate than live transcription, and Word List terms are
/// corrected by listening for them in the audio. Each phrase keeps its exact
/// timing so voices can still be matched to names.
enum CallRetranscriber {
    struct Recording {
        var file: URL
        var speaker: String
        /// Seconds from the start of the call transcript to the start of this file.
        var startOffset: TimeInterval
    }

    /// The new transcript lines for one recording.
    static func segments(for recording: Recording, terms: [String]) async throws -> [CallTranscript.Segment] {
        guard FileManager.default.fileExists(atPath: recording.file.path) else { return [] }
        let result = try await ParakeetService.shared.transcribe(file: recording.file)
        let timings = result.tokenTimings ?? []
        let tokens = timings.map { TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime) }
        let phrases = PhraseSplitter.phrases(from: tokens)
        let reader = terms.isEmpty ? nil : try? AudioSliceReader(url: recording.file)

        var segments: [CallTranscript.Segment] = []
        for phrase in phrases {
            var text = phrase.text
            if let reader {
                // Give the vocabulary model just this phrase's audio, with timings to match.
                let from = max(0, phrase.start - 0.25)
                let audio = reader.samples(from: from, to: phrase.end + 0.25)
                let shifted = timings[phrase.tokens].map {
                    TokenTiming(token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime - from,
                                endTime: $0.endTime - from, confidence: $0.confidence)
                }
                let boosted = await ParakeetService.shared.boost(text: text, timings: shifted,
                                                                 audio: audio, terms: terms)
                text = boosted.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            }
            guard !text.isEmpty else { continue }
            let start = recording.startOffset + phrase.start
            let end = recording.startOffset + phrase.end
            segments.append(CallTranscript.Segment(offset: start, speaker: recording.speaker,
                                                   text: text, spoken: start...max(start, end)))
        }
        return segments
    }
}

/// Reads stretches of a recording as 16 kHz mono samples.
final class AudioSliceReader {
    private let file: AVAudioFile
    private let converter = AudioConverter()

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
    }

    func samples(from: TimeInterval, to: TimeInterval) -> [Float] {
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, from) * rate)
        guard start < file.length, to > from else { return [] }
        let wanted = AVAudioFramePosition((to - max(0, from)) * rate)
        let count = AVAudioFrameCount(min(wanted, file.length - start))
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        file.framePosition = start
        do {
            try file.read(into: buffer, frameCount: count)
            return try converter.resampleBuffer(buffer)
        } catch {
            return []
        }
    }
}
