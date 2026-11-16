import AppKit
import CoreAudio
import Darwin

/// A call app that can be watched, with the bundle identifiers it runs under.
struct CallApp: Equatable {
    var name: String
    var bundlePrefixes: [String]
    /// Record everything this Mac plays rather than just this app's sound.
    /// FaceTime's calls are played by a system service (avconferenced), not
    /// by the FaceTime app, so its own sound is silent.
    var capturesAllSound = false
    /// Hear the Mac's sound with a Core Audio tap rather than ScreenCaptureKit
    /// (see SystemAudioTap), falling back to ScreenCaptureKit if it fails.
    var prefersTap = false

    /// A recording you started yourself from the menu bar, with no call app
    /// in use: your microphone, plus whatever this Mac plays.
    static let manual = CallApp(name: "Meeting", bundlePrefixes: [], capturesAllSound: true)

    static let all: [CallApp] = [
        CallApp(name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"]),
        CallApp(name: "Zoom", bundlePrefixes: ["us.zoom."]),
        CallApp(name: "Google Meet", bundlePrefixes: ["com.google.chrome", "com.apple.safari", "company.thebrowser.browser",
                                                      "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.browser"]),
        CallApp(name: "Webex", bundlePrefixes: ["com.cisco.webex", "cisco-systems.spark", "com.webex."]),
        CallApp(name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"]),
        // FaceTime (and iPhone calls on the Mac) take the microphone through
        // avconferenced, which may report no bundle ID (then it's known by
        // its process name).
        CallApp(name: "FaceTime", bundlePrefixes: ["com.apple.facetime", "com.apple.avconferenced",
                                                   "process:avconferenced"],
                capturesAllSound: true, prefersTap: true),
    ]

    static func matching(bundleID: String, enabledNames: [String]) -> CallApp? {
        let id = bundleID.lowercased()
        return all.first { app in
            enabledNames.contains(app.name) && app.bundlePrefixes.contains { id.hasPrefix($0) }
        }
    }
}

/// A process currently using the microphone.
struct MicUser: Equatable {
    var bundleID: String
    var pid: pid_t
}

/// Notices when a watched call app starts and stops using the microphone,
/// using Core Audio's per-process information (macOS 14.2 and later).
@MainActor
final class CallDetector {
    struct ActiveCall: Equatable {
        var app: CallApp
        var bundleID: String
        var pid: pid_t
    }

    var onCallStarted: ((ActiveCall) -> Void)?
    var onCallEnded: ((ActiveCall) -> Void)?
    /// Names of the apps to watch, from settings.
    var enabledApps: [String] = []

    private var timer: Timer?
    private(set) var current: ActiveCall?
    private var lastSeen: Date?
    /// How long the mic must be idle before a call counts as over. Short, so
    /// back-to-back calls are told apart; long enough to ride out AirPods
    /// switching microphones mid-call.
    private let endGrace: TimeInterval = 5

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        update(users: Self.processesUsingMicrophone().filter { $0.pid != ownPID }, now: Date())
    }

    /// One check: which apps are using the microphone at `now`. Separate from
    /// Core Audio so it can be tested.
    func update(users: [MicUser], now: Date) {
        let matches = users.compactMap { user -> ActiveCall? in
            guard let app = CallApp.matching(bundleID: user.bundleID, enabledNames: self.enabledApps) else { return nil }
            return ActiveCall(app: app, bundleID: user.bundleID, pid: user.pid)
        }
        if let call = current {
            if let same = matches.first(where: { $0.app == call.app }) {
                // Still on the call (its audio process may have changed).
                current = same
                lastSeen = now
            } else if call.app.capturesAllSound, !users.isEmpty {
                // FaceTime's microphone moves between macOS services that
                // aren't all recognisable as FaceTime: while anything still
                // has the microphone, the call goes on.
                lastSeen = now
            } else if let lastSeen, now.timeIntervalSince(lastSeen) > endGrace {
                // The call app let go of the microphone: the call is over.
                current = nil
                onCallEnded?(call)
            }
        }
        // A new call: the first time a call app takes the microphone, including
        // straight after another call ends (or in another call app).
        if current == nil, let match = matches.first {
            current = match
            lastSeen = now
            onCallStarted?(match)
        }
    }

    /// The call app using the microphone right now, if any (for "Transcribe this call").
    var activeCall: ActiveCall? { current }

    // MARK: - Core Audio

    nonisolated static func processesUsingMicrophone() -> [MicUser] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard uint32Property(id, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            let pid = pid_t(bitPattern: uint32Property(id, kAudioProcessPropertyPID) ?? 0)
            var bundleID = stringProperty(id, kAudioProcessPropertyBundleID) ?? ""
            // System services (like FaceTime's avconferenced) may have no
            // bundle ID: go by their process name instead.
            if bundleID.isEmpty, let name = processName(pid) { bundleID = "process:" + name.lowercased() }
            guard !bundleID.isEmpty else { return nil }
            return MicUser(bundleID: bundleID, pid: pid)
        }
    }

    nonisolated private static func processName(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
    }

    nonisolated private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    nonisolated private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
