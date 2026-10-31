import AppKit
import CoreAudio

/// A call app that can be watched, with the bundle identifiers it runs under.
struct CallApp: Equatable {
    var name: String
    var bundlePrefixes: [String]

    static let all: [CallApp] = [
        CallApp(name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"]),
        CallApp(name: "Zoom", bundlePrefixes: ["us.zoom."]),
        CallApp(name: "Google Meet", bundlePrefixes: ["com.google.chrome", "com.apple.safari", "company.thebrowser.browser",
                                                      "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.browser"]),
        CallApp(name: "Webex", bundlePrefixes: ["com.cisco.webex", "cisco-systems.spark", "com.webex."]),
        CallApp(name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"]),
        CallApp(name: "FaceTime", bundlePrefixes: ["com.apple.facetime"]),
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
    /// How long the mic must be idle before a call counts as over.
    private let endGrace: TimeInterval = 12

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
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
        let users = Self.processesUsingMicrophone().filter { $0.pid != ownPID }
        let match = users.lazy.compactMap { user -> ActiveCall? in
            guard let app = CallApp.matching(bundleID: user.bundleID, enabledNames: self.enabledApps) else { return nil }
            return ActiveCall(app: app, bundleID: user.bundleID, pid: user.pid)
        }.first

        if let match {
            lastSeen = Date()
            if current == nil {
                current = match
                onCallStarted?(match)
            }
        } else if let call = current, let lastSeen, Date().timeIntervalSince(lastSeen) > endGrace {
            current = nil
            onCallEnded?(call)
        }
    }

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
            guard uint32Property(id, kAudioProcessPropertyIsRunningInput) == 1,
                  let bundleID = stringProperty(id, kAudioProcessPropertyBundleID), !bundleID.isEmpty else { return nil }
            let pid = pid_t(bitPattern: uint32Property(id, kAudioProcessPropertyPID) ?? 0)
            return MicUser(bundleID: bundleID, pid: pid)
        }
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
