import AppKit
import SwiftUI

/// The listening ball at the bottom of the screen, used when Warble can't tell
/// where your text box is (or the ball by the cursor is switched off).
/// Words go straight into your app (as Wispr Flow does), not into the ball.
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
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if case .preparing(let message) = controller.phase {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WarbleColor.idle)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(WarbleColor.background.opacity(0.94), in: Capsule())
            }
            // The same listening ball as by the cursor, a little bigger.
            ListeningBall(level: controller.level, phase: controller.phase, scale: 1.6)
                .frame(width: 44, height: 44)
        }
        .frame(width: 420, height: 120, alignment: .bottom)
        .environment(\.colorScheme, .dark)
    }
}
