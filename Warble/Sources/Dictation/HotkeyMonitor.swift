import AppKit
import Carbon.HIToolbox

/// The key the user holds to dictate.
/// Only keys that type nothing on their own, so holding one to talk never
/// puts a character in your text. Pressed together with another key (as in
/// a shortcut like Shift-A or Control-C) they're left to that shortcut.
enum DictationKey: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightShift, leftControl, rightControl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn (🌐) key"
        case .rightOption: return "Right Option (⌥) key"
        case .rightCommand: return "Right Command (⌘) key"
        case .rightShift: return "Right Shift (⇧) key"
        case .leftControl: return "Control (⌃) key"
        case .rightControl: return "Right Control (⌃) key"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .fn: return UInt16(kVK_Function)
        case .rightOption: return UInt16(kVK_RightOption)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .rightShift: return UInt16(kVK_RightShift)
        case .leftControl: return UInt16(kVK_Control)
        case .rightControl: return UInt16(kVK_RightControl)
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightShift: return .shift
        case .leftControl, .rightControl: return .control
        }
    }
}

/// Watches a modifier key system-wide and reports when it goes down and up.
/// Needs the Accessibility permission to see key presses in other apps.
@MainActor
final class HotkeyMonitor {
    /// Called with when the key went down or up (seconds since the Mac started,
    /// from the key event itself), so a busy moment in Warble can't make a
    /// quick tap look like a long hold.
    var onPress: ((TimeInterval) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    /// Another key went down soon after the dictation key: it's part of a
    /// shortcut (Shift-A, Control-C, Fn-Delete), not a press to talk.
    var onUsedInShortcut: (() -> Void)?

    /// Only another key this soon after the press counts as a shortcut; later
    /// on you're talking, and a stray key mustn't throw that away.
    static let shortcutWindow: TimeInterval = 1.0

    private var monitors: [Any] = []
    private var key: DictationKey = .fn
    private var isDown = false
    private var downAt: TimeInterval = 0

    func start(key: DictationKey) {
        stop()
        self.key = key
        let kinds: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
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
        guard event.keyCode == key.keyCode, event.type == .flagsChanged else {
            if isDown, Self.isShortcut(otherKeyAt: event.timestamp, pressedAt: downAt) { onUsedInShortcut?() }
            return
        }
        let down = event.modifierFlags.contains(key.flag)
        guard down != isDown else { return }
        isDown = down
        if down {
            downAt = event.timestamp
            onPress?(event.timestamp)
        } else {
            onRelease?(event.timestamp)
        }
    }

    /// Whether another key at `time`, with the dictation key held since
    /// `pressedAt`, makes this press part of a shortcut. Pure, unit tested.
    nonisolated static func isShortcut(otherKeyAt time: TimeInterval, pressedAt: TimeInterval) -> Bool {
        time - pressedAt <= shortcutWindow
    }
}
