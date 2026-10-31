import AVFoundation
import Foundation

/// Records one call: your microphone and the call app's audio, each transcribed
/// live on-device, and each saved to an audio file for speaker recognition later.
@MainActor
final class CallRecorder {
    static let meLabel = "Me"
    static let othersLabel = "Others"

    private(set) var transcript: CallTranscript
    var onUpdate: ((CallTranscript, _ liveMe: String, _ liveOthers: String) -> Void)?

    private let micEngine = AVAudioEngine()
    private let micTranscriber = StreamTranscriber()
    private let callTranscriber = StreamTranscriber()
    private var systemCapture: SystemAudioCapture?
    private let micWriter: AudioFileWriter
    private let callWriter: AudioFileWriter
    private var liveMe = ""
    private var liveOthers = ""
    let folder: URL

    init(app: CallApp, recordingsFolder: URL) {
        transcript = CallTranscript(appName: app.name, started: Date())
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        folder = recordingsFolder.appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        micWriter = AudioFileWriter(url: folder.appendingPathComponent("me.caf"))
        callWriter = AudioFileWriter(url: folder.appendingPathComponent("others.caf"))
        self.app = app
    }

    private let app: CallApp

    func start(hints: [String]) async throws {
        micTranscriber.onFinal = { [weak self] text in self?.add(Self.meLabel, text) }
        micTranscriber.onVolatile = { [weak self] text in self?.liveMe = text; self?.publish() }
        callTranscriber.onFinal = { [weak self] text in self?.add(Self.othersLabel, text) }
        callTranscriber.onVolatile = { [weak self] text in self?.liveOthers = text; self?.publish() }

        try await micTranscriber.start(hints: hints)
        try await callTranscriber.start(hints: hints)

        // The other people on the call.
        let callTranscriber = self.callTranscriber
        let callWriter = self.callWriter
        let capture = SystemAudioCapture { buffer in
            callTranscriber.feed(buffer)
            callWriter.write(buffer)
        }
        try await capture.start(bundlePrefixes: app.bundlePrefixes, appName: app.name)
        systemCapture = capture

        // You.
        let input = micEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format,
                         block: Self.makeMicTap(transcriber: micTranscriber, writer: micWriter))
        micEngine.prepare()
        try micEngine.start()
    }

    func stop() async -> CallTranscript {
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        await systemCapture?.stop()
        systemCapture = nil
        await micTranscriber.stop()
        await callTranscriber.stop()
        micWriter.close()
        callWriter.close()
        transcript.ended = Date()
        return transcript
    }

    private func add(_ speaker: String, _ text: String) {
        transcript.add(speaker: speaker, text: text, at: Date())
        publish()
    }

    private func publish() {
        onUpdate?(transcript, liveMe, liveOthers)
    }

    nonisolated private static func makeMicTap(transcriber: StreamTranscriber,
                                               writer: AudioFileWriter) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            transcriber.feed(buffer)
            writer.write(buffer)
        }
    }
}

/// Writes audio buffers to a file from any thread.
final class AudioFileWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var closed = false

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                    commonFormat: buffer.format.commonFormat,
                                    interleaved: buffer.format.isInterleaved)
        }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock()
        closed = true
        file = nil
        lock.unlock()
    }
}
