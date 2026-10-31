import SwiftUI
import UniformTypeIdentifiers

struct GeneralView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissions: PermissionsManager
    var onShowPermissions: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Dictation", isOn: $appState.dictationEnabled)
                Text("You can also switch dictation on and off from the waveform icon in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ask \"Transcribe this call?\" when a call starts", isOn: $appState.promptForCalls)
            }
            if !permissions.allRequiredGranted {
                Section {
                    HStack {
                        Label("Gabble still needs some permissions.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Set up", action: onShowPermissions)
                    }
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                Text("Everything Gabble hears stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

struct DictationView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Speech engine") {
                Picker("Model", selection: $appState.recognitionModel) {
                    ForEach(RecognitionModel.allCases) { model in
                        Text(model.displayName + (model.isAvailable ? "" : " (coming soon)"))
                            .tag(model)
                            .selectionDisabled(!model.isAvailable)
                    }
                }
                Text("All models run on this Mac. Hugging Face models will be downloadable here later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Cleanup") {
                Toggle("Tidy up what I say", isOn: $appState.cleanupEnabled)
                Text("Removes filler words, applies your corrections (\"Tuesday, no, Wednesday\"), adds punctuation and uses your Word List.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictation")
    }
}

struct LexiconView: View {
    @EnvironmentObject private var lexicon: LexiconStore
    @State private var newTerm = ""
    @State private var newMeaning = ""
    @State private var showingImport = false
    @State private var importText = ""

    private var canAdd: Bool {
        !newTerm.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addWord() {
        guard canAdd else { return }
        lexicon.add(term: newTerm, meaning: newMeaning)
        newTerm = ""
        newMeaning = ""
    }

    var body: some View {
        Form {
            Section {
                Text("Gabble learns your acronyms and jargon automatically: when you correct a word it typed, and from words that keep appearing in your calls. You can also add them yourself below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Add a word") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Word or acronym")
                            .font(.subheadline.weight(.medium))
                        TextField("Word or acronym", text: $newTerm, prompt: Text("e.g. SaaS"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onSubmit(addWord)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What it means (optional)")
                            .font(.subheadline.weight(.medium))
                        TextField("What it means", text: $newMeaning, prompt: Text("e.g. Software as a Service"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onSubmit(addWord)
                    }
                    HStack {
                        Button("Paste a list…") { showingImport = true }
                        Spacer()
                        Button("Add word", action: addWord)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canAdd)
                    }
                }
                .padding(.vertical, 4)
            }

            if !lexicon.suggested.isEmpty {
                Section("Suggested (\(lexicon.suggested.count))") {
                    ForEach(lexicon.suggested) { entry in
                        HStack {
                            Text(entry.term).bold()
                            Text("seen \(entry.timesSeen)×").foregroundStyle(.secondary)
                            Spacer()
                            Button("Add") { lexicon.approve(entry) }
                            Button("Dismiss", role: .destructive) { lexicon.remove(entry) }
                        }
                    }
                }
            }

            Section("Your words (\(lexicon.confirmed.count))") {
                if lexicon.confirmed.isEmpty {
                    Text("No words yet.").foregroundStyle(.secondary)
                }
                ForEach(lexicon.confirmed) { entry in
                    HStack {
                        Text(entry.term).bold()
                        if !entry.meaning.isEmpty {
                            Text(entry.meaning).foregroundStyle(.secondary)
                        }
                        if !entry.soundsLike.isEmpty {
                            Text("heard as: " + entry.soundsLike.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            lexicon.remove(entry)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Word List")
        .sheet(isPresented: $showingImport) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste your terms").font(.headline)
                Text("One per line. Add a meaning after a dash, e.g. \"KPI - key performance indicator\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $importText)
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
                HStack {
                    Spacer()
                    Button("Cancel") { showingImport = false; importText = "" }
                    Button("Import") {
                        lexicon.importList(importText)
                        importText = ""
                        showingImport = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 480)
        }
    }
}

struct CallsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Ask \"Transcribe this call?\" when a call starts", isOn: $appState.promptForCalls)
            }
            Section("Watch these apps for calls") {
                ForEach(AppState.defaultCallApps, id: \.self) { app in
                    Toggle(app, isOn: Binding(
                        get: { appState.callApps.contains(app) },
                        set: { on in
                            if on { appState.callApps.append(app) } else { appState.callApps.removeAll { $0 == app } }
                        }
                    ))
                }
            }
            Section {
                Text("Call detection, recording and speaker recognition are coming in the next update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calls")
    }
}

struct FilingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section("Master folder") {
                LabeledContent("Transcripts are saved in") {
                    Text(appState.masterFolderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…") { choosingFolder = true }
                    Button("Show in Finder") {
                        let url = URL(fileURLWithPath: appState.masterFolderPath)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Text("Tip: once you set up Obsidian, pick a folder inside your vault so every transcript shows up there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Filing")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                appState.masterFolderPath = url.path
            }
        }
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var permissions: PermissionsManager

    var body: some View {
        Form {
            Section {
                Text("Gabble needs a few permissions from macOS. Click each button, then switch Gabble on in the window that opens. Come back here when you're done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(PermissionsManager.Kind.allCases) { kind in
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        statusIcon(permissions.status(kind))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title).font(.headline)
                            Text(kind.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(permissions.status(kind).label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if permissions.status(kind) != .granted {
                            Button(permissions.status(kind) == .denied ? "Open Settings" : "Allow") {
                                if permissions.status(kind) == .denied {
                                    permissions.openSettings(for: kind)
                                } else {
                                    permissions.request(kind)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button("Check again") { permissions.refresh() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
    }

    @ViewBuilder
    private func statusIcon(_ status: PermissionsManager.Status) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title2)
        case .notAsked:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary).font(.title2)
        }
    }
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
