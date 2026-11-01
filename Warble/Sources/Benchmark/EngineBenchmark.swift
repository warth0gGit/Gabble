import AVFoundation
import Foundation

/// Compares Apple's speech engine with Parakeet on the same recording of your
/// voice: you read a short passage, then both engines transcribe it and are
/// scored on accuracy (word error rate against the passage), Word List terms
/// and speed. Everything runs on this Mac.
@MainActor
final class EngineBenchmark: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case analysing(String)
        case done
        case failed(String)
    }

    struct EngineResult: Identifiable, Equatable {
        var name: String
        var transcript: String
        var score: WordErrorRate
        var missedTerms: [String]
        /// First-time setup in this session: loading the model into memory.
        var loadSeconds: Double
        /// Time to transcribe the recording once the model is loaded (best of two runs).
        var processingSeconds: Double
        var audioSeconds: Double
        var id: String { name }
        /// How many times faster than real time, e.g. 40 means a minute takes 1.5 seconds.
        var speed: Double { processingSeconds > 0 ? audioSeconds / processingSeconds : 0 }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [EngineResult] = []
    @Published private(set) var level: Double = 0
    @Published private(set) var recordedSeconds: Double = 0
    @Published private(set) var savedReport: URL?
    let passage: String
    let terms: [String]

    private let appState: AppState
    private let lexicon: LexiconStore
    private var recorder: BenchmarkRecorder?
    private var samples: [Float] = []

    init(appState: AppState, lexicon: LexiconStore) {
        self.appState = appState
        self.lexicon = lexicon
        let picked = Self.pickTerms(from: lexicon.recognitionHints)
        terms = picked
        passage = Self.passage(with: picked)
    }

    static let basePassage = """
    Morning everyone, here is a quick update before Thursday's planning session. \
    The pilot with our largest customers went well, and we closed several new deals last week. \
    I'd like Sarah to own the follow-up, so please send her the revised forecast by Friday afternoon. \
    Let's also book a short call to review the onboarding feedback and agree the next steps.
    """

    /// Up to five Word List terms to test jargon, longest-standing first.
    static func pickTerms(from hints: [String]) -> [String] {
        Array(hints.filter { $0.count >= 2 && !$0.contains(where: \.isNumber) }.prefix(5))
    }

    static func passage(with terms: [String]) -> String {
        guard !terms.isEmpty else { return basePassage }
        let list: String
        if terms.count == 1 {
            list = terms[0]
        } else {
            list = terms.dropLast().joined(separator: ", ") + " and " + terms.last!
        }
        return basePassage + " We also need to talk about \(list)."
    }

    // MARK: - Recording

    func startRecording() {
        results = []
        savedReport = nil
        samples = []
        recordedSeconds = 0
        let recorder = BenchmarkRecorder()
        recorder.onLevel = { [weak self] level, seconds in
            self?.level = level
            self?.recordedSeconds = seconds
        }
        do {
            try recorder.start()
            self.recorder = recorder
            phase = .recording
        } catch {
            phase = .failed("Warble couldn't open the microphone: \(error.localizedDescription)")
        }
    }

    func stopAndCompare() {
        guard let recorder else { return }
        samples = recorder.stop()
        self.recorder = nil
        level = 0
        guard Double(samples.count) / BenchmarkRecorder.sampleRate >= 3 else {
            phase = .failed("That recording was too short. Read the whole passage, then press Stop.")
            return
        }
        Task { await compare() }
    }

    func cancel() {
        _ = recorder?.stop()
        recorder = nil
        level = 0
        phase = .idle
    }

    // MARK: - Comparing

    private func compare() async {
        let audioSeconds = Double(samples.count) / BenchmarkRecorder.sampleRate
        let hints = lexicon.recognitionHints
        var apple: (load: Double, times: [Double], text: String)?
        var parakeet: (load: Double, times: [Double], text: String)?
        var problems: [String] = []

        // Two rounds, alternating engines, so neither benefits from going second.
        for round in 1...2 {
            phase = .analysing("Apple's engine, round \(round) of 2…")
            do {
                let run = try await Self.runApple(samples, hints: hints)
                apple = (apple?.load ?? run.load, (apple?.times ?? []) + [run.seconds], run.text)
            } catch {
                problems.append("Apple: \(error.localizedDescription)")
            }
            phase = .analysing(round == 1 && !(await ParakeetService.shared.isReady)
                ? "Parakeet, round 1 of 2 (loading the model first)…"
                : "Parakeet, round \(round) of 2…")
            do {
                let run = try await Self.runParakeet(samples, hints: hints)
                parakeet = (parakeet?.load ?? run.load, (parakeet?.times ?? []) + [run.seconds], run.text)
            } catch {
                problems.append("Parakeet: \(error.localizedDescription)")
            }
        }

        var results: [EngineResult] = []
        if let apple {
            results.append(result(name: "Apple", run: apple, audioSeconds: audioSeconds))
        }
        if let parakeet {
            results.append(result(name: "Parakeet", run: parakeet, audioSeconds: audioSeconds))
        }
        self.results = results
        if results.isEmpty {
            phase = .failed(problems.first ?? "Neither engine produced a transcript.")
            return
        }
        savedReport = saveReport(audioSeconds: audioSeconds, problems: Array(Set(problems)))
        phase = .done
    }

    private func result(name: String, run: (load: Double, times: [Double], text: String),
                        audioSeconds: Double) -> EngineResult {
        EngineResult(name: name, transcript: run.text,
                     score: WordErrorRate.compute(reference: passage, hypothesis: run.text),
                     missedTerms: WordErrorRate.missedTerms(terms, reference: passage, hypothesis: run.text),
                     loadSeconds: run.load,
                     processingSeconds: run.times.min() ?? 0,
                     audioSeconds: audioSeconds)
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Apple's SpeechAnalyzer, fed the recording as fast as it will take it.
    private static func runApple(_ samples: [Float], hints: [String]) async throws
        -> (load: Double, seconds: Double, text: String) {
        final class Collected: @unchecked Sendable { var phrases: [String] = [] }
        let collected = Collected()
        let transcriber = StreamTranscriber()
        transcriber.onFinal = { phrase in collected.phrases.append(phrase) }
        let start = now()
        try await transcriber.start(hints: hints)
        let loaded = now()
        for buffer in BenchmarkRecorder.buffers(from: samples) {
            transcriber.feed(buffer)
        }
        await transcriber.stop()
        let finished = now()
        // Let the last main-actor callbacks land.
        await Task.yield()
        return (loaded - start, finished - loaded, collected.phrases.joined(separator: " "))
    }

    /// Parakeet on the Neural Engine, with Word List boosting as used in dictation.
    private static func runParakeet(_ samples: [Float], hints: [String]) async throws
        -> (load: Double, seconds: Double, text: String) {
        let start = now()
        try await ParakeetService.shared.prepare()
        let loaded = now()
        let result = try await ParakeetService.shared.transcribe(samples)
        let text = await ParakeetService.shared.boost(text: result.text, timings: result.tokenTimings ?? [],
                                                      audio: ParakeetService.padded(samples), terms: hints)
        let finished = now()
        return (loaded - start, finished - loaded, text)
    }

    // MARK: - Report

    var reportMarkdown: String {
        var lines = ["# Warble speech engine comparison", ""]
        lines.append("Date: \(Date().formatted(date: .abbreviated, time: .shortened))  ")
        lines.append("Recording: \(String(format: "%.1f", results.first?.audioSeconds ?? 0)) seconds of you reading the passage  ")
        lines.append("Mac: \(Self.macDescription)")
        lines.append("")
        lines.append("| | " + results.map(\.name).joined(separator: " | ") + " |")
        lines.append("|---|" + results.map { _ in "---|" }.joined())
        lines.append("| Words right | " + results.map { String(format: "%.1f%%", $0.accuracy * 100) }.joined(separator: " | ") + " |")
        lines.append("| Word errors (wrong / missing / extra) | " + results.map {
            "\($0.score.errors) (\($0.score.substitutions) / \($0.score.deletions) / \($0.score.insertions))"
        }.joined(separator: " | ") + " |")
        if !terms.isEmpty {
            lines.append("| Word List terms heard | " + results.map { "\(terms.count - $0.missedTerms.count) of \(terms.count)" }.joined(separator: " | ") + " |")
        }
        lines.append("| Time to transcribe | " + results.map { String(format: "%.2f s", $0.processingSeconds) }.joined(separator: " | ") + " |")
        lines.append("| Speed | " + results.map { String(format: "%.0f× real time", $0.speed) }.joined(separator: " | ") + " |")
        lines.append("| Model load (first use this session) | " + results.map { String(format: "%.2f s", $0.loadSeconds) }.joined(separator: " | ") + " |")
        lines.append("")
        lines.append("## What was read")
        lines.append("")
        lines.append(passage)
        for result in results {
            lines.append("")
            lines.append("## \(result.name) heard")
            lines.append("")
            lines.append(result.transcript.isEmpty ? "(nothing)" : result.transcript)
            if !result.missedTerms.isEmpty {
                lines.append("")
                lines.append("Missed Word List terms: \(result.missedTerms.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func saveReport(audioSeconds: Double, problems: [String]) -> URL? {
        let folder = URL(fileURLWithPath: appState.masterFolderPath).appendingPathComponent("Warble Benchmarks", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let url = folder.appendingPathComponent("Engine comparison \(formatter.string(from: Date())).md")
        var text = reportMarkdown
        if !problems.isEmpty { text += "\n\n## Problems\n\n" + problems.map { "- " + $0 }.joined(separator: "\n") }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            BenchmarkRecorder.writeWAV(samples, to: url.deletingPathExtension().appendingPathExtension("caf"))
            return url
        } catch {
            return nil
        }
    }

    private static var macDescription: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        let chip = String(cString: chars)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(chip.isEmpty ? "Apple silicon" : chip), macOS \(os)"
    }
}

extension EngineBenchmark.EngineResult {
    var accuracy: Double { score.accuracy }
}

/// Records the microphone as 16 kHz mono samples, the format both engines use.
final class BenchmarkRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: 1, interleaved: false)!

    /// Loudness 0...1 and seconds recorded, on the main actor.
    var onLevel: (@MainActor (Double, Double) -> Void)?

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw SpeechEngineError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: makeTap(converter: converter))
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func makeTap(converter: AVAudioConverter) -> AVAudioNodeTapBlock {
        return { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = Self.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = output.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
            let peak = chunk.reduce(Float(0)) { max($0, abs($1)) }
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            let seconds = Double(self.samples.count) / Self.sampleRate
            self.lock.unlock()
            let onLevel = self.onLevel
            Task { @MainActor in onLevel?(min(1, Double(peak) * 2), seconds) }
        }
    }

    /// Splits samples into buffers for feeding a streaming engine.
    static func buffers(from samples: [Float], frames: Int = 1600) -> [AVAudioPCMBuffer] {
        stride(from: 0, to: samples.count, by: frames).compactMap { start in
            let count = min(frames, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData?[0] else { return nil }
            samples.withUnsafeBufferPointer { source in
                data.update(from: source.baseAddress! + start, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            return buffer
        }
    }

    /// Keeps the recording next to the report, so a result can be checked later.
    static func writeWAV(_ samples: [Float], to url: URL) {
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
        for buffer in buffers(from: samples, frames: 16_000) {
            try? file.write(from: buffer)
        }
    }
}
