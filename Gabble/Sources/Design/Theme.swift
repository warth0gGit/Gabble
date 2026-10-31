import SwiftUI

/// Gabble's colours. Black backgrounds and one green, which only appears
/// when the app is doing something or there is something to act on.
enum GabbleColor {
    /// Night: window and pop-up backgrounds.
    static let background = Color(red: 0x0A / 255, green: 0x0C / 255, blue: 0x0B / 255)
    /// Surface: cards and grouped settings.
    static let surface = Color(red: 0x12 / 255, green: 0x16 / 255, blue: 0x14 / 255)
    /// Hairline borders between surfaces.
    static let line = Color(red: 0x26 / 255, green: 0x2D / 255, blue: 0x29 / 255)
    /// The one accent colour.
    static let green = Color(red: 0x2E / 255, green: 0xE5 / 255, blue: 0x9D / 255)
    /// The bright centre of the waveform.
    static let glow = Color(red: 0xA6 / 255, green: 0xFF / 255, blue: 0xD6 / 255)
    /// Off states and hints.
    static let idle = Color(red: 0x8B / 255, green: 0x96 / 255, blue: 0x90 / 255)
}

extension View {
    /// Applies Gabble's dark look and green accent to a window or panel.
    func gabbleTheme() -> some View {
        self
            .preferredColorScheme(.dark)
            .tint(GabbleColor.green)
    }
}
