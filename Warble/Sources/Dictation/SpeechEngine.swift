import AVFoundation
import Speech

enum SpeechEngineError: LocalizedError {
    case languageNotSupported
    case noAudioFormat
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .languageNotSupported:
            return "Your Mac's language isn't supported by Apple's on-device speech engine yet."
        case .noAudioFormat:
            return "Warble couldn't set up the speech engine's audio format."
        case .microphoneUnavailable:
            return "Warble couldn't open the microphone."
        }
    }
}

/// Live on-device speech to text using Apple's SpeechAnalyzer (macOS 26).
@MainActor
final class SpeechEngine {
    /// Called with the full text heard so far (final + in-progress words).
    var onPartial: ((String) -> Void)?
    /// Called with microphone loudness from 0 to 1.
    var onLevel: ((Double) -> Void)?
    /// Called while the speech model downloads for the first time.
    var onPreparing: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""

    private(set) var isRunning = false

    func start(hints: [String]) async throws {
        guard !isRunning else { return }
        finalText = ""
        volatileText = ""

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw SpeechEngineError.languageNotSupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onPreparing?("Downloading Apple's speech model (first time only)…")
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }

        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(hints.prefix(200))
            try? await analyzer.setContext(context)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.finalText = Self.join(self.finalText, text)
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    self.onPartial?(Self.join(self.finalText, self.volatileText))
                }
            } catch {
                // The stream ends with an error if the analyzer is cancelled; nothing to do.
            }
        }

        try await analyzer.start(inputSequence: stream)
        try startMicrophone(converting: analyzerFormat, into: continuation)
        isRunning = true
    }

    /// Stops listening and returns everything that was heard.
    func stop() async -> String {
        guard isRunning else { return finalText }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        let text = Self.join(finalText, volatileText)
        onLevel?(0)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        guard isRunning else { return }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
    }

    private func startMicrophone(converting target: AVAudioFormat,
                                 into continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw SpeechEngineError.microphoneUnavailable
        }
        let levelHandler: @Sendable (Double) -> Void = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat,
                         block: Self.makeTap(converter: converter, target: target,
                                             continuation: continuation, level: levelHandler))
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Built outside the main actor because audio arrives on a background thread.
    nonisolated private static func makeTap(
        converter: AVAudioConverter,
        target: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        level: @escaping @Sendable (Double) -> Void
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            level(rms(of: buffer))

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
            if error == nil, output.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: output))
            }
        }
    }

    nonisolated private static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return Double(sqrt(sum / Float(count)))
    }

    nonisolated private static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespaces)
        let right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}
