import SwiftUI

/// Placeholder brand colours from the design mock-up. The design thread owns
/// this folder and will replace these with the final theme.
enum GabbleColor {
    static let background = Color(red: 0x0A / 255, green: 0x0C / 255, blue: 0x0B / 255)
    static let surface = Color(red: 0x12 / 255, green: 0x16 / 255, blue: 0x14 / 255)
    static let green = Color(red: 0x2E / 255, green: 0xE5 / 255, blue: 0x9D / 255)
    static let glow = Color(red: 0xA6 / 255, green: 0xFF / 255, blue: 0xD6 / 255)
    static let idle = Color(red: 0x8B / 255, green: 0x96 / 255, blue: 0x90 / 255)
}

/// Placeholder for the glowing waveform ribbon. Keep this signature:
/// `level` is the live microphone loudness from 0 to 1.
struct WaveformRibbon: View {
    var level: Double
    var isActive: Bool

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let strands = 4
                let amplitude = isActive ? max(0.12, min(1, level * 3)) : 0.06
                for strand in 0..<strands {
                    var path = Path()
                    let phase = Double(strand) * 0.7 + t * 2.4
                    let steps = 48
                    for step in 0...steps {
                        let x = Double(step) / Double(steps)
                        let envelope = sin(.pi * x)
                        let y = 0.5 + sin(x * 9 + phase) * 0.38 * amplitude * envelope
                        let point = CGPoint(x: x * size.width, y: y * size.height)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    let colour = isActive ? GabbleColor.green : GabbleColor.idle
                    context.stroke(path, with: .color(colour.opacity(1 - Double(strand) * 0.2)), lineWidth: 1.6)
                }
            }
        }
        .shadow(color: isActive ? GabbleColor.glow.opacity(0.6) : .clear, radius: 4)
        .accessibilityHidden(true)
    }
}
