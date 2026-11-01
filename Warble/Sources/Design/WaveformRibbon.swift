import SwiftUI

/// The Warble waveform ribbon: several thin strands that weave around each other.
///
/// When inactive it is the still "W" from the app icon, in grey.
/// When active it becomes a moving green wave whose peaks grow with `level`,
/// the live microphone loudness from 0 to 1.
struct WaveformRibbon: View {
    var level: Double
    var isActive: Bool
    /// Fewer strands read better at small sizes.
    var strands: Int = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            Canvas { context, size in
                RibbonRenderer.draw(
                    in: &context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    level: level,
                    isActive: isActive,
                    strands: strands
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// The ribbon's shape, shared by the SwiftUI view and the menu bar icon.
enum RibbonGeometry {
    /// How tall the peaks are while listening, from the mic level.
    static func liveAmplitude(level: Double) -> Double {
        0.35 + 0.65 * min(1, max(0, level) * 3)
    }

    /// Points for one strand. `strand` runs from 0 to 1 across the ribbon.
    static func points(
        in rect: CGRect,
        strand f: Double,
        time t: Double,
        isActive: Bool,
        amplitude: Double,
        steps: Int
    ) -> [CGPoint] {
        let midY = rect.midY
        let peak = rect.height * 0.46 * amplitude
        var result: [CGPoint] = []
        result.reserveCapacity(steps + 1)
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let y: Double
            if isActive {
                // A travelling wave that keeps the W's rhythm but moves.
                let envelope = pow(sin(.pi * u), 0.6)
                let twist = 0.6 + 0.4 * cos(2 * .pi * f + t * 1.4 + u * 2.4)
                let wave = 0.70 * cos(2 * .pi * 2 * (u - 0.5) - t * 3.2)
                    + 0.30 * sin(2 * .pi * 3.6 * u + t * 4.1 + f * 1.2)
                y = -envelope * peak * twist * wave
            } else {
                // The still W: tall outer arms, a middle peak and two troughs.
                let envelope = (0.72 + 0.28 * abs(2 * u - 1)) * min(1, sin(.pi * u) * 6)
                let twist = 0.55 + 0.45 * cos(2 * .pi * f + 1.32 + u * 2.4)
                let wave = 0.80 * cos(2 * .pi * 2 * (u - 0.5) + 0.25 * sin(1.54))
                    + 0.20 * sin(2 * .pi * 4.4 * u + f * 1.4 + 2.42)
                y = -envelope * peak * twist * wave
            }
            result.append(CGPoint(x: rect.minX + u * rect.width, y: midY + y))
        }
        return result
    }

    static func path(
        in rect: CGRect,
        strand f: Double,
        time t: Double,
        isActive: Bool,
        amplitude: Double
    ) -> CGPath {
        let steps = max(24, Int(rect.width / 1.5))
        let pts = points(in: rect, strand: f, time: t, isActive: isActive, amplitude: amplitude, steps: steps)
        let path = CGMutablePath()
        path.addLines(between: pts)
        return path
    }
}

enum RibbonRenderer {
    static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        level: Double,
        isActive: Bool,
        strands: Int
    ) {
        let count = max(1, strands)
        let inset = max(1.5, size.height * 0.06)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let amplitude = isActive ? RibbonGeometry.liveAmplitude(level: level) : 1
        let small = count < 6
        let lineWidth: CGFloat = small ? 1.4 : 1.0

        context.blendMode = .plusLighter
        for k in 0..<count {
            let f = count == 1 ? 0.5 : Double(k) / Double(count - 1)
            let core = 1 - abs(f - 0.5) * 2
            let path = Path(RibbonGeometry.path(in: rect, strand: f, time: time, isActive: isActive, amplitude: amplitude))

            if isActive {
                let alpha = (small ? 0.55 : 0.2) + 0.5 * core * (small ? 0.6 : 1)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: [
                        .init(color: WarbleColor.green.opacity(alpha * 0.5), location: 0),
                        .init(color: WarbleColor.glow.opacity(min(1, alpha + 0.15)), location: 0.5),
                        .init(color: WarbleColor.green.opacity(alpha * 0.5), location: 1),
                    ]),
                    startPoint: CGPoint(x: rect.minX, y: 0),
                    endPoint: CGPoint(x: rect.maxX, y: 0)
                )
                if core > 0.7 {
                    var glow = context
                    glow.addFilter(.blur(radius: max(2, size.height * 0.08)))
                    glow.stroke(path, with: .color(WarbleColor.green.opacity(0.6)), lineWidth: lineWidth * 2.5)
                }
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            } else {
                let alpha = small ? 0.6 : 0.3 + 0.3 * core
                context.stroke(path, with: .color(WarbleColor.idle.opacity(alpha)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
