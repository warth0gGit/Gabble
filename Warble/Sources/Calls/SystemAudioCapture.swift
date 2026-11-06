import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum SystemAudioError: LocalizedError {
    case noDisplay
    case appNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Warble couldn't find a display to capture call audio from."
        case .appNotFound(let name): return "Warble couldn't find \(name) to record its audio."
        }
    }
}

/// Captures the sound coming out of one app (the call app) with ScreenCaptureKit.
/// Needs the "Screen & System Audio Recording" permission.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "warble.system-audio")
    /// Called with each buffer of the call app's sound, and with `isGap`
    /// true for the silence put in where the app sent nothing (see below).
    private let onBuffer: @Sendable (_ buffer: AVAudioPCMBuffer, _ isGap: Bool) -> Void
    /// Where the last buffer ended on the capture clock (used on `queue` only).
    private var lastEnd: TimeInterval?

    init(onBuffer: @escaping @Sendable (_ buffer: AVAudioPCMBuffer, _ isGap: Bool) -> Void) {
        self.onBuffer = onBuffer
    }

    func start(bundlePrefixes: [String], appName: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }
        let apps = content.applications.filter { app in
            let id = app.bundleIdentifier.lowercased()
            return bundlePrefixes.contains { id.hasPrefix($0) }
        }
        guard !apps.isEmpty else { throw SystemAudioError.appNotFound(appName) }

        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // We only want sound; keep the video side as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        // If the call app sent nothing for a while (it went quiet, or its
        // sound device changed, e.g. AirPods switching mode), put that much
        // silence in first. Everything downstream counts time by the amount
        // of audio, so without it the voices heard after a gap would be
        // matched to the wrong lines of the transcript.
        let start = sampleBuffer.presentationTimeStamp.seconds
        let rate = buffer.format.sampleRate
        if start.isFinite, rate > 0 {
            let missing = AudioGap.silentFrames(previousEnd: lastEnd, start: start, sampleRate: rate)
            for frames in AudioGap.pieces(missing, sampleRate: rate) {
                guard let silence = Self.silence(frames: frames, format: buffer.format) else { break }
                onBuffer(silence, true)
            }
            lastEnd = start + Double(buffer.frameLength) / rate
        }
        onBuffer(buffer, false)
    }

    /// A stretch of silence in the given format.
    static func silence(frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
        return buffer
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// How much silence to put in where the call app's audio skipped ahead.
/// Pure, unit tested.
enum AudioGap {
    /// Shorter jumps are ordinary unevenness between buffers.
    static let minimum: TimeInterval = 0.2
    /// Longer jumps are taken to be the clock being reset, not silence.
    static let maximum: TimeInterval = 600
    /// The most silence put in for one gap. Every second of it goes through
    /// the recording and the transcriber at once, so a very long gap would
    /// mean a burst of work and memory; past this, the voices after the gap
    /// are off by the extra (a minute of silence is ~11.5 MB of the call
    /// app's 48 kHz mono sound). The voice check is not given the silence
    /// (digital silence makes every voice sound alike to it); it is told how
    /// long the gap was instead (`SpeakerIdentifier.skip`).
    static let mostFilled: TimeInterval = 60

    /// Frames of silence to add before a buffer that starts at `start`
    /// (seconds on the capture clock), when the previous one ended at `previousEnd`.
    static func silentFrames(previousEnd: TimeInterval?, start: TimeInterval, sampleRate: Double) -> Int {
        guard let previousEnd, sampleRate > 0 else { return 0 }
        let gap = start - previousEnd
        guard gap >= minimum, gap <= maximum else { return 0 }
        return Int((min(gap, mostFilled) * sampleRate).rounded())
    }

    /// `frames` of silence split into buffers of at most a second each.
    static func pieces(_ frames: Int, sampleRate: Double) -> [Int] {
        let size = max(1, Int(sampleRate))
        guard frames > 0 else { return [] }
        return stride(from: 0, to: frames, by: size).map { min(size, frames - $0) }
    }
}
