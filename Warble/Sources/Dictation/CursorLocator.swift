import AppKit
import ApplicationServices

/// Where the focused text box and its cursor are, in Accessibility
/// coordinates (top-left origin of the main display).
struct CursorSpot: Equatable {
    /// The text box. Nil when the app doesn't say.
    var field: CGRect?
    /// A zero-width line at the right edge of the last letter before the
    /// cursor (or of the selection, when text is selected). Nil when unknown.
    var caret: CGRect?
    /// More text follows the cursor on the same line, so the listening ball
    /// must not sit to its right.
    var textAfter = false
}

/// Asks the focused app where its cursor is. Every question has a short time
/// limit, and none of it needs the main thread, so a slow app (Claude, Slack,
/// browsers) can't make Warble stutter while the listening ball follows it.
enum CursorLocator {
    /// How long one Accessibility question may take before Warble gives up on it.
    static let timeLimit: Float = 0.1

    /// The cursor in app `pid`'s focused element, without checking that it's a
    /// text box (the caller already did, when dictation started). Every
    /// question, including finding the focused element, has the short time
    /// limit. Safe off the main thread.
    nonisolated static func current(pid: pid_t) -> CursorSpot? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeLimit)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return spot(for: focused as! AXUIElement)
    }

    /// The text box's frame and its cursor. Safe off the main thread.
    nonisolated static func spot(for element: AXUIElement) -> CursorSpot? {
        // Only this element gets the short limit; Warble's other questions keep theirs.
        AXUIElementSetMessagingTimeout(element, timeLimit)
        var spot = CursorSpot()
        spot.field = frame(of: element)
        if let range = selectedRange(of: element) {
            let end = range.location + range.length
            if end > 0, string(element, CFRange(location: end - 1, length: 1)) != "\n",
               let letter = bounds(element, CFRange(location: end - 1, length: 1)),
               letter.width > 0, letter.width < maxLetterWidth {
                // The last letter before the cursor: its right edge is where the
                // cursor is drawn. More reliable than the empty range at the
                // cursor, which many apps report as zero-sized or not at all.
                spot.caret = CGRect(x: letter.maxX, y: letter.minY, width: 0, height: letter.height)
            } else if let empty = bounds(element, CFRange(location: end, length: 0)), isCaret(empty) {
                spot.caret = empty
            }
            if let caret = spot.caret, let next = bounds(element, CFRange(location: end, length: 1)),
               next.width > 0, abs(next.midY - caret.midY) < max(caret.height, 4) / 2 {
                spot.textAfter = true
            }
        }
        if spot.caret == nil, let marked = selectionBounds(of: element) {
            // Chromium and WebKit (Claude, Slack, browsers) often have no usable
            // character ranges but do answer through text markers.
            spot.caret = CGRect(x: marked.maxX, y: marked.minY, width: 0, height: marked.height)
        }
        return spot.field == nil && spot.caret == nil ? nil : spot
    }

    /// Wider than any letter: an app that answers a letter's bounds with its
    /// whole line or box is giving no cursor position at all.
    nonisolated static let maxLetterWidth: CGFloat = 60

    /// A plausible cursor: a thin, line-high rectangle. Some apps answer the
    /// empty range at the cursor with the whole box, or with nothing (zero size).
    nonisolated static func isCaret(_ rect: CGRect) -> Bool {
        rect.height >= 4 && rect.height < 200 && rect.width <= 4
    }

    // MARK: - Accessibility helpers

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    nonisolated private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range
    }

    nonisolated private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The selection (or the cursor, when nothing is selected) through
    /// WebKit/Chromium text markers. Nil in apps that don't have them.
    nonisolated private static func selectionBounds(of element: AXUIElement) -> CGRect? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success,
              let marker else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString,
                                                         marker, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect),
              rect.height >= 4, rect.height < 200, rect.width < maxLetterWidth else { return nil }
        return rect
    }

    nonisolated private static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &value) == .success else { return nil }
        return value as? String
    }
}
