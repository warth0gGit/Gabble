import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissions: PermissionsManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(appState.dictationEnabled ? Color.accentColor : .secondary)
                Text("Gabble")
                    .font(.headline)
                Spacer()
                Toggle("Dictation", isOn: $appState.dictationEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Text(appState.dictationEnabled
                 ? "Dictation is on. Speak and your words go wherever your cursor is."
                 : "Dictation is off.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !permissions.allRequiredGranted {
                Label("Some permissions still need approving.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Divider()

            Button("Open Gabble…") {
                openWindow(id: WindowID.main)
                NSApp.activate()
            }
            Button("Quit Gabble") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { permissions.refresh() }
    }
}
