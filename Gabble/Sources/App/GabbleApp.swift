import SwiftUI

@main
struct GabbleApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var permissions = PermissionsManager()
    @StateObject private var lexicon = LexiconStore()

    var body: some Scene {
        // The full app window, opened from the Dock.
        Window("Gabble", id: WindowID.main) {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(permissions)
                .environmentObject(lexicon)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 880, height: 600)

        // The quick toggle that lives in the menu bar.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
                .environmentObject(permissions)
        } label: {
            Image(systemName: appState.dictationEnabled ? "waveform.circle.fill" : "waveform.circle")
                .accessibilityLabel(appState.dictationEnabled ? "Gabble dictation on" : "Gabble dictation off")
        }
        .menuBarExtraStyle(.window)
    }
}

enum WindowID {
    static let main = "main"
}
