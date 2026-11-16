import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum SystemAudioTapError: LocalizedError {
    case failed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .failed(let step, let status): return "Warble couldn't \(step) to hear the call (error \(status))."
        }
    }
}

/// Hears everything this Mac plays (except Warble itself) with a Core Audio
/// process tap. Used for FaceTime: its calls are played by a macOS service
/// (avconferenced) rather than the FaceTime app, and ScreenCaptureKit's
/// recording of the Mac's sound came back with nothing from a FaceTime call
/// (Jonny, build 45). Needs the "System Audio Recording" permission, which
/// macOS asks for the first time.
final class SystemAudioTap: @unchecked Sendable {
    private let onBuffer: @Sendable (_ buffer: AVAudioPCMBuffer, _ isGap: Bool) -> Void
    private let queue = DispatchQueue(label: "warble.system-tap")
    private static let unknown = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// What the tap delivers, for the call log.
    private(set) var formatDescription = ""

    init(onBuffer: @escaping @Sendable (_ buffer: AVAudioPCMBuffer, _ isGap: Bool) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw SystemAudioTapError.failed("set up a system audio tap", status) }
        tapID = tap

        guard let outputUID = Self.defaultOutputUID() else {
            stop()
            throw SystemAudioTapError.failed("find your speakers or headphones", -1)
        }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Warble call audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else {
            stop()
            throw SystemAudioTapError.failed("set up a private audio device", status)
        }
        aggregateID = aggregate

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &stream) else {
            stop()
            throw SystemAudioTapError.failed("read the call audio format", status)
        }
        formatDescription = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch"

        let onBuffer = self.onBuffer
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
            // The audio is only valid during this call: take a mono copy.
            guard let shared = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let mono = Self.mono(shared) else { return }
            onBuffer(mono, false)
        }
        guard status == noErr, let proc else {
            stop()
            throw SystemAudioTapError.failed("listen to the call audio", status)
        }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else {
            stop()
            throw SystemAudioTapError.failed("start listening to the call audio", status)
        }
    }

    func stop() {
        if let procID, aggregateID != Self.unknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != Self.unknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != Self.unknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// One channel, float, at the same rate: the average of the channels.
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let source = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let target = out.floatChannelData?[0] else { return nil }
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += interleaved ? source[0][frame * stride + channel] : source[channel][frame]
            }
            target[frame] = sum / Float(channels)
        }
        out.frameLength = AVAudioFrameCount(frames)
        return out
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != Self.unknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != Self.unknown else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// A short plain-text log kept with each recording (call-log.txt): how the
/// call was heard, and how loud each side was every 10 seconds, so a call
/// that comes out empty can be diagnosed from its folder.
final class CallLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let started = Date()
    private var peaks: [String: Double] = [:]
    private var buffers: [String: Int] = [:]
    private var lastSummary = Date()

    init(folder: URL) {
        url = folder.appendingPathComponent("call-log.txt")
    }

    func note(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        writeLocked(text)
    }

    /// Called with each buffer of one side ("me" or "others").
    func heard(_ side: String, level: Double) {
        lock.lock()
        defer { lock.unlock() }
        peaks[side] = max(peaks[side] ?? 0, level)
        buffers[side, default: 0] += 1
        guard Date().timeIntervalSince(lastSummary) >= 10 else { return }
        lastSummary = Date()
        let parts = ["me", "others"].map { side in
            String(format: "%@ %d buffers, peak %.4f", side, buffers[side] ?? 0, peaks[side] ?? 0)
        }
        writeLocked(parts.joined(separator: "; "))
        peaks = [:]
        buffers = [:]
    }

    private func writeLocked(_ text: String) {
        let line = String(format: "%7.1f s  ", Date().timeIntervalSince(started)) + text + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
