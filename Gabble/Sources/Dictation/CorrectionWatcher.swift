import AppKit
import ApplicationServices

/// Works out what the user changed inside text Gabble typed. Pure and tested.
enum CorrectionDiff {
    /// Given the field's text right after Gabble typed `inserted` (`before`) and
    /// a little later (`after`), returns the user's edited version of `inserted`,
    /// or nil if the change wasn't inside Gabble's text.
    static func editedVersion(of inserted: String, before: String, after: String) -> String? {
        guard before != after, !inserted.isEmpty,
              let insertedRange = before.range(of: inserted, options: .backwards) else { return nil }

        let b = Array(before), a = Array(after)
        var prefix = 0
        while prefix < b.count, prefix < a.count, b[prefix] == a[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < b.count - prefix, suffix < a.count - prefix,
              b[b.count - 1 - suffix] == a[a.count - 1 - suffix] { suffix += 1 }

        let changeStart = prefix
        let changeEnd = b.count - suffix
        let insStart = before.distance(from: before.startIndex, to: insertedRange.lowerBound)
        let insEnd = before.distance(from: before.startIndex, to: insertedRange.upperBound)
        guard changeStart >= insStart, changeEnd <= insEnd, changeStart < insEnd else { return nil }
        // Typing straight before or after Gabble's text is not a correction of it.
        if changeStart == changeEnd, changeStart == insStart || changeStart == insEnd { return nil }

        let replacement = String(a[prefix..<(a.count - suffix)])
        var edited = Array(inserted)
        edited.replaceSubrange((changeStart - insStart)..<(changeEnd - insStart), with: Array(replacement))
        return String(edited)
    }
}

/// After Gabble types something, quietly checks the same text field a few
/// seconds later to see whether the user fixed a word, so it can learn it.
@MainActor
final class CorrectionWatcher {
    private var pending: Task<Void, Never>?

    func watch(inserted: String, delay: Duration = .seconds(12),
               onCorrection: @escaping (_ original: String, _ edited: String) -> Void) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard let element = Self.focusedTextElement(),
                  let before = Self.value(of: element), before.contains(inserted) else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let after = Self.value(of: element),
                  let edited = CorrectionDiff.editedVersion(of: inserted, before: before, after: after),
                  edited != inserted else { return }
            onCorrection(inserted, edited)
        }
    }

    private static func focusedTextElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subrole = subrole as? String, subrole == (kAXSecureTextFieldSubrole as String) {
            return nil // never read password fields
        }
        return element
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        guard let text = value as? String, text.count < 200_000 else { return nil }
        return text
    }
}
