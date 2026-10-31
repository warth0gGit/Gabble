import AppKit
import SwiftUI

/// The small floating capsule at the bottom of the screen while dictating.
/// It never takes focus, so text still goes to the app you were using.
@MainActor
final class DictationHUD {
    private let panel: NSPanel

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
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
        let host = NSHostingView(rootView: DictationHUDView().environmentObject(controller))
        host.frame = panel.contentLayoutRect
        panel.contentView = host
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct DictationHUDView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if !controller.liveText.isEmpty, controller.phase == .listening {
                Text(controller.liveText)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(GabbleColor.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 400)
            }
            capsule
        }
        .frame(width: 420, height: 120, alignment: .bottom)
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.phase == .listening ? GabbleColor.green : GabbleColor.idle)
                .frame(width: 8, height: 8)
                .shadow(color: GabbleColor.glow.opacity(controller.phase == .listening ? 0.8 : 0), radius: 4)
            WaveformRibbon(level: controller.level, isActive: controller.phase == .listening)
                .frame(width: 90, height: 22)
            statusText
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(GabbleColor.idle)
                .frame(minWidth: 40, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(GabbleColor.background, in: Capsule())
        .overlay(Capsule().strokeBorder(GabbleColor.green.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private var statusText: some View {
        switch controller.phase {
        case .listening:
            if let start = controller.startedAt {
                Text(start, style: .timer)
            } else {
                Text("0:00")
            }
        case .processing:
            Text("Tidying…")
        case .preparing(let message):
            Text(message).lineLimit(1)
        case .idle:
            EmptyView()
        }
    }
}
