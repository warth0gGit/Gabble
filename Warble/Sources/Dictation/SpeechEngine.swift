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
    /// Called with each finished phrase as soon as the engine is sure of it.
    var onFinalSegment: ((String) -> Void)?
    /// Called with the in-progress words of the phrase being spoken right now.
    var onVolatileSegment: ((String) -> Void)?
    /// Called with microphone loudness from 0 to 1.
    var onLevel: ((Double) -> Void)?
    /// Called while the speech model downloads for the first time.
    var onPreparing: ((String) -> Void)?

    private let microphone = MicrophoneCapture()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""
    /// Counts dictations, so results arriving late from an earlier one (after a
    /// reset) can't leak into the next.
    private var run = 0

    private(set) var isRunning = false

    func start(hints: [String]) async throws {
        guard !isRunning else { return }
        run += 1
        let mine = run
        finalText = ""
        volatileText = ""

        // Start the microphone first and keep what it hears, so words spoken
        // while Apple's speech model gets ready aren't lost.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let preRoll = PreRoll()
        let levelHandler: @Sendable (Double) -> Void = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        do {
            try await microphone.start(deviceUID: MicrophoneChoice.saved()) { buffer in
                levelHandler(AudioReformatter.rms(of: buffer))
                preRoll.receive(buffer)
            }
        } catch {
            continuation.finish()
            throw error
        }
        inputContinuation = continuation

        do {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: SpeechAccent.saved().locale) else {
                throw SpeechEngineError.languageNotSupported
            }

            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
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
            self.analyzer = analyzer

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        guard let self, self.run == mine else { return }
                        if result.isFinal {
                            self.finalText = Self.join(self.finalText, text)
                            self.volatileText = ""
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { self.onFinalSegment?(trimmed) }
                        } else {
                            self.volatileText = text
                            self.onVolatileSegment?(text)
                        }
                        self.onPartial?(Self.join(self.finalText, self.volatileText))
                    }
                } catch {
                    // The stream ends with an error if the analyzer is cancelled; nothing to do.
                }
            }

            // Hand over what was heard so far, then stream live.
            preRoll.attach(AudioReformatter(target: analyzerFormat)) { output in
                continuation.yield(AnalyzerInput(buffer: output))
            }
            try await analyzer.start(inputSequence: stream)
        } catch {
            // Don't leave a half-started analyzer or microphone running.
            microphone.stop()
            continuation.finish()
            inputContinuation = nil
            await analyzer?.cancelAndFinishNow()
            resultsTask?.cancel()
            resultsTask = nil
            analyzer = nil
            throw error
        }
        isRunning = true
    }

    /// Stops listening and returns everything that was heard.
    func stop() async -> String {
        guard isRunning else { return finalText }
        isRunning = false
        microphone.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        // Finishing normally takes a fraction of a second. If the speech model
        // stalls, give up after a few seconds and keep what was heard so far,
        // rather than leaving dictation stuck.
        let running = self.analyzer
        let results = resultsTask
        let finished = await withDeadline(seconds: 4) {
            try? await running?.finalizeAndFinishThroughEndOfInput()
            await results?.value
            return true
        }
        if finished == nil {
            await running?.cancelAndFinishNow()
            results?.cancel()
        }
        resultsTask = nil
        analyzer = nil
        let text = Self.join(finalText, volatileText)
        onLevel?(0)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        guard isRunning else { return }
        isRunning = false
        microphone.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
    }

    nonisolated private static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespaces)
        let right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}

/// What dictation needs from a speech engine. Apple's (`SpeechEngine`) and
/// Parakeet (`ParakeetDictationEngine`) both provide it, so Settings can switch.
@MainActor
protocol DictationSpeechEngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinalSegment: ((String) -> Void)? { get set }
    var onVolatileSegment: ((String) -> Void)? { get set }
    var onLevel: ((Double) -> Void)? { get set }
    var onPreparing: ((String) -> Void)? { get set }
    func start(hints: [String]) async throws
    func stop() async -> String
    func cancel() async
}

extension SpeechEngine: DictationSpeechEngine {}

/// Holds the microphone's first buffers until the speech model is ready, then
/// passes them on in order, followed by live audio. Thread-safe: buffers arrive
/// on an audio thread. Keeps at most about 30 seconds.
final class PreRoll: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var reformatter: AudioReformatter?
    private var send: ((AVAudioPCMBuffer) -> Void)?

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let reformatter, let send {
            if let output = reformatter.convert(buffer) { send(output) }
            return
        }
        // The audio engine may reuse its buffer, so keep a copy.
        guard let copy = Self.copy(buffer) else { return }
        pending.append(copy)
        pendingFrames += AVAudioFramePosition(copy.frameLength)
        let limit = AVAudioFramePosition(copy.format.sampleRate * 30)
        while pendingFrames > limit, !pending.isEmpty {
            pendingFrames -= AVAudioFramePosition(pending.removeFirst().frameLength)
        }
    }

    func attach(_ reformatter: AudioReformatter, send: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        for buffer in pending {
            if let output = reformatter.convert(buffer) { send(output) }
        }
        pending.removeAll()
        pendingFrames = 0
        self.reformatter = reformatter
        self.send = send
    }

    var bufferedFrames: AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }
        return pendingFrames
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
