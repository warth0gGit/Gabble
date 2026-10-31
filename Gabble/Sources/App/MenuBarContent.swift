import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var dictation: DictationController
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

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.dictationEnabled {
                Button(dictation.isActive ? "Stop dictating" : "Start dictating") {
                    dictation.toggleHandsFree()
                }
                .buttonStyle(.borderedProminent)
                .disabled(dictation.phase == .processing)
            }

            if let error = dictation.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !permissions.allRequiredGranted {
                Label("Some permissions still need approving.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if !dictation.lastResult.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last dictation").font(.caption).foregroundStyle(.secondary)
                    Text(dictation.lastResult)
                        .font(.callout)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(dictation.lastResult, forType: .string)
                    }
                    .buttonStyle(.link)
                }
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

    private var statusText: String {
        guard appState.dictationEnabled else { return "Dictation is off." }
        switch dictation.phase {
        case .listening: return "Listening… release the key (or tap it again) to finish."
        case .processing: return "Tidying up your words…"
        case .preparing(let message): return message
        case .idle:
            return "Hold the \(appState.dictationKey.displayName) and speak. Your words go wherever your cursor is. Tap it once to keep listening hands-free."
        }
    }
}
