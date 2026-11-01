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
    /// New stretches of the other side's audio, labelled by voice.
    var onVoices: (([VoiceSegment]) -> Void)?
    /// Recognises who is speaking on the other side of the call.
    let speakers: SpeakerIdentifier
    /// Whether you, or the other side, are talking right now (from sound levels).
    let meMeter = SpeakingMeter(threshold: 0.02)
    let othersMeter = SpeakingMeter(threshold: 0.008)

    private let microphone = MicrophoneCapture()
    private let micTranscriber = StreamTranscriber()
    private let callTranscriber = StreamTranscriber()
    private var systemCapture: SystemAudioCapture?
    private let micWriter: AudioFileWriter
    private let callWriter: AudioFileWriter
    private var liveMe = ""
    private var liveOthers = ""
    let folder: URL

    init(app: CallApp, recordingsFolder: URL) {
        let started = Date()
        transcript = CallTranscript(appName: app.name, started: started)
        speakers = SpeakerIdentifier(origin: started)
        let stamp = CallTranscript.isoFormatter.string(from: started).replacingOccurrences(of: ":", with: "-")
        folder = recordingsFolder.appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        micWriter = AudioFileWriter(url: folder.appendingPathComponent("me.caf"))
        callWriter = AudioFileWriter(url: folder.appendingPathComponent("others.caf"))
        self.app = app
    }

    private let app: CallApp

    func start(hints: [String], knownVoices: [Voiceprint] = []) async throws {
        speakers.onSegments = { [weak self] segments in self?.onVoices?(segments) }
        micTranscriber.onFinal = { [weak self] text in self?.add(Self.meLabel, text) }
        micTranscriber.onVolatile = { [weak self] text in self?.liveMe = text; self?.publish() }
        callTranscriber.onFinal = { [weak self] text in self?.add(Self.othersLabel, text) }
        callTranscriber.onVolatile = { [weak self] text in self?.liveOthers = text; self?.publish() }

        try await micTranscriber.start(hints: hints)
        try await callTranscriber.start(hints: hints)

        // The other people on the call.
        let callTranscriber = self.callTranscriber
        let callWriter = self.callWriter
        let speakers = self.speakers
        let othersMeter = self.othersMeter
        let capture = SystemAudioCapture { buffer in
            othersMeter.feed(buffer)
            callTranscriber.feed(buffer)
            callWriter.write(buffer)
            speakers.append(buffer)
        }
        try await capture.start(bundlePrefixes: app.bundlePrefixes, appName: app.name)
        systemCapture = capture

        // Voice recognition is a bonus: if its models can't load, the call is
        // still transcribed as Me and Others.
        Task.detached { try? await speakers.prepare(known: knownVoices) }

        // You, on the same microphone the call app uses. MicrophoneCapture keeps
        // recording when AirPods connect, disconnect or switch mode mid-call.
        let micTranscriber = self.micTranscriber
        let micWriter = self.micWriter
        let meMeter = self.meMeter
        try await microphone.start(deviceUID: MicrophoneChoice.systemDefault) { buffer in
            meMeter.feed(buffer)
            micTranscriber.feed(buffer)
            micWriter.write(buffer)
        }
    }

    func stop() async -> CallTranscript {
        microphone.stop()
        await systemCapture?.stop()
        systemCapture = nil
        await micTranscriber.stop()
        await callTranscriber.stop()
        await speakers.finish()
        micWriter.close()
        callWriter.close()
        transcript.ended = Date()
        return transcript
    }

    /// Both recordings, labelled, with where each starts on the transcript's clock.
    /// Used to re-read the call with Parakeet once it ends.
    var recordings: [CallRetranscriber.Recording] {
        let sides: [(AudioFileWriter, String)] = [(micWriter, Self.meLabel), (callWriter, Self.othersLabel)]
        return sides.compactMap { (writer, label) -> CallRetranscriber.Recording? in
            guard let first = writer.firstWrite else { return nil }
            return CallRetranscriber.Recording(file: writer.fileURL, speaker: label,
                                               startOffset: first.timeIntervalSince(transcript.started))
        }
    }

    private func add(_ speaker: String, _ text: String) {
        transcript.add(speaker: speaker, text: text, at: Date())
        publish()
    }

    private func publish() {
        onUpdate?(transcript, liveMe, liveOthers)
    }
}

/// Whether someone is talking right now, judged from how loud the audio is.
/// Fed on audio threads; read on the main thread a few times a second.
final class SpeakingMeter: @unchecked Sendable {
    let threshold: Double
    private let lock = NSLock()
    private var lastLoud: Date = .distantPast
    private var latest: Double = 0

    init(threshold: Double) { self.threshold = threshold }

    func feed(_ buffer: AVAudioPCMBuffer) {
        record(level: AudioReformatter.rms(of: buffer))
    }

    func record(level: Double, at time: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        latest = level
        if level >= threshold { lastLoud = time }
    }

    /// The most recent sound level.
    var level: Double {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Talking now, or in the last `hold` seconds (so it doesn't flicker
    /// between words).
    func isSpeaking(hold: TimeInterval = 0.5, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return now.timeIntervalSince(lastLoud) <= hold
    }
}

/// Writes audio buffers to a file from any thread.
final class AudioFileWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var closed = false
    private var started: Date?
    /// The file keeps the first buffer's format; later audio in another format
    /// (the microphone changed mid-call) is converted to it.
    private var reformatter: AudioReformatter?

    init(url: URL) { self.url = url }

    var fileURL: URL { url }

    /// When the first audio arrived; the file's timeline starts here.
    var firstWrite: Date? {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if started == nil { started = Date() }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                    commonFormat: buffer.format.commonFormat,
                                    interleaved: buffer.format.isInterleaved)
        }
        guard let file else { return }
        if buffer.format == file.processingFormat {
            try? file.write(from: buffer)
            return
        }
        if reformatter?.target != file.processingFormat {
            reformatter = AudioReformatter(target: file.processingFormat)
        }
        if let converted = reformatter?.convert(buffer) {
            try? file.write(from: converted)
        }
    }

    func close() {
        lock.lock()
        closed = true
        file = nil
        lock.unlock()
    }
}
