import SwiftUI
import UniformTypeIdentifiers

struct GeneralView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissions: PermissionsManager
    var onShowPermissions: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Dictation shortcut on", isOn: $appState.dictationEnabled)
                Text("Hold the \(appState.dictationKey.displayName) to dictate into any app. You can also switch this on and off from the menu bar icon's right-click menu, or just click the icon to start and stop dictating.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ask \"Transcribe this call?\" when a call starts", isOn: $appState.promptForCalls)
            }
            if !permissions.allRequiredGranted {
                Section {
                    HStack {
                        Label("Warble still needs some permissions.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Set up", action: onShowPermissions)
                    }
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                Text("Everything Warble hears stays on this Mac.")
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
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var lexicon: LexiconStore
    @State private var tryText = ""
    @State private var trying = false
    @State private var comparingEngines = false

    var body: some View {
        Form {
            Section("How to dictate") {
                Toggle("Dictation shortcut on", isOn: $appState.dictationEnabled)
                Picker("Shortcut key", selection: $appState.dictationKey) {
                    ForEach(DictationKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("**Hold** the key, speak, then let go. Your words appear wherever your cursor is.", systemImage: "hand.point.down")
                    Label("**Tap** the key once to keep listening hands-free. Tap again to finish.", systemImage: "hand.tap")
                }
                .font(.callout)
                MicrophonePicker(selection: $appState.microphone)
                Toggle("Show words as I speak", isOn: $appState.liveTyping)
                Text(appState.liveTyping
                     ? "In Mac apps like Notes and Mail, words appear in the text box while you talk, then get tidied up when you finish. In the Claude app, Slack, Teams and browsers, the tidied text is typed when you finish, because those apps can't swap words reliably."
                     : "Your words appear all at once, already tidied, when you finish.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if appState.dictationKey == .fn, let action = FnKeySetting.current, action != .doNothing {
                    Label("Your Mac also uses the Fn key to \(action.description). That can pop up over your text and swallow what Warble types. In System Settings → Keyboard, set \"Press 🌐 key to\" to \"Do Nothing\".",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if appState.dictationKey == .fn, FnKeySetting.current == nil {
                    Text("Tip: if pressing Fn opens the emoji picker or Apple's own dictation, go to System Settings → Keyboard and set \"Press 🌐 key to\" to \"Do Nothing\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Try it here") {
                TextEditor(text: $tryText)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if tryText.isEmpty {
                            Text("Click Start, say something, then click Stop. Try \"um, let's meet Tuesday, no, Wednesday at ten\".")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Button(trying && dictation.isActive ? "Stop" : "Start") {
                        if trying && dictation.isActive {
                            Task { await dictation.finish() }
                        } else {
                            trying = true
                            dictation.testSink = { text in
                                tryText += (tryText.isEmpty ? "" : "\n") + text
                                trying = false
                                dictation.testSink = nil
                            }
                            Task { await dictation.start(handsFree: true) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dictation.phase == .processing)
                    Button("Clear") { tryText = "" }
                    Spacer()
                    if let error = dictation.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Section("Speech engine") {
                Picker("Model", selection: $appState.recognitionModel) {
                    ForEach(RecognitionModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(appState.recognitionModel.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if appState.recognitionModel == .parakeet {
                    ParakeetStatusRow()
                }
                Picker("Accent", selection: $appState.speechAccent) {
                    ForEach(SpeechAccent.allCases) { accent in
                        Text(accent.displayName).tag(accent)
                    }
                }
                Text("The English you speak, even if your Mac is set to a different one. Apple's engine (also used for live call transcripts) listens for this accent. Parakeet understands both without a setting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Both engines run entirely on this Mac and use your Word List to hear your jargon correctly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Compare engines on my voice…") { comparingEngines = true }
            }
            .sheet(isPresented: $comparingEngines) {
                EngineComparisonView(appState: appState, lexicon: lexicon)
            }
            .onChange(of: appState.recognitionModel, initial: true) { _, model in
                if model == .parakeet { ParakeetStatus.shared.warmUp() }
            }

            Section("Cleanup") {
                Toggle("Tidy up what I say", isOn: $appState.cleanupEnabled)
                Text("Removes filler words, applies your corrections (\"Tuesday, no, Wednesday\"), fixes punctuation, makes lists, uses your Word List and matches the app you're writing in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let reason = SmartCleanup.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Label("Using Apple Intelligence on this Mac.", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                if appState.cleanupEnabled, let outcome = dictation.lastCleanup {
                    switch outcome {
                    case .smart, .quick:
                        Label(outcome.summary, systemImage: "sparkles")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .skipped:
                        Label(outcome.summary, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                if let timing = dictation.lastTiming {
                    Label(timing.summary, systemImage: "stopwatch")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let note = dictation.lastNote {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictation")
        .onDisappear { dictation.testSink = nil }
    }
}

struct LexiconView: View {
    @EnvironmentObject private var lexicon: LexiconStore
    @State private var newTerm = ""
    @State private var newMeaning = ""
    @State private var newSoundsLike = ""
    @State private var showingImport = false
    @State private var importText = ""

    private var canAdd: Bool {
        !newTerm.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addWord() {
        guard canAdd else { return }
        let heard = newSoundsLike.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lexicon.add(term: newTerm, soundsLike: heard, meaning: newMeaning)
        newTerm = ""
        newMeaning = ""
        newSoundsLike = ""
    }

    var body: some View {
        Form {
            Section {
                Text("Warble learns your acronyms and jargon automatically: when you correct a word it typed, and from words that keep appearing in your calls. You can also add them yourself below.")
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
                        Text("Warble mishears it as (optional)")
                            .font(.subheadline.weight(.medium))
                        TextField("Misheard as", text: $newSoundsLike, prompt: Text("e.g. clawed, clod"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .onSubmit(addWord)
                        Text("Separate several with commas. Warble will always write the word instead of these. To add one to a word you already have, type the word again here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
    @EnvironmentObject private var calls: CallController
    @State private var recent: [URL] = []

    var body: some View {
        Form {
            Section {
                Toggle("Ask \"Transcribe this call?\" when a call starts", isOn: $appState.promptForCalls)
                Text("When one of the apps below starts using your microphone, Warble asks whether to transcribe. It records your voice and the other people's audio separately, transcribes both on this Mac, and saves the transcript to your Calls folder when the call ends.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                Text("Google Meet is detected when your web browser uses the microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if calls.isRecording {
                Section("Now") {
                    HStack {
                        Label("Transcribing a call", systemImage: "record.circle")
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Stop and save") { calls.stopRecording() }
                    }
                }
            }
            Section("Recent transcripts") {
                if recent.isEmpty {
                    Text("No transcripts yet.").foregroundStyle(.secondary)
                }
                ForEach(recent, id: \.self) { url in
                    HStack {
                        Text(url.deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Show Calls folder in Finder") {
                    try? FileManager.default.createDirectory(at: calls.callsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([calls.callsFolder])
                }
            }
            KnownVoicesSection(voices: calls.voices)
        }
        .formStyle(.grouped)
        .navigationTitle("Calls")
        .onAppear { recent = calls.recentTranscripts() }
        .onChange(of: calls.state) { _, _ in recent = calls.recentTranscripts() }
    }
}

/// The people Warble recognises by voice on calls.
struct KnownVoicesSection: View {
    @ObservedObject var voices: VoiceprintStore

    var body: some View {
        Section("People Warble knows by voice") {
            Text("During a call, when Warble hears someone it doesn't know, it asks \"Who is talking?\". Their voice is remembered here, on this Mac only, so next time their lines are labelled automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if voices.voices.isEmpty {
                Text("Nobody yet.").foregroundStyle(.secondary)
            }
            ForEach(voices.voices.sorted { $0.name < $1.name }) { voice in
                HStack {
                    Text(voice.name)
                    Spacer()
                    Text(voice.updated, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Forget") { voices.forget(voice) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

struct FilingView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissions: PermissionsManager
    @EnvironmentObject private var calls: CallController
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
                Text("Calls go in the Calls folder inside it, sorted into subfolders such as Calls/1-1s/Sarah Jones.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("How Warble files calls") {
                Text("When a call ends, Warble looks at which meeting it was, who was on it and when it happens. If it has filed a call like it before, it puts it in the same folder and tells you; otherwise it asks once and remembers your answer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calendar").font(.headline)
                        Text(permissions.status(.calendar) == .granted
                             ? "Warble can see your meetings' names, invitees and whether they repeat."
                             : "Optional, but it makes filing much smarter. Works with any calendar in the Calendar app, including Outlook.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if permissions.status(.calendar) == .granted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow") { permissions.request(.calendar) }
                    }
                }
            }
            FilingRulesSection(store: calls.filing)
            ObsidianSection(folderPath: appState.masterFolderPath)
        }
        .formStyle(.grouped)
        .navigationTitle("Filing")
        .onAppear { permissions.refresh() }
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
                Text("Warble needs a few permissions from macOS. Click each button, then switch Warble on in the window that opens. Come back here when you're done.")
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
                        switch permissions.status(kind) {
                        case .granted:
                            EmptyView()
                        case .needsRelaunch:
                            VStack(alignment: .trailing) {
                                Button("Reopen Warble") { relaunch() }
                                Button("Open Settings") { permissions.openSettings(for: kind) }
                                    .buttonStyle(.link)
                            }
                        case .denied:
                            Button("Open Settings") { permissions.openSettings(for: kind) }
                        case .notAsked:
                            Button("Allow") { permissions.request(kind) }
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

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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
        case .needsRelaunch:
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange).font(.title2)
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

/// Shows whether the Parakeet model has downloaded yet.
struct ParakeetStatusRow: View {
    @ObservedObject private var status = ParakeetStatus.shared

    var body: some View {
        switch status.state {
        case .unknown, .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading Parakeet from Hugging Face (first time only)…")
                    .font(.callout)
            }
        case .ready:
            Label("Parakeet is ready.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            HStack {
                Label("Parakeet couldn't download: \(message). Apple's engine is used until it does.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Try again") { status.warmUp() }
            }
        }
    }
}

/// What macOS does when the Fn (🌐) key is pressed, from System Settings → Keyboard.
enum FnKeySetting: Int {
    case doNothing = 0, changeInputSource = 1, showEmoji = 2, startDictation = 3

    /// Nil if the setting can't be read.
    static var current: FnKeySetting? {
        guard let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        else { return nil }
        return FnKeySetting(rawValue: value)
    }

    var description: String {
        switch self {
        case .doNothing: return "do nothing"
        case .changeInputSource: return "change the keyboard language"
        case .showEmoji: return "show the emoji picker"
        case .startDictation: return "start Apple's own dictation"
        }
    }
}

/// The folders Warble has learned to file calls into.
struct FilingRulesSection: View {
    @ObservedObject var store: FilingStore

    var body: some View {
        Section("Folders Warble has learned") {
            if store.rules.isEmpty {
                Text("None yet. After your first call, Warble asks where it should go.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.rules.sorted { $0.folder < $1.folder }) { rule in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(WarbleColor.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.folder)
                        Text(Self.describe(rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { store.forget(rule) }
                        .buttonStyle(.borderless)
                        .help("Warble will ask again next time instead of filing here automatically.")
                }
            }
        }
    }

    static func describe(_ rule: FilingRule) -> String {
        var parts = ["\(rule.timesUsed) call\(rule.timesUsed == 1 ? "" : "s")"]
        if !rule.seriesIDs.isEmpty { parts.append("repeating meeting") }
        if let title = rule.titles.first { parts.append("\u{201C}\(title)\u{201D}") }
        if let people = rule.peopleSets.first, !people.isEmpty {
            parts.append("with " + people.prefix(3).map { $0.capitalized }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

/// Helps set up Obsidian on the master folder.
struct ObsidianSection: View {
    var folderPath: String

    private var obsidianInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }

    var body: some View {
        Section("Obsidian") {
            Text("Obsidian is a free notes app that reads plain Markdown files, which is what Warble writes. Each transcript lists who was on the call as links like [[Sarah Jones]], so in Obsidian you can open a person and see every call with them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if obsidianInstalled {
                Text("To set it up: click **Open Obsidian**, choose **Open folder as vault**, and pick your master folder: \(folderPath)")
                    .font(.callout)
                    .textSelection(.enabled)
                Button("Open Obsidian") { openObsidian() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Obsidian isn't installed yet. Download it, open it, choose **Open folder as vault**, and pick your master folder: \(folderPath)")
                    .font(.callout)
                    .textSelection(.enabled)
                Link("Download Obsidian", destination: URL(string: "https://obsidian.md/download")!)
            }
        }
    }

    private func openObsidian() {
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: folderPath), withIntermediateDirectories: true)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Lets you pick the microphone for dictation.
struct MicrophonePicker: View {
    @Binding var selection: String
    @State private var devices: [InputDevice] = []

    var body: some View {
        Picker("Microphone", selection: $selection) {
            Text("Same as Sound settings (AirPods when they're in)").tag(MicrophoneChoice.systemDefault)
            Text("Mac's built-in microphone").tag(MicrophoneChoice.builtIn)
            ForEach(devices.filter { !$0.isBuiltIn }) { device in
                Text(device.name).tag(device.uid)
            }
        }
        .onAppear { devices = InputDevices.all() }
        Text("AirPods hear you best, but each dictation switches them into call mode for a moment, so music sounds like a phone call until you stop. The Mac's built-in microphone starts instantly and leaves your AirPods alone.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
