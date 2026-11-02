import AppKit
import SwiftUI

/// The listening indicator shown right in the text box you're dictating into:
/// the green Warble waveform with a timer, then "Tidying…" when you stop.
/// When Warble can't tell where the text box is, the capsule at the bottom of
/// the screen is used instead. It never takes focus or clicks, so typing still
/// reaches your app.
@MainActor
final class InFieldIndicator {
    private let panel: NSPanel

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
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
        panel.contentView = NSHostingView(rootView: InFieldIndicatorView().environmentObject(controller))
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

    /// The indicator's height: a strip, however tall the text box is.
    nonisolated static let stripHeight: CGFloat = 44
    /// Width used when only the cursor position is known.
    nonisolated static let caretWidth: CGFloat = 480

    /// Picks the strip to cover from the focused text box's frame and the
    /// cursor's bounds, both in Accessibility coordinates (top-left origin).
    /// Nil when Warble can't tell where the text is: then the capsule shows.
    nonisolated static func area(field: CGRect?, caret: CGRect?) -> CGRect? {
        let field = field.flatMap { $0.width >= 60 && $0.height >= 14 ? $0 : nil }
        let caret = caret.flatMap { $0.height >= 4 && $0.height < 200 ? $0 : nil }
        if let field {
            let height = min(field.height, stripHeight)
            // Centered on the cursor's line when known, kept inside the box.
            let centre = caret?.midY ?? field.midY
            let y = min(max(centre - height / 2, field.minY), field.maxY - height)
            return CGRect(x: field.minX, y: y, width: field.width, height: height)
        }
        if let caret {
            return CGRect(x: caret.minX - caretWidth / 3, y: caret.midY - stripHeight / 2,
                          width: caretWidth, height: stripHeight)
        }
        return nil
    }

    /// Accessibility rectangles are measured from the top of the main display;
    /// windows are placed from the bottom.
    nonisolated static func cocoaRect(fromAccessibility rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Waveform plus timer, filling the strip over the text box.
struct InFieldIndicatorView: View {
    @EnvironmentObject private var controller: DictationController

    private var isListening: Bool { controller.phase == .listening }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                Circle()
                    .fill(isListening ? WarbleColor.green : WarbleColor.idle)
                    .frame(width: 8, height: 8)
                    .shadow(color: WarbleColor.glow.opacity(isListening ? 0.8 : 0), radius: 4)
                WaveformRibbon(level: controller.level, isActive: isListening, strands: 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(12, geometry.size.height - 10))
                status
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(WarbleColor.idle)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(WarbleColor.background.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(WarbleColor.green.opacity(isListening ? 0.35 : 0.15), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .listening:
            if let start = controller.startedAt {
                Text(start, style: .timer)
            } else {
                Text("0:00")
            }
        case .processing:
            Text("Tidying…")
        case .preparing:
            Text("0:00")
        case .idle:
            EmptyView()
        }
    }
}
