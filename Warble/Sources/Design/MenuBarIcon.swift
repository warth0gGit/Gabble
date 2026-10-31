import AppKit

/// Draws the menu bar icon. It is always a template image, so macOS colours it
/// like every other menu bar icon (black on a light bar, white on a dark one).
///
/// - Ready: a solid, still W.
/// - Starting up or tidying text (`enabled` false): a faint, still W.
/// - Listening: the W comes alive as a moving wave.
enum MenuBarIcon {
    static let size = NSSize(width: 24, height: 18)

    static func image(time: Double, listening: Bool, enabled: Bool, level: Double) -> NSImage {
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let rect = bounds.insetBy(dx: 1.5, dy: 2)
            let strands = 4
            let amplitude = listening ? RibbonGeometry.liveAmplitude(level: level) : 1
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for k in 0..<strands {
                let f = Double(k) / Double(strands - 1)
                let core = 1 - abs(f - 0.5) * 2
                cg.addPath(RibbonGeometry.path(in: rect, strand: f, time: time, isActive: listening, amplitude: amplitude))
                let alpha: Double
                if listening {
                    alpha = 0.75 + 0.25 * core
                } else if enabled {
                    alpha = 0.6 + 0.4 * core
                } else {
                    alpha = 0.22 + 0.18 * core
                }
                cg.setStrokeColor(NSColor.black.withAlphaComponent(alpha).cgColor)
                cg.setLineWidth(core > 0.5 ? 1.5 : 1.1)
                cg.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
