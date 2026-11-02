import AppKit
import SwiftUI

/// Optional "Matrix effect while dictating": a stream of green characters over
/// the text box you're dictating into, until the tidied text goes in. It never
/// takes focus or clicks, so typing still reaches your app.
@MainActor
final class MatrixOverlay {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: MatrixRainView())
    }

    /// Covers `area` (Cocoa screen coordinates, bottom-left origin).
    func show(over area: CGRect) {
        panel.setFrame(area, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: - Where to draw (pure, unit tested)

    /// The tallest area the effect covers, so a huge text area (a whole web
    /// page or document) gets a band around the cursor instead.
    nonisolated static let maxHeight: CGFloat = 240
    nonisolated static let caretBand: CGFloat = 120

    /// Picks the area to cover from the focused text box's frame and the
    /// cursor's bounds, both in Accessibility coordinates (top-left origin).
    /// Nil when Warble can't tell where the text is: then only the capsule shows.
    nonisolated static func area(field: CGRect?, caret: CGRect?) -> CGRect? {
        let field = field.flatMap { $0.width >= 40 && $0.height >= 14 ? $0 : nil }
        let caret = caret.flatMap { $0.height >= 4 && $0.height < 200 ? $0 : nil }
        if let field, field.height <= maxHeight { return field }
        if let caret {
            let width = min(field?.width ?? 480, 720)
            let x = field?.minX ?? (caret.minX - width / 3)
            var band = CGRect(x: x, y: caret.midY - caretBand / 2, width: width, height: caretBand)
            if let field {
                band = band.intersection(field)
                if band.height < 30 { band = CGRect(x: field.minX, y: caret.midY - caretBand / 2, width: field.width, height: caretBand) }
            }
            return band
        }
        if let field {
            return CGRect(x: field.minX, y: field.minY, width: field.width, height: maxHeight)
        }
        return nil
    }

    /// Accessibility rectangles are measured from the top of the main display;
    /// windows are placed from the bottom.
    nonisolated static func cocoaRect(fromAccessibility rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Columns of falling characters, worked out from the time alone (no state),
/// so it costs nothing while hidden.
struct MatrixRainView: View {
    private static let glyphs = Array("01アイウエオカキクケコサシスセソタチツテト0101ABCDEFXYZ")
    private static let cell: CGFloat = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .background(WarbleColor.background.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WarbleColor.green.opacity(0.35), lineWidth: 1))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let columns = Int(size.width / Self.cell) + 1
        let rows = Int(size.height / Self.cell) + 1
        let trail = max(6, rows / 2)
        for column in 0..<columns {
            let seed = Self.noise(column, 7)
            let speed = 6 + seed * 10                 // rows per second
            let span = Double(rows + trail)
            let head = Int((time * speed + seed * span * 3).truncatingRemainder(dividingBy: span))
            for step in 0..<trail {
                let row = head - step
                guard row >= 0, row < rows else { continue }
                let flicker = Int(time * 8) + row * 31
                let glyph = Self.glyphs[Int(Self.noise(column * 131 + row, flicker) * Double(Self.glyphs.count)) % Self.glyphs.count]
                let fade = 1 - Double(step) / Double(trail)
                let colour = step == 0 ? WarbleColor.glow : WarbleColor.green.opacity(fade * 0.9)
                context.draw(Text(String(glyph)).font(.system(size: 11, design: .monospaced)).foregroundStyle(colour),
                             at: CGPoint(x: CGFloat(column) * Self.cell + Self.cell / 2,
                                         y: CGFloat(row) * Self.cell + Self.cell / 2))
            }
        }
    }

    /// A repeatable 0..<1 number for a pair of integers.
    private static func noise(_ a: Int, _ b: Int) -> Double {
        var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }
}
