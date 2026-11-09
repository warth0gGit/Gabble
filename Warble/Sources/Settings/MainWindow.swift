import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case home, transcripts, people, general, dictation, lexicon, calls, filing, permissions

    var id: String { rawValue }

    /// Home, Transcripts and People sit above the settings pages.
    static let main: [SettingsSection] = [.home, .transcripts, .people]
    static let settings: [SettingsSection] = allCases.filter { !SettingsSection.main.contains($0) }

    var title: String {
        switch self {
        case .home: return "Home"
        case .transcripts: return "Transcripts"
        case .people: return "People"
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
        case .home: return "house"
        case .transcripts: return "doc.text"
        case .people: return "person.2"
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
    /// "Version 1.0 (build 39)", from the app's own Info.plist.
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (build \(build))"
    }

    @EnvironmentObject private var permissions: PermissionsManager
    @State private var selection: SettingsSection? = .home
    /// What the Transcripts tab is searching for (People's "Show all their calls" sets it).
    @State private var transcriptQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()
            splitView
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSection.main) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
                Section("Settings") {
                    ForEach(SettingsSection.settings) { section in
                        Label(section.title, systemImage: section.icon)
                            .badge(section == .permissions && !permissions.allRequiredGranted ? Text("!") : nil)
                            .tag(section)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(Self.versionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .home {
            case .home: HomeView(onOpen: { selection = $0 })
            case .transcripts: TranscriptsView(query: $transcriptQuery)
            case .people:
                PeopleView(onShowCalls: { name in
                    transcriptQuery = name
                    selection = .transcripts
                })
            case .general: GeneralView(onShowPermissions: { selection = .permissions })
            case .dictation: DictationView()
            case .lexicon: LexiconView()
            case .calls: CallsView(onShowTranscripts: { selection = .transcripts })
            case .filing: FilingView()
            case .permissions: PermissionsView()
            }
        }
    }
}
