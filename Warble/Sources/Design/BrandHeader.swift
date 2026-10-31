import SwiftUI

/// The fixed band at the top of the Warble window: icon, name and a live status pill.
struct BrandHeader: View {
    @EnvironmentObject private var dictation: DictationController

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            Text("Warble")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            statusPill
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(WarbleColor.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WarbleColor.line).frame(height: 1)
        }
    }

    private var statusPill: some View {
        let listening = dictation.phase == .listening
        return HStack(spacing: 8) {
            WaveformRibbon(level: dictation.level, isActive: listening, strands: 4)
                .frame(width: 30, height: 16)
            Text(listening ? "Listening" : "Ready")
                .font(.callout.weight(.medium))
                .foregroundStyle(listening ? WarbleColor.green : WarbleColor.idle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(WarbleColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(listening ? WarbleColor.green.opacity(0.4) : WarbleColor.line, lineWidth: 1))
    }
}
