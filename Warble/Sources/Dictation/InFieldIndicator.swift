import AppKit
import SwiftUI

/// The listening ball: a small green ball just after your cursor while you
/// dictate. It swells with your voice, breathes when you pause, and a thin
/// ring circles it while Warble tidies your words. It follows the cursor as
/// words are typed in. When Warble can't tell where the text box is, a bigger
/// ball shows at the bottom of the screen instead (DictationHUD). It never
/// takes focus or clicks, so typing still reaches your app.
@MainActor
final class InFieldIndicator {
    private let panel: NSPanel
    private var followTask: Task<Void, Never>?

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.ballBox, height: Self.ballBox),
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

    /// Shows the ball centered on `center` (Cocoa screen coordinates). If it's
    /// already showing, it stays where following the cursor has put it.
    func show(at center: CGPoint) {
        if !panel.isVisible { move(to: center) }
        panel.orderFrontRegardless()
        follow()
    }

    func hide() {
        followTask?.cancel()
        followTask = nil
        panel.orderOut(nil)
    }

    private func move(to center: CGPoint) {
        panel.setFrame(NSRect(x: center.x - Self.ballBox / 2, y: center.y - Self.ballBox / 2,
                              width: Self.ballBox, height: Self.ballBox), display: true)
    }

    /// Checks where the cursor is four times a second, in the background, and
    /// moves the ball with it. A check that fails or times out keeps the ball
    /// where it was.
    private func follow() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let spot = await Task.detached(priority: .userInitiated) { CursorLocator.current() }.value
                guard let self else { return }
                guard !Task.isCancelled, self.panel.isVisible,
                      let spot, let center = InFieldIndicator.cocoaCenter(for: spot) else { continue }
                if hypot(center.x - self.panel.frame.midX, center.y - self.panel.frame.midY) >= 1 {
                    self.move(to: center)
                }
            }
        }
    }

    /// Where the ball goes for `spot`, in Cocoa screen coordinates.
    static func cocoaCenter(for spot: CursorSpot) -> CGPoint? {
        guard let center = ballCenter(field: spot.field, caret: spot.caret, textAfter: spot.textAfter),
              let primary = NSScreen.screens.first else { return nil }
        return cocoaPoint(fromAccessibility: center, primaryScreenHeight: primary.frame.height)
    }

    // MARK: - Where to draw (pure, unit tested)

    /// The panel's size: room for the ball at its biggest plus its glow.
    nonisolated static let ballBox: CGFloat = 28
    /// Space between the cursor and the ball.
    nonisolated static let gap: CGFloat = 6
    /// The ball's largest radius (swelling, its dark edge or the tidying ring),
    /// so even at its biggest it never grows into your text.
    nonisolated static let reach: CGFloat = 9.5

    /// The ball's center, in Accessibility coordinates (top-left origin), from
    /// the focused text box and the cursor. Nil when Warble can't tell where
    /// the text is: then the ball shows at the bottom of the screen.
    /// - After the cursor, on its line, when nothing follows it there and the
    ///   box has room.
    /// - Just under the cursor when it's mid-sentence or at the box's right
    ///   edge, so it never covers your words.
    /// - No usable cursor: top right inside the box, or just outside its right
    ///   edge when the box is a thin single line.
    nonisolated static func ballCenter(field: CGRect?, caret: CGRect?, textAfter: Bool) -> CGPoint? {
        let field = field.flatMap { $0.width >= 60 && $0.height >= 14 ? $0 : nil }
        var caret = caret.flatMap { $0.height >= 4 && $0.height < 200 ? $0 : nil }
        // Some web apps report a cursor at the top-left of the screen: ignore one outside the box.
        if let box = field, let spot = caret, !box.insetBy(dx: -24, dy: -24).contains(CGPoint(x: spot.maxX, y: spot.midY)) {
            caret = nil
        }
        if let caret {
            let beside = caret.maxX + gap + reach
            let roomy = field.map { beside + reach <= $0.maxX } ?? true
            if roomy && !textAfter { return CGPoint(x: beside, y: caret.midY) }
            return CGPoint(x: caret.maxX, y: caret.maxY + 2 + reach)
        }
        if let field {
            if field.height < 36 { return CGPoint(x: field.maxX + gap + reach, y: field.midY) }
            return CGPoint(x: field.maxX - 12 - reach, y: field.minY + 12 + reach)
        }
        return nil
    }

    /// Accessibility positions are measured from the top of the main display;
    /// windows are placed from the bottom.
    nonisolated static func cocoaPoint(fromAccessibility point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}

/// The ball by the cursor.
struct InFieldIndicatorView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        ListeningBall(level: controller.level, phase: controller.phase)
            .frame(width: InFieldIndicator.ballBox, height: InFieldIndicator.ballBox)
    }
}

/// A green ball with a thin dark edge (so it shows on white apps as well as
/// dark ones). Talking: it swells with your voice. Pausing or starting: it
/// breathes slowly. Tidying: a thin green ring circles it. With Reduce
/// Motion on it holds still, and tidying shows as a still, dotted ring.
struct ListeningBall: View {
    var level: Double
    var phase: DictationController.Phase
    /// 1 by the cursor; bigger at the bottom of the screen.
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Quiet speech still moves the ball. Pure.
    nonisolated static func boosted(_ level: Double) -> Double {
        min(1, max(0, level).squareRoot() * 1.4)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || phase == .idle)) { context in
            Canvas { gc, size in
                draw(in: &gc, size: size, t: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let tidying = phase == .processing
        let voice = Self.boosted(level)
        let talking = phase == .listening && voice > 0.08
        let breathe = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2.2)
        let level = reduceMotion ? 0.4 : voice
        let base = 6 * scale
        let radius: CGFloat
        if tidying { radius = base * 0.85 }
        else if talking { radius = base * (0.9 + 0.3 * level) }
        else { radius = base * (0.85 + 0.12 * breathe) }
        // Ready to listen yet? A dimmer ball while the microphone starts.
        let strength = phase == .listening ? 1.0 : 0.6

        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }

        // A soft glow, never more than 4 points past the ball.
        if !tidying {
            let glow = talking ? 0.35 + 0.4 * level : 0.3 * breathe
            gc.fill(circle(radius + 4 * scale), with: .radialGradient(
                Gradient(colors: [WarbleColor.green.opacity(glow * strength), WarbleColor.green.opacity(0)]),
                center: center, startRadius: radius, endRadius: radius + 4 * scale))
        }
        // The dark edge.
        gc.fill(circle(radius + 1), with: .color(WarbleColor.background.opacity(0.85)))
        // The ball, lit from the top left.
        let fill = tidying ? 0.6 : (talking ? 1 : 0.75 + 0.25 * breathe) * strength
        gc.fill(circle(radius), with: .radialGradient(
            Gradient(colors: [WarbleColor.glow.opacity(fill), WarbleColor.green.opacity(fill)]),
            center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3),
            startRadius: 0, endRadius: radius))
        // Tidying: a ring circles the ball.
        if tidying {
            let ringRadius = radius + 3.5 * scale
            var ring = Path()
            if reduceMotion {
                ring.addArc(center: center, radius: ringRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            } else {
                let start = Angle.radians(t * 5)
                ring.addArc(center: center, radius: ringRadius, startAngle: start,
                            endAngle: start + .radians(.pi * 1.2), clockwise: false)
            }
            gc.stroke(ring, with: .color(WarbleColor.green.opacity(0.95)),
                      style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: reduceMotion ? [1.5, 2.5] : []))
        }
    }
}
