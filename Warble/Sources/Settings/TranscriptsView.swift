import AppKit
import SwiftUI

/// Every saved call: folders down the left, calls by day on the right, each
/// showing where it was filed, who spoke and the summary's headline. Search
/// covers names, people, folders, summaries and every word said.
struct TranscriptsView: View {
    @EnvironmentObject private var calls: CallController
    @Binding var query: String

    var body: some View {
        TranscriptsBrowser(library: calls.library, query: $query)
    }
}

enum TranscriptFilter: Hashable {
    case all, needsLook, unfiled
    case folder(String)
}

private struct TranscriptsBrowser: View {
    @EnvironmentObject private var calls: CallController
    @ObservedObject var library: CallLibrary
    @Binding var query: String
    @State private var filter: TranscriptFilter? = .all
    @State private var when: When = .any
    @State private var expanded: URL?
    @State private var sharing: ShareTarget?
    @State private var checking = false
    @State private var problem: String?

    enum When: String, CaseIterable, Identifiable {
        case any = "Any time", week = "Past week", month = "Past month"
        var id: String { rawValue }
    }

    private struct ShareTarget: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
            Divider()
            VStack(spacing: 0) {
                toolbar
                if calls.isRecording { recordingBanner }
                list
            }
            .frame(maxWidth: .infinity)
        }
        .background(WarbleColor.background)
        .navigationTitle("Transcripts")
        .sheet(item: $sharing) { target in ShareCallSheet(note: target.url) }
        .sheet(isPresented: $checking) { speakerSheet }
        .alert("Couldn't move the call", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
        .onAppear { refresh() }
        .onChange(of: calls.state) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() { library.refresh(callsFolder: calls.callsFolder) }

    // MARK: Folders

    private var sidebar: some View {
        let entries = library.entries
        return List(selection: $filter) {
            row("All calls", "tray.full", entries.count).tag(TranscriptFilter.all)
            row("Needs a look", "exclamationmark.triangle", entries.filter { needsLook($0) }.count, warn: true)
                .tag(TranscriptFilter.needsLook)
            Section("Folders") {
                ForEach(CallLibraryLogic.folderTree(entries)) { node in
                    row(node.name, "folder", node.count)
                        .padding(.leading, CGFloat(node.depth) * 14)
                        .tag(TranscriptFilter.folder(node.path))
                }
                let unfiled = entries.filter(\.isUnfiled).count
                if unfiled > 0 {
                    row(CallLibraryLogic.unfiledFolder, "folder.badge.questionmark", unfiled).tag(TranscriptFilter.unfiled)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(WarbleColor.background)
    }

    private func row(_ title: String, _ icon: String, _ count: Int, warn: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: icon).lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(warn && count > 0 ? CallPanelColor.amber : WarbleColor.idle)
        }
    }

    // MARK: Search and filters

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SearchField(text: $query, prompt: "Search calls, people, folders and what was said")
                Button {
                    try? FileManager.default.createDirectory(at: calls.callsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([calls.callsFolder])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show the Calls folder in Finder")
            }
            Picker("When", selection: $when) {
                ForEach(When.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var recordingBanner: some View {
        HStack {
            Label("Transcribing a call", systemImage: "record.circle").foregroundStyle(.red)
            Spacer()
            Button("Stop and save") { calls.stopRecording() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(WarbleColor.surface))
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    // MARK: Calls

    private struct Shown {
        var entry: CallEntry
        var said: String?
    }

    private var shown: [Shown] {
        let now = Date()
        return library.entries.compactMap { (entry: CallEntry) -> Shown? in
            switch filter ?? .all {
            case .all: break
            case .needsLook: if !needsLook(entry) { return nil }
            case .unfiled: if !entry.isUnfiled { return nil }
            case .folder(let path): if !CallLibraryLogic.isIn(entry, folder: path) { return nil }
            }
            switch when {
            case .any: break
            case .week: if now.timeIntervalSince(entry.started) > 7 * 86_400 { return nil }
            case .month: if now.timeIntervalSince(entry.started) > 31 * 86_400 { return nil }
            }
            let hit = CallLibraryLogic.match(entry, query: query)
            return hit.matches ? Shown(entry: entry, said: hit.said) : nil
        }
    }

    private var list: some View {
        let shown = self.shown
        let said = Dictionary(shown.compactMap { item in item.said.map { (item.entry.url, $0) } }, uniquingKeysWith: { a, _ in a })
        let groups = CallLibraryLogic.byDay(shown.map { $0.entry })
        let folders = CallLibraryLogic.folderTree(library.entries).map { $0.path }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                if groups.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(WarbleColor.idle)
                        .padding(.vertical, 30)
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.calls) { entry in
                            CallRow(
                                entry: entry,
                                said: said[entry.url],
                                query: query,
                                expanded: expanded == entry.url,
                                toCheck: toCheck(entry),
                                folders: folders,
                                onToggle: { withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == entry.url ? nil : entry.url } },
                                onShare: { sharing = ShareTarget(url: entry.url) },
                                onSpeakers: { calls.reopenCheck(); checking = true },
                                onMove: { move(entry, to: $0) }
                            )
                        }
                    } header: {
                        Text(group.day.uppercased())
                            .font(.caption.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(WarbleColor.idle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .background(WarbleColor.background)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }

    private var emptyText: String {
        if !library.loaded { return "Reading your calls…" }
        if library.entries.isEmpty { return "No transcripts yet. When a call ends, it shows up here." }
        return "No calls match. Try another word, or pick All calls."
    }

    /// Speakers still to check, for the last call only (that's the one you can fix).
    private func toCheck(_ entry: CallEntry) -> Int? {
        guard let check = calls.speakerCheck, !calls.isRecording, check.toCheck > 0,
              check.url.lastPathComponent == entry.url.lastPathComponent else { return nil }
        return check.toCheck
    }

    private func needsLook(_ entry: CallEntry) -> Bool {
        toCheck(entry) != nil || CallLibraryLogic.needsLook(entry)
    }

    private func move(_ entry: CallEntry, to folder: String) {
        do {
            try library.move(entry, to: folder, callsFolder: calls.callsFolder)
            expanded = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private var speakerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let check = calls.speakerCheck, !check.finished {
                SpeakerCheckView(clips: calls.clips, check: check)
            } else {
                Label("Speakers saved", systemImage: "checkmark.circle.fill").foregroundStyle(WarbleColor.green)
                HStack { Spacer(); Button("Close") { checking = false }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(20)
        .frame(width: 420)
        .environmentObject(calls)
    }
}

/// One call in the list: when, how long, where it's filed, who spoke and the
/// headline. Click it to see the summary and actions.
private struct CallRow: View {
    let entry: CallEntry
    let said: String?
    let query: String
    let expanded: Bool
    let toCheck: Int?
    let folders: [String]
    let onToggle: () -> Void
    let onShare: () -> Void
    let onSpeakers: () -> Void
    let onMove: (String) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.when(entry.started))
                    .font(.callout.monospacedDigit())
                Text(Self.length(entry))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WarbleColor.idle)
            }
            .frame(width: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name).font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    FolderPill(folder: entry.folder)
                    if !entry.people.isEmpty || entry.unnamedVoices > 0 {
                        Faces(names: entry.people, unnamed: entry.unnamedVoices)
                        Text(Self.names(entry.people))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    if let toCheck {
                        Badge(text: "\(toCheck) speaker\(toCheck == 1 ? "" : "s") to check", color: CallPanelColor.amber)
                    } else if entry.unnamedVoices > 0 {
                        Badge(text: "\(entry.unnamedVoices) unnamed voice\(entry.unnamedVoices == 1 ? "" : "s")", color: WarbleColor.idle)
                    }
                    if entry.summaryPending {
                        Badge(text: "Summary on its way", color: WarbleColor.idle)
                    }
                }
                if let said {
                    Text("“\(said)”")
                        .font(.callout)
                        .foregroundStyle(WarbleColor.glow)
                        .lineLimit(2)
                } else if !entry.headline.isEmpty && !expanded {
                    Text(entry.headline)
                        .font(.callout)
                        .foregroundStyle(WarbleColor.idle)
                        .lineLimit(1)
                }
                if expanded { detail }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if toCheck != nil {
                    Button("Speakers", action: onSpeakers).help("Check and fix who spoke on this call")
                }
                Button("Share", action: onShare).help("Make a tidy PDF of this call to send to people")
                Button("Open") { NSWorkspace.shared.open(entry.url) }
                    .buttonStyle(.borderedProminent)
                    .help("Open the full note")
            }
            .controlSize(.small)
            .opacity(hovering || expanded ? 1 : 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hovering || expanded ? WarbleColor.surface : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(hovering || expanded ? WarbleColor.line : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if !entry.summary.isEmpty || !entry.headline.isEmpty {
                heading("Summary")
                if entry.summary.isEmpty {
                    Text(entry.headline)
                } else {
                    ForEach(Array(entry.summary.prefix(5).enumerated()), id: \.offset) { _, point in
                        Text("•  " + point).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !entry.actions.isEmpty {
                heading("Actions")
                ForEach(Array(entry.actions.prefix(6).enumerated()), id: \.offset) { _, action in
                    Text("•  " + action).fixedSize(horizontal: false, vertical: true)
                }
            }
            heading("On the call")
            Text((["Me"] + entry.people).joined(separator: ", ") + (entry.shortApp.isEmpty ? "" : " · \(entry.shortApp)"))
            HStack(spacing: 8) {
                Menu("Move to") {
                    ForEach(folders.filter { $0 != entry.folder }, id: \.self) { folder in
                        Button(folder) { onMove(folder) }
                    }
                    if !entry.isUnfiled {
                        Divider()
                        Button(CallLibraryLogic.unfiledFolder) { onMove("") }
                    }
                }
                .fixedSize()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .font(.callout)
        .padding(.top, 4)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(WarbleColor.idle)
    }

    /// "9:30 AM" for this week; "Nov 5" before that.
    static func when(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 6 * 86_400 {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "32 min", with the weekday and time for older calls: "Thu 2:00 PM · 58 min".
    static func length(_ entry: CallEntry, now: Date = Date()) -> String {
        let minutes = entry.minutes.map { "\(max(1, $0)) min" } ?? ""
        let day = Calendar.current.isDate(entry.started, inSameDayAs: now) ? ""
            : entry.started.formatted(.dateTime.weekday(.abbreviated)) + (minutes.isEmpty ? "" : " · ")
        return day + minutes
    }

    /// "Sarah, Matt, AJ +2".
    static func names(_ people: [String]) -> String {
        let firsts = people.prefix(3).map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        return firsts.joined(separator: ", ") + (people.count > 3 ? " +\(people.count - 3)" : "")
    }
}

/// Where a call is filed, as a small green tag.
struct FolderPill: View {
    let folder: String

    var body: some View {
        let unfiled = folder.isEmpty
        Label(unfiled ? CallLibraryLogic.unfiledFolder : folder, systemImage: "folder")
            .labelStyle(PillLabelStyle())
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(unfiled ? WarbleColor.idle : WarbleColor.glow)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(unfiled ? Color.clear : WarbleColor.green.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(unfiled ? WarbleColor.line : WarbleColor.green.opacity(0.3), lineWidth: 1))
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Up to four people's initials, overlapping; "?" for voices nobody named.
struct Faces: View {
    let names: [String]
    var unnamed: Int = 0

    var body: some View {
        let shown = Array(names.prefix(4))
        HStack(spacing: -5) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
                face(PeopleView.initials(name, among: names)).help(name)
            }
            if shown.count < 4 && unnamed > 0 {
                face("?").help("Not named yet")
            }
        }
    }

    private func face(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 22, height: 22)
            .background(Circle().fill(WarbleColor.surface))
            .overlay(Circle().strokeBorder(WarbleColor.background, lineWidth: 1.5))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.45), lineWidth: 1))
    }
}

/// A search box that looks the same on every page.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(WarbleColor.idle)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(WarbleColor.idle)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(WarbleColor.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WarbleColor.line, lineWidth: 1))
    }
}
