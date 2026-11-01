import AppKit

/// Draws the menu bar icon: a black rounded square with a white W inside.
///
/// - Ready: a still white W.
/// - Starting up or tidying text (`enabled` false): a faint, still W.
/// - Active (dictating or transcribing a call): the W turns green and moves as a wave.
enum MenuBarIcon {
    static let size = NSSize(width: 20, height: 18)
    private static let green = NSColor(red: 0x2E / 255, green: 0xE5 / 255, blue: 0x9D / 255, alpha: 1)

    static func image(time: Double, listening: Bool, enabled: Bool, level: Double) -> NSImage {
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let side = min(bounds.width, bounds.height) - 1
            let square = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            let tile = CGPath(roundedRect: square, cornerWidth: 4, cornerHeight: 4, transform: nil)
            cg.addPath(tile)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath()
            // A faint edge so the tile still reads on a dark menu bar.
            cg.addPath(tile)
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
            cg.setLineWidth(0.75)
            cg.strokePath()

            let rect = square.insetBy(dx: 3, dy: 4)
            let strands = 3
            let amplitude = listening ? RibbonGeometry.liveAmplitude(level: level) : 1
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for k in 0..<strands {
                let f = Double(k) / Double(strands - 1)
                let core = 1 - abs(f - 0.5) * 2
                cg.addPath(RibbonGeometry.path(in: rect, strand: f, time: time, isActive: listening, amplitude: amplitude))
                let colour: NSColor
                if listening {
                    colour = green.withAlphaComponent(0.7 + 0.3 * core)
                } else if enabled {
                    colour = NSColor.white.withAlphaComponent(0.75 + 0.25 * core)
                } else {
                    colour = NSColor.white.withAlphaComponent(0.3 + 0.15 * core)
                }
                cg.setStrokeColor(colour.cgColor)
                cg.setLineWidth(core > 0.5 ? 1.4 : 1.0)
                cg.strokePath()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
