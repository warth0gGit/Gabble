import AppKit
import SwiftUI

/// The menu bar icon. A still W that matches the other menu bar icons when idle,
/// and a moving green wave while listening.
///
/// Menu bar labels only show images, so each frame is drawn into an NSImage.
struct MenuBarIcon: View {
    var isActive: Bool
    var enabled: Bool
    var level: Double

    @StateObject private var animator = MenuBarIconAnimator()

    var body: some View {
        Image(nsImage: MenuBarIcon.image(time: animator.time, isActive: isActive, enabled: enabled, level: level))
            .onAppear { animator.setRunning(isActive) }
            .onChange(of: isActive) { _, active in animator.setRunning(active) }
            .accessibilityLabel(isActive ? "Listening" : (enabled ? "Dictation ready" : "Dictation off"))
    }

    static let size = NSSize(width: 24, height: 18)

    static func image(time: Double, isActive: Bool, enabled: Bool, level: Double) -> NSImage {
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let rect = bounds.insetBy(dx: 1.5, dy: 2)
            let strands = 4
            let amplitude = isActive ? RibbonGeometry.liveAmplitude(level: level) : 1
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for k in 0..<strands {
                let f = Double(k) / Double(strands - 1)
                let core = 1 - abs(f - 0.5) * 2
                cg.addPath(RibbonGeometry.path(in: rect, strand: f, time: time, isActive: isActive, amplitude: amplitude))
                if isActive {
                    let colour = NSColor(GabbleColor.green).withAlphaComponent(0.6 + 0.4 * core)
                    cg.setStrokeColor(colour.cgColor)
                    cg.setLineWidth(core > 0.5 ? 1.5 : 1.1)
                } else {
                    // Template images take the menu bar's own colour; alpha sets how strong it looks.
                    let alpha = enabled ? 0.55 + 0.45 * core : 0.25 + 0.2 * core
                    cg.setStrokeColor(NSColor.black.withAlphaComponent(alpha).cgColor)
                    cg.setLineWidth(core > 0.5 ? 1.4 : 1.0)
                }
                cg.strokePath()
            }
            return true
        }
        image.isTemplate = !isActive
        return image
    }
}

/// Drives the menu bar animation only while listening.
@MainActor
final class MenuBarIconAnimator: ObservableObject {
    @Published private(set) var time: Double = 0
    private var timer: Timer?

    func setRunning(_ running: Bool) {
        if running {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.time = Date().timeIntervalSinceReferenceDate
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}
