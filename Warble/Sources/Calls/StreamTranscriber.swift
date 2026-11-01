import AVFoundation
import Speech

/// On-device transcription of an audio stream that is pushed in buffer by buffer
/// (used for each side of a call). Thread-safe to feed from an audio thread.
final class StreamTranscriber: @unchecked Sendable {
    /// Called on the main actor with each finished phrase.
    var onFinal: (@MainActor (String) -> Void)?
    /// Called on the main actor with the phrase currently being heard.
    var onVolatile: (@MainActor (String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    func start(hints: [String]) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: SpeechAccent.saved().locale) else {
            throw SpeechEngineError.languageNotSupported
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(hints.prefix(200))
            try? await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        lock.lock()
        self.analyzer = analyzer
        self.continuation = continuation
        self.targetFormat = format
        lock.unlock()

        let onFinal = self.onFinal
        let onVolatile = self.onVolatile
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    if result.isFinal {
                        if !text.isEmpty { await onFinal?(text) }
                        await onVolatile?("")
                    } else {
                        await onVolatile?(text)
                    }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Pushes audio in any format; it is converted to what the speech engine needs.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, let target = targetFormat, buffer.frameLength > 0 else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
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

    func stop() async {
        lock.lock()
        let continuation = self.continuation
        let analyzer = self.analyzer
        self.continuation = nil
        self.analyzer = nil
        lock.unlock()
        continuation?.finish()
        // Finishing normally takes a moment. If the speech model stalls, give up
        // after a few seconds and keep what was heard, so saving can't get stuck.
        let results = resultsTask
        let finished = await withDeadline(seconds: 8) {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await results?.value
            return true
        }
        if finished == nil {
            await analyzer?.cancelAndFinishNow()
            results?.cancel()
        }
        resultsTask = nil
    }
}
