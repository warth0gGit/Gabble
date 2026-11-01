import AppKit
import SwiftUI

/// The small floating capsule at the bottom of the screen while dictating:
/// shows the mic is on, how loud you are and how long you've been talking.
/// Words go straight into your app (as Wispr Flow does), not into the capsule.
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
            capsule
        }
        .frame(width: 420, height: 120, alignment: .bottom)
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.phase == .listening ? WarbleColor.green : WarbleColor.idle)
                .frame(width: 8, height: 8)
                .shadow(color: WarbleColor.glow.opacity(controller.phase == .listening ? 0.8 : 0), radius: 4)
            WaveformRibbon(level: controller.level, isActive: controller.phase == .listening, strands: 8)
                .frame(width: 120, height: 26)
            statusText
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(WarbleColor.idle)
                .frame(minWidth: 40, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(WarbleColor.background.opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(WarbleColor.green.opacity(controller.phase == .listening ? 0.3 : 0.15), lineWidth: 1))
        .shadow(color: WarbleColor.green.opacity(controller.phase == .listening ? 0.22 : 0), radius: 14)
        .environment(\.colorScheme, .dark)
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
