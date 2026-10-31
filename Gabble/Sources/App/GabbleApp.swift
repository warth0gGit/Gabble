import SwiftUI

@main
struct GabbleApp: App {
    @StateObject private var appState: AppState
    @StateObject private var permissions = PermissionsManager()
    @StateObject private var lexicon: LexiconStore
    @StateObject private var dictation: DictationController

    init() {
        let appState = AppState()
        let lexicon = LexiconStore()
        _appState = StateObject(wrappedValue: appState)
        _lexicon = StateObject(wrappedValue: lexicon)
        _dictation = StateObject(wrappedValue: DictationController(appState: appState, lexicon: lexicon))
    }

    var body: some Scene {
        // The full app window, opened from the Dock.
        Window("Gabble", id: WindowID.main) {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(permissions)
                .environmentObject(lexicon)
                .environmentObject(dictation)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 880, height: 600)

        // The quick toggle that lives in the menu bar.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
                .environmentObject(permissions)
                .environmentObject(dictation)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel(dictation.isActive ? "Gabble is listening" : "Gabble")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if dictation.isActive { return "waveform.circle.fill" }
        return appState.dictationEnabled ? "waveform" : "waveform.slash"
    }
}

enum WindowID {
    static let main = "main"
}
