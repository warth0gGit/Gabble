import AppKit
import SwiftUI

/// The listening ball: a small black ball with the green Warble wave inside,
/// just after your cursor while you dictate. The wave rises with your voice,
/// keeps moving gently when you pause, and an arc circles it while Warble
/// tidies your words. It follows the cursor as
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
                guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { continue }
                let spot = await Task.detached(priority: .userInitiated) { CursorLocator.current(pid: pid) }.value
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
    /// How far inside the box the ball sits when the cursor isn't known.
    nonisolated static let inset: CGFloat = 12

    /// The ball's center, in Accessibility coordinates (top-left origin), from
    /// the focused text box and the cursor. Nil when Warble can't tell where
    /// the text is: then the ball shows at the bottom of the screen.
    /// - After the cursor, on its line, when nothing follows it there and the
    ///   box has room.
    /// - Just under the cursor when it's mid-sentence or at the box's right
    ///   edge, so it never covers your words.
    /// - No usable cursor: where an empty box's cursor sits, at the start of
    ///   its first line (left inside the box), so it never looks parked at
    ///   the far end.
    nonisolated static func ballCenter(field: CGRect?, caret: CGRect?, textAfter: Bool) -> CGPoint? {
        let field = field.flatMap { $0.width >= 60 && $0.height >= 14 ? $0 : nil }
        var caret = caret.flatMap { CursorLocator.isCaret($0) ? $0 : nil }
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
            let x = field.minX + inset + reach
            return CGPoint(x: x, y: field.height < 36 ? field.midY : field.minY + inset + reach)
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

/// A small black ball with a green rim and a tiny version of the Warble wave
/// inside (Jonny's pick, option C), so it reads as Warble on dark and light
/// apps alike. Talking: the wave rises with your voice. Pausing or starting:
/// a low wave keeps moving, never a flat line. Tidying: the wave slows and a
/// green arc circles the rim. With Reduce Motion on it holds still, and
/// tidying shows as a still, dotted rim.
struct ListeningBall: View {
    var level: Double
    var phase: DictationController.Phase
    /// 1 by the cursor; bigger at the bottom of the screen.
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Quiet speech still moves the wave. Pure.
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
        let level = reduceMotion ? (talking ? 0.4 : 0) : voice
        let breathe = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 2.2)
        // Ready to listen yet? Dimmer while the microphone starts.
        let strength = phase == .listening || tidying ? 1.0 : 0.6
        let radius = 9 * scale

        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }

        // A soft glow, never more than 4 points past the ball.
        if !tidying {
            let glow = (talking ? 0.2 + 0.4 * level : 0.15 + 0.1 * breathe) * strength
            gc.fill(circle(radius + 4 * scale), with: .radialGradient(
                Gradient(colors: [WarbleColor.green.opacity(glow), WarbleColor.green.opacity(0)]),
                center: center, startRadius: radius * 0.8, endRadius: radius + 4 * scale))
        }
        // The black ball and its green rim.
        gc.fill(circle(radius), with: .color(.black))
        let rim = circle(radius - 0.65)
        if tidying {
            gc.stroke(rim, with: .color(WarbleColor.green.opacity(0.3)), lineWidth: 1.3)
        } else {
            gc.stroke(rim, with: .color(WarbleColor.green.opacity(0.85 * strength)), lineWidth: 1.3)
        }

        // The wave: three strands, highest in the middle, fading to the rim.
        let amplitude: CGFloat
        if tidying { amplitude = 1.4 * scale }
        else if talking { amplitude = (1.8 + 4 * level) * scale }
        else { amplitude = 1.6 * scale * (0.85 + 0.3 * breathe) }
        let speed: Double = reduceMotion ? 0 : (tidying ? 1.5 : 6)
        var inner = gc
        inner.clip(to: circle(radius - 1.8 * scale))
        for strand in 0..<3 {
            var wave = Path()
            var x = -radius
            while x <= radius {
                let envelope = CGFloat(cos(Double(x / radius) * .pi / 2))
                let swing = CGFloat(sin(Double(x / (1.9 * scale)) + t * speed + Double(strand) * 0.7))
                let y = swing * amplitude * envelope * (1 - CGFloat(strand) * 0.15)
                let point = CGPoint(x: center.x + x, y: center.y + y)
                if x == -radius { wave.move(to: point) } else { wave.addLine(to: point) }
                x += 0.5
            }
            let opacity = (tidying ? 0.55 : 1) * (1 - Double(strand) * 0.25) * strength
            inner.stroke(wave, with: .color((strand == 0 ? WarbleColor.glow : WarbleColor.green).opacity(opacity)),
                         lineWidth: strand == 0 ? 1.3 : 0.9)
        }

        // Tidying: an arc circles the rim.
        if tidying {
            var arc = Path()
            if reduceMotion {
                arc.addArc(center: center, radius: radius - 0.65, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            } else {
                let start = Angle.radians(t * 5)
                arc.addArc(center: center, radius: radius - 0.65, startAngle: start,
                           endAngle: start + .radians(.pi * 1.2), clockwise: false)
            }
            gc.stroke(arc, with: .color(WarbleColor.green),
                      style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: reduceMotion ? [1.5, 2.5] : []))
        }
    }
}
