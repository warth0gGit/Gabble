import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var dictation: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WaveformRibbon(level: dictation.level, isActive: dictation.isActive, strands: 5)
                    .frame(width: 36, height: 24)
                    .opacity(appState.dictationEnabled ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gabble")
                        .font(.headline)
                    Text(headline)
                        .font(.caption)
                        .foregroundStyle(dictation.isActive ? GabbleColor.green : GabbleColor.idle)
                }
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
                .foregroundStyle(GabbleColor.background)
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
        .background(GabbleColor.background.opacity(0.6))
        .onAppear { permissions.refresh() }
    }

    private var headline: String {
        if dictation.isActive { return "Listening" }
        return appState.dictationEnabled ? "Ready" : "Dictation is off"
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
