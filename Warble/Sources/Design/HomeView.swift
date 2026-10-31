import SwiftUI

/// The page Warble opens on: a welcome, how to use it, and what needs attention.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var lexicon: LexiconStore
    var onOpen: (SettingsSection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if !permissions.allRequiredGranted {
                    permissionsCard
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    card(
                        icon: "cursorarrow.click.2",
                        title: "Click to dictate",
                        text: "Click the W in the menu bar, speak, then click again. Your words are typed wherever your cursor is.",
                        action: ("Try it", .dictation)
                    )
                    card(
                        icon: "keyboard",
                        title: "Or hold \(appState.dictationKey.displayName)",
                        text: appState.dictationEnabled
                            ? "Hold the key while you talk and let go to finish. Tap it once to keep listening hands-free."
                            : "The hold-to-talk shortcut is switched off.",
                        action: ("Shortcut settings", .dictation)
                    )
                    card(
                        icon: "character.book.closed",
                        title: "Your words",
                        text: lexicon.entries.isEmpty
                            ? "Teach Warble names and jargon it should spell your way."
                            : "Warble knows \(lexicon.entries.count) of your words and learns more from your corrections.",
                        action: ("Word List", .lexicon)
                    )
                    card(
                        icon: "phone.bubble",
                        title: "Calls",
                        text: "Transcribing Teams and Zoom calls, with who said what, is coming next.",
                        action: ("Call settings", .calls)
                    )
                }
                if !dictation.lastResult.isEmpty {
                    lastDictation
                }
                Text("Everything Warble hears stays on this Mac.")
                    .font(.footnote)
                    .foregroundStyle(WarbleColor.idle)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(WarbleColor.background)
        .navigationTitle("Home")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            WaveformRibbon(level: dictation.level, isActive: true, strands: 18)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
            Text("Talk instead of type.")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Warble turns your voice into clean, finished text in any app, and soon it will transcribe and file your calls too.")
                .font(.body)
                .foregroundStyle(WarbleColor.idle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .background(
            RadialGradient(
                colors: [WarbleColor.green.opacity(0.12), WarbleColor.surface],
                center: .top, startRadius: 10, endRadius: 420
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(WarbleColor.line, lineWidth: 1))
    }

    private var permissionsCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up permissions").font(.headline)
                Text("Warble needs a few Mac permissions before it can hear you and type for you.")
                    .font(.callout)
                    .foregroundStyle(WarbleColor.idle)
            }
            Spacer()
            Button("Set up") { onOpen(.permissions) }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(WarbleColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
    }

    private var lastDictation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last dictation").font(.caption).foregroundStyle(WarbleColor.idle)
            Text(dictation.lastResult)
                .lineLimit(4)
                .textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dictation.lastResult, forType: .string)
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WarbleColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WarbleColor.line, lineWidth: 1))
    }

    private func card(icon: String, title: String, text: String, action: (String, SettingsSection)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(WarbleColor.green)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(WarbleColor.idle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action.0) { onOpen(action.1) }
                .buttonStyle(.link)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(WarbleColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WarbleColor.line, lineWidth: 1))
    }
}
