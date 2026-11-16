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
    private var systemTap: SystemAudioTap?
    /// How the call was heard, kept with the recording (call-log.txt).
    let log: CallLog
    /// Why the other side couldn't be heard, if it couldn't (the call is
    /// then recorded from your microphone alone).
    private(set) var othersProblem: String?
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
        log = CallLog(folder: folder)
        self.app = app
    }

    private let app: CallApp

    func start(hints: [String]) async throws {
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
        let log = self.log
        let others: @Sendable (AVAudioPCMBuffer, Bool) -> Void = { buffer, isGap in
            let level = AudioReformatter.rms(of: buffer)
            othersMeter.record(level: level)
            log.heard("others", level: level)
            callTranscriber.feed(buffer)
            callWriter.write(buffer)
            // The voice check gets the length of a gap, not its silence.
            if isGap {
                speakers.skip(seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
            } else {
                speakers.append(buffer)
            }
        }
        log.note("\(app.name) call; Warble \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
        if app.prefersTap {
            let tap = SystemAudioTap(onBuffer: others)
            do {
                try tap.start()
                systemTap = tap
                log.note("others: hearing all Mac sound with a Core Audio tap (\(tap.formatDescription))")
            } catch {
                log.note("others: tap failed: \(error.localizedDescription)")
            }
        }
        if systemTap == nil {
            let capture = SystemAudioCapture(onBuffer: others)
            do {
                try await capture.start(bundlePrefixes: app.bundlePrefixes, appName: app.name,
                                        allSound: app.capturesAllSound)
                systemCapture = capture
                log.note("others: ScreenCaptureKit, " + (app.capturesAllSound ? "all Mac sound" : "\(app.name)'s sound"))
            } catch {
                log.note("others: ScreenCaptureKit failed: \(error.localizedDescription)")
                // Without the permission nothing can be heard of the other side;
                // otherwise record your side rather than nothing at all.
                let text = error.localizedDescription.lowercased()
                if text.contains("declined") || text.contains("not authorized") || text.contains("tcc") { throw error }
                othersProblem = error.localizedDescription
            }
        }

        // Voice recognition is a bonus: if its models can't load, the call is
        // still transcribed as Me and Others.
        Task.detached { try? await speakers.prepare() }

        // You, on the same microphone the call app uses. MicrophoneCapture keeps
        // recording when AirPods connect, disconnect or switch mode mid-call.
        let micTranscriber = self.micTranscriber
        let micWriter = self.micWriter
        let meMeter = self.meMeter
        do {
            try await microphone.start(deviceUID: MicrophoneChoice.systemDefault) { buffer in
                let level = AudioReformatter.rms(of: buffer)
                meMeter.record(level: level)
                log.heard("me", level: level)
                micTranscriber.feed(buffer)
                micWriter.write(buffer)
            }
            log.note("me: microphone started")
        } catch {
            log.note("me: microphone failed: \(error.localizedDescription)")
            throw error
        }
    }

    func stop() async -> CallTranscript {
        microphone.stop()
        log.note("stopped")
        systemTap?.stop()
        systemTap = nil
        let capture = systemCapture
        systemCapture = nil
        // Every step has a time limit, so finishing a call can never get stuck
        // (the next call may be about to start).
        _ = await withDeadline(seconds: 5) {
            await capture?.stop()
            return true
        }
        await micTranscriber.stop()
        await callTranscriber.stop()
        let speakers = self.speakers
        _ = await withDeadline(seconds: 20) {
            await speakers.finish()
            return true
        }
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
