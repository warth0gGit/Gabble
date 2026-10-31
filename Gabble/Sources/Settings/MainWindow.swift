import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, dictation, lexicon, calls, filing, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .lexicon: return "Word List"
        case .calls: return "Calls"
        case .filing: return "Filing"
        case .permissions: return "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .lexicon: return "character.book.closed"
        case .calls: return "phone.bubble"
        case .filing: return "folder"
        case .permissions: return "lock.shield"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject private var permissions: PermissionsManager
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(section == .permissions && !permissions.allRequiredGranted ? Text("!") : nil)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .general {
            case .general: GeneralView(onShowPermissions: { selection = .permissions })
            case .dictation: DictationView()
            case .lexicon: LexiconView()
            case .calls: CallsView()
            case .filing: FilingView()
            case .permissions: PermissionsView()
            }
        }
        .onAppear {
            permissions.refresh()
            if !permissions.allRequiredGranted { selection = .permissions }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}
