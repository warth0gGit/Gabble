import SwiftUI

@main
struct WarbleApp: App {
    @StateObject private var appState: AppState
    @StateObject private var permissions: PermissionsManager
    @StateObject private var lexicon: LexiconStore
    @StateObject private var dictation: DictationController

    init() {
        let appState = AppState()
        let lexicon = LexiconStore()
        let permissions = PermissionsManager()
        let dictation = DictationController(appState: appState, lexicon: lexicon)
        _appState = StateObject(wrappedValue: appState)
        _lexicon = StateObject(wrappedValue: lexicon)
        _permissions = StateObject(wrappedValue: permissions)
        _dictation = StateObject(wrappedValue: dictation)

        // The menu bar icon: click to turn dictation on or off, right-click for a menu.
        Task { @MainActor in
            StatusItemController.shared.install(appState: appState, dictation: dictation, permissions: permissions)
        }
    }

    var body: some Scene {
        // The full app window, opened from the Dock.
        Window("Warble", id: WindowID.main) {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(permissions)
                .environmentObject(lexicon)
                .environmentObject(dictation)
                .frame(minWidth: 760, minHeight: 520)
                .warbleTheme()
                .containerBackground(WarbleColor.background, for: .window)
                .background(OpenWindowCapture())
        }
        .defaultSize(width: 880, height: 600)
    }
}

enum WindowID {
    static let main = "main"
}
