import AVFoundation
import CoreAudio
import Foundation

/// A microphone the Mac can record from.
struct InputDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    /// Stable between launches and reconnects, so it's what Settings saves.
    var uid: String
    var name: String
    var isBuiltIn: Bool
    var isBluetooth: Bool
}

/// Lists the Mac's microphones (CoreAudio).
enum InputDevices {
    static func all() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap(device)
    }

    private static func device(_ id: AudioDeviceID) -> InputDevice? {
        guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
        return InputDevice(id: id, uid: uid, name: name,
                           isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                           isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                               || transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// Which microphone dictation uses. Saved in Settings.
enum MicrophoneChoice {
    static let defaultsKey = "dictationMicrophone"
    /// Whatever the Mac's Sound settings use (AirPods, when they're in).
    static let systemDefault = ""
    /// The Mac's own microphone, even with AirPods in. The default: it avoids
    /// switching AirPods into their lower-quality call mode, which is slow,
    /// unreliable and makes music sound like a phone call.
    static let builtIn = "builtin"

    static func saved(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey) ?? builtIn
    }

    /// The device to record from, or nil for the Mac's default. A chosen
    /// microphone that isn't connected falls back to the default.
    static func device(for choice: String, in devices: [InputDevice]) -> InputDevice? {
        switch choice {
        case systemDefault: return nil
        case builtIn: return devices.first(where: \.isBuiltIn)
        default: return devices.first { $0.uid == choice }
        }
    }
}

/// Runs the microphone for dictation.
///
/// Starting a microphone can take seconds, or stall, while macOS switches
/// AirPods into their microphone mode, and the microphone's format changes
/// underneath a running recording when headphones connect or disconnect. So
/// the microphone is started away from the main thread with a time limit (the
/// app never freezes on "Starting…"), restarted when the device changes, and
/// restarted once if no sound arrives at all after starting.
final class MicrophoneCapture: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    struct DidNotStart: LocalizedError {
        var errorDescription: String? {
            "The microphone didn't start. If you just put in or took out AirPods, wait a moment and try again."
        }
    }

    private let queue = DispatchQueue(label: "com.warth0g.warble.microphone")
    private let lock = NSLock()
    // Guarded by `lock`.
    private var generation = 0
    private var buffersSeen = 0
    // Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var handler: Handler?
    private var deviceUID = MicrophoneChoice.systemDefault

    /// Starts recording, sending each buffer (in the microphone's own format) to
    /// `handler` on an audio thread. Throws if the microphone doesn't start in time.
    func start(deviceUID: String, timeout: Double = 4, handler: @escaping Handler) async throws {
        let mine = nextGeneration()
        let started = await withDeadline(seconds: timeout) { [self] () -> Bool in
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard isCurrent(mine) else { return continuation.resume(returning: false) }
                    self.handler = handler
                    self.deviceUID = deviceUID
                    continuation.resume(returning: run(generation: mine))
                }
            }
        }
        guard started == true, isCurrent(mine) else {
            stop()
            throw DidNotStart()
        }
        watchForSilence(generation: mine)
    }

    /// Stops recording. Safe to call at any time, even while a start is stalled.
    func stop() {
        _ = nextGeneration()
        queue.async { [self] in tearDown() }
    }

    // MARK: - On the microphone queue

    private func run(generation mine: Int) -> Bool {
        tearDown()
        let engine = AVAudioEngine()
        if let device = MicrophoneChoice.device(for: deviceUID, in: InputDevices.all()),
           let unit = engine.inputNode.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let handler else { return false }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, self.countBuffer(generation: mine) else { return }
            handler(buffer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // The microphone changed (AirPods connected, switched mode or were
            // taken out). The engine has stopped itself; start again on the new one.
            guard let self else { return }
            self.queue.async {
                guard self.isCurrent(mine) else { return }
                _ = self.run(generation: mine)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        return true
    }

    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// If nothing at all arrives soon after starting (a Bluetooth microphone that
    /// is still switching modes), start the microphone once more.
    private func watchForSilence(generation mine: Int) {
        queue.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard isCurrent(mine), buffers() == 0 else { return }
            _ = run(generation: mine)
        }
    }

    // MARK: - Generations

    private func nextGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        buffersSeen = 0
        return generation
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }

    private func countBuffer(generation value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == generation else { return false }
        buffersSeen += 1
        return true
    }

    private func buffers() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffersSeen
    }
}

/// Converts microphone audio to the format a speech engine wants. Rebuilds
/// itself when the microphone's format changes mid-dictation. Used only on the
/// audio thread.
final class AudioReformatter: @unchecked Sendable {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if source != buffer.format || converter == nil {
            source = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter, buffer.format.sampleRate > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
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
        return error == nil && output.frameLength > 0 ? output : nil
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return Double((sum / Float(count)).squareRoot())
    }
}
