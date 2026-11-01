import AVFoundation
import FluidAudio
import Foundation

/// Live dictation with NVIDIA Parakeet. Parakeet works on whole stretches of
/// audio rather than word by word, but it is fast enough to re-read the phrase
/// you're saying twice a second. That gives the same live typing as Apple's
/// engine: in-progress words while you talk, then the finished phrase (with
/// Word List terms corrected) when you pause.
@MainActor
final class ParakeetDictationEngine: DictationSpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinalSegment: ((String) -> Void)?
    var onVolatileSegment: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onPreparing: ((String) -> Void)?

    /// How long a pause ends a phrase.
    private let phrasePause: TimeInterval = 0.8
    /// Phrases are finished at this length even without a pause.
    private let maxPhrase: TimeInterval = 20
    private let refreshInterval: Duration = .milliseconds(500)

    private let audioEngine = AVAudioEngine()
    private let audio = PhraseAudio(sampleRate: Double(ParakeetService.sampleRate))
    private var loopTask: Task<Void, Never>?
    private var finalText = ""
    private var hints: [String] = []
    private var lastDecodedVersion = -1
    private(set) var isRunning = false

    func start(hints: [String]) async throws {
        guard !isRunning else { return }
        finalText = ""
        lastDecodedVersion = -1
        self.hints = hints
        audio.reset()

        if !(await ParakeetService.shared.isReady) {
            onPreparing?("Loading the Parakeet speech model (the first time downloads about 600 MB)…")
        }
        try await ParakeetService.shared.prepare()

        try startMicrophone()
        isRunning = true
        let interval = refreshInterval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.isRunning, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stop() async -> String {
        guard isRunning else { return finalText }
        isRunning = false
        stopMicrophone()
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        let rest = audio.snapshot()
        if rest.hasSpeech {
            audio.consume(rest.samples.count)
            await finishPhrase(rest.samples)
        }
        onLevel?(0)
        return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        guard isRunning else { return }
        isRunning = false
        stopMicrophone()
        loopTask?.cancel()
        loopTask = nil
        audio.reset()
    }

    // MARK: - Decoding

    private func refresh() async {
        let snapshot = audio.snapshot()
        guard snapshot.hasSpeech else { return }
        if snapshot.trailingSilence >= phrasePause || snapshot.duration >= maxPhrase {
            audio.consume(snapshot.samples.count)
            await finishPhrase(snapshot.samples)
        } else if snapshot.version != lastDecodedVersion {
            lastDecodedVersion = snapshot.version
            guard let result = try? await ParakeetService.shared.transcribe(snapshot.samples),
                  isRunning else { return }
            let words = Self.tidy(result.text)
            onVolatileSegment?(words)
            onPartial?(Self.join(finalText, words))
        }
    }

    private func finishPhrase(_ samples: [Float]) async {
        guard let result = try? await ParakeetService.shared.transcribe(samples) else { return }
        let boosted = await ParakeetService.shared.boost(
            text: result.text, timings: result.tokenTimings ?? [],
            audio: ParakeetService.padded(samples), terms: hints)
        let phrase = Self.tidy(boosted)
        if !phrase.isEmpty {
            finalText = Self.join(finalText, phrase)
            onFinalSegment?(phrase)
        }
        onPartial?(finalText)
    }

    nonisolated static func tidy(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    nonisolated private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    // MARK: - Microphone

    private func startMicrophone() throws {
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(ParakeetService.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw SpeechEngineError.microphoneUnavailable
        }
        let levelHandler: @Sendable (Double) -> Void = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat,
                         block: Self.makeTap(converter: converter, target: target,
                                             audio: audio, level: levelHandler))
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopMicrophone() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    nonisolated private static func makeTap(
        converter: AVAudioConverter,
        target: AVAudioFormat,
        audio: PhraseAudio,
        level: @escaping @Sendable (Double) -> Void
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, output.frameLength > 0, let data = output.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
            let rms = audio.append(samples)
            level(Double(rms))
        }
    }
}

/// The audio of the phrase being spoken, filled from the audio thread.
/// Keeps track of where speech was last heard so pauses can end phrases.
final class PhraseAudio: @unchecked Sendable {
    struct Snapshot {
        var samples: [Float]
        var hasSpeech: Bool
        var trailingSilence: TimeInterval
        var duration: TimeInterval
        var version: Int
    }

    private let sampleRate: Double
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastSpeechEnd = 0
    private var hasSpeech = false
    private var version = 0
    private var noiseFloor: Float = 0.005

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func reset() {
        lock.lock()
        samples = []
        lastSpeechEnd = 0
        hasSpeech = false
        version = 0
        lock.unlock()
    }

    /// Adds audio and returns its loudness.
    @discardableResult
    func append(_ chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(chunk.count)).squareRoot()

        lock.lock()
        defer { lock.unlock() }
        // Track background noise slowly so a noisy room doesn't count as talking.
        if rms < noiseFloor * 2 { noiseFloor = noiseFloor * 0.95 + rms * 0.05 }
        let isSpeech = rms > max(0.01, noiseFloor * 3)
        samples.append(contentsOf: chunk)
        if isSpeech {
            hasSpeech = true
            lastSpeechEnd = samples.count
        } else if !hasSpeech {
            // Before anyone speaks, keep only a short lead-in.
            let keep = Int(sampleRate * 0.4)
            if samples.count > keep * 3 { samples.removeFirst(samples.count - keep) }
        }
        version += 1
        return rms
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(samples: samples, hasSpeech: hasSpeech,
                        trailingSilence: Double(samples.count - lastSpeechEnd) / sampleRate,
                        duration: Double(samples.count) / sampleRate,
                        version: version)
    }

    /// Removes audio that has been turned into a finished phrase.
    func consume(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = min(count, samples.count)
        samples.removeFirst(n)
        lastSpeechEnd = max(0, lastSpeechEnd - n)
        hasSpeech = lastSpeechEnd > 0
        version += 1
    }
}
