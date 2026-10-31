import AppKit
import Carbon.HIToolbox

/// The key the user holds to dictate.
enum DictationKey: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn (🌐) key"
        case .rightOption: return "Right Option (⌥) key"
        case .rightCommand: return "Right Command (⌘) key"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .fn: return UInt16(kVK_Function)
        case .rightOption: return UInt16(kVK_RightOption)
        case .rightCommand: return UInt16(kVK_RightCommand)
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightOption: return .option
        case .rightCommand: return .command
        }
    }
}

/// Watches a modifier key system-wide and reports when it goes down and up.
/// Needs the Accessibility permission to see key presses in other apps.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var monitors: [Any] = []
    private var key: DictationKey = .fn
    private var isDown = false

    func start(key: DictationKey) {
        stop()
        self.key = key
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == key.keyCode else { return }
        let down = event.modifierFlags.contains(key.flag)
        guard down != isDown else { return }
        isDown = down
        if down { onPress?() } else { onRelease?() }
    }
}
