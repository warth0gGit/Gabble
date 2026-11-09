import AppKit
import SwiftUI

/// The people Warble knows by voice, grouped by where you meet them (the
/// folder most of their calls are filed in), A to Z, or how recently you
/// spoke. Each shows how many calls, when you last spoke and how well Warble
/// knows their voice; click one to see their calls. Rename, Merge into… and
/// Forget (with Undo) are on each person.
struct PeopleView: View {
    @EnvironmentObject private var calls: CallController
    /// Opens the Transcripts tab searching for this person.
    var onShowCalls: (String) -> Void

    var body: some View {
        PeopleBrowser(voices: calls.voices, library: calls.library, onShowCalls: onShowCalls)
    }

    // MARK: - Pure, unit tested

    /// How well Warble knows a voice, from how many recordings of them it keeps.
    static func strength(_ voice: Voiceprint) -> (bars: Int, label: String) {
        switch voice.prints.count {
        case ...1: return (1, "Still learning")
        case 2...3: return (2, "Getting there")
        case 4...5: return (3, "Knows well")
        default: return (4, "Knows well")
        }
    }

    /// "AJ" for AJ Patel, "MK" for Matt Kern, "M" for Matt, so people who
    /// share a first letter don't look alike.
    static func initials(_ name: String, among names: [String]) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 { return (String(parts[0].prefix(1)) + String(parts[parts.count - 1].prefix(1))).uppercased() }
        let word = String(parts.first ?? "")
        if word.count <= 2 { return word.uppercased() }
        return String(word.prefix(1)).uppercased()
    }

    /// Someone else on file who's probably the same person: one name is the
    /// other's first name (Matt / Matt Kern) and the voices are close.
    static func likelyDuplicate(of voice: Voiceprint, in all: [Voiceprint]) -> Voiceprint? {
        func first(_ name: String) -> String { name.split(separator: " ").first.map { $0.lowercased() } ?? name.lowercased() }
        let isShort = !voice.name.contains(" ")
        guard isShort else { return nil }   // offer merging the short name into the full one
        return all.first { other in
            other.id != voice.id && other.name.contains(" ") && first(other.name) == voice.name.lowercased()
                && VoiceMatcher.distance(voice.embedding, to: other) <= VoiceMatcher.tentativeDistance
        }
    }

    /// Worth a look: probably someone else on file, or a voice Warble has
    /// heard only once.
    static func needsLook(_ voice: Voiceprint, in all: [Voiceprint]) -> Bool {
        likelyDuplicate(of: voice, in: all) != nil || strength(voice).bars == 1
    }
}

enum PeopleFilter: Hashable {
    case everyone, needsLook
    case place(String)
}

private struct PeopleBrowser: View {
    @ObservedObject var voices: VoiceprintStore
    @ObservedObject var library: CallLibrary
    var onShowCalls: (String) -> Void
    @EnvironmentObject private var calls: CallController

    @State private var filter: PeopleFilter? = .everyone
    @State private var grouping: Grouping = .place
    @State private var query = ""
    @State private var expanded: UUID?
    @State private var renaming: Voiceprint?
    @State private var newName = ""
    @State private var forgetting: Voiceprint?
    @State private var forgotten: Voiceprint?
    @State private var undoTask: Task<Void, Never>?

    enum Grouping: String, CaseIterable, Identifiable {
        case place = "Where you meet them", alphabet = "A to Z", recent = "Most recent"
        var id: String { rawValue }
    }

    private struct Person: Identifiable {
        var voice: Voiceprint
        var stats: CallLibraryLogic.PersonStats
        var place: String
        var id: UUID { voice.id }
    }

    private struct PersonGroup: Identifiable {
        var title: String
        var id: String { title }
        var people: [Person]
    }

    var body: some View {
        let everyone = people
        HStack(spacing: 0) {
            sidebar(everyone)
                .frame(width: 200)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                list(everyone)
            }
            .frame(maxWidth: .infinity)
        }
        .background(WarbleColor.background)
        .navigationTitle("People")
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let voice = renaming { voices.rename(from: voice.name, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("If someone already has this name, the two are joined as one person.")
        }
        .confirmationDialog("Forget \(forgetting?.name ?? "")?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }
        )) {
            Button("Forget", role: .destructive) {
                if let voice = forgetting { forget(voice) }
                forgetting = nil
            }
        } message: {
            Text("Warble will ask \"Who's this?\" again next time they're on a call.")
        }
        .onAppear { library.refresh(callsFolder: calls.callsFolder) }
    }

    private var people: [Person] {
        voices.voices.map { voice in
            let stats = CallLibraryLogic.stats(for: voice.name, in: library.entries)
            return Person(voice: voice, stats: stats, place: CallLibraryLogic.placeGroup(stats))
        }
    }

    // MARK: Groups

    private func sidebar(_ everyone: [Person]) -> some View {
        let places = Dictionary(grouping: everyone, by: \.place)
        let names = places.keys.sorted { a, b in
            // Real folders first, then Unfiled, then people with no saved calls.
            func rank(_ s: String) -> Int {
                s == CallLibraryLogic.noCallsGroup ? 2 : s == CallLibraryLogic.unfiledFolder ? 1 : 0
            }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.localizedStandardCompare(b) == .orderedAscending
        }
        let attention = everyone.filter { PeopleView.needsLook($0.voice, in: voices.voices) }.count
        return List(selection: $filter) {
            row("Everyone", "person.2", everyone.count).tag(PeopleFilter.everyone)
            row("Needs a look", "exclamationmark.triangle", attention, warn: true).tag(PeopleFilter.needsLook)
            Section("Where you meet them") {
                ForEach(names, id: \.self) { name in
                    row(name, name == CallLibraryLogic.noCallsGroup ? "person.crop.circle.badge.questionmark" : "folder",
                        places[name]?.count ?? 0)
                        .tag(PeopleFilter.place(name))
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

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchField(text: $query, prompt: "Search people")
            HStack(spacing: 8) {
                Text("Group by").font(.callout).foregroundStyle(WarbleColor.idle)
                Picker("Group by", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: List

    private func groups(_ everyone: [Person]) -> [PersonGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = everyone.filter { person in
            switch filter ?? .everyone {
            case .everyone: break
            case .needsLook: if !PeopleView.needsLook(person.voice, in: voices.voices) { return false }
            case .place(let place): if person.place != place { return false }
            }
            return q.isEmpty || person.voice.name.localizedStandardContains(q) || person.place.localizedStandardContains(q)
                || (person.stats.mostlyIn ?? "").localizedStandardContains(q)
        }
        let now = Date()
        func key(_ person: Person) -> String {
            switch grouping {
            case .place: return person.place
            case .alphabet: return person.voice.name.first.map { String($0).uppercased() } ?? "#"
            case .recent: return CallLibraryLogic.recentGroup(person.stats, now: now)
            }
        }
        let order: [String]
        switch grouping {
        case .recent:
            order = ["This week", "This month", "Earlier", CallLibraryLogic.noCallsGroup]
        default:
            order = Set(shown.map(key)).sorted { a, b in
                func rank(_ s: String) -> Int {
                    s == CallLibraryLogic.noCallsGroup ? 2 : s == CallLibraryLogic.unfiledFolder ? 1 : 0
                }
                return rank(a) != rank(b) ? rank(a) < rank(b) : a.localizedStandardCompare(b) == .orderedAscending
            }
        }
        return order.compactMap { title in
            let inGroup = shown.filter { key($0) == title }.sorted { a, b in
                switch grouping {
                case .alphabet:
                    return a.voice.name.localizedCaseInsensitiveCompare(b.voice.name) == .orderedAscending
                case .recent:
                    return (a.stats.last ?? a.voice.updated) > (b.stats.last ?? b.voice.updated)
                case .place:
                    return a.stats.calls.count != b.stats.calls.count ? a.stats.calls.count > b.stats.calls.count
                        : a.voice.name.localizedCaseInsensitiveCompare(b.voice.name) == .orderedAscending
                }
            }
            return inGroup.isEmpty ? nil : PersonGroup(title: title, people: inGroup)
        }
    }

    private func list(_ everyone: [Person]) -> some View {
        let groups = self.groups(everyone)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                Text("When Warble hears someone it doesn't know on a call, it asks \"Who's this?\". Their voice is remembered here, on this Mac only, so next time their lines are labeled automatically.")
                    .font(.callout)
                    .foregroundStyle(WarbleColor.idle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                if let gone = forgotten {
                    HStack {
                        Text("Forgot \(gone.name).").foregroundStyle(WarbleColor.idle)
                        Spacer()
                        Button("Undo") { restore(gone) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(WarbleColor.surface))
                }
                if groups.isEmpty {
                    Text(voices.voices.isEmpty ? "Nobody yet." : "Nobody matches. Try another name.")
                        .foregroundStyle(WarbleColor.idle)
                        .padding(.vertical, 24)
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.people) { person in
                            PersonRow(
                                voice: person.voice,
                                stats: person.stats,
                                all: voices.voices,
                                expanded: expanded == person.id,
                                onToggle: { withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == person.id ? nil : person.id } },
                                onRename: { newName = person.voice.name; renaming = person.voice },
                                onMerge: { voices.merge(person.voice.name, into: $0) },
                                onForget: { forgetting = person.voice },
                                onShowCalls: { onShowCalls(person.voice.name) }
                            )
                        }
                    } header: {
                        Text("\(group.title.uppercased()) · \(group.people.count)")
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

    private func forget(_ voice: Voiceprint) {
        voices.forget(voice)
        forgotten = voice
        undoTask?.cancel()
        undoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { forgotten = nil }
        }
    }

    /// Puts a forgotten person back, with every recording Warble had of them.
    private func restore(_ voice: Voiceprint) {
        for print in voice.prints { voices.remember(name: voice.name, embedding: print) }
        forgotten = nil
        undoTask?.cancel()
    }
}

/// One person: initials, name, their calls at a glance and how well Warble
/// knows their voice. Click to see their recent calls.
private struct PersonRow: View {
    let voice: Voiceprint
    let stats: CallLibraryLogic.PersonStats
    let all: [Voiceprint]
    let expanded: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onMerge: (String) -> Void
    let onForget: () -> Void
    let onShowCalls: () -> Void
    @State private var hovering = false

    var body: some View {
        let duplicate = PeopleView.likelyDuplicate(of: voice, in: all)
        let strength = PeopleView.strength(voice)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(PeopleView.initials(voice.name, among: all.map(\.name)))
                    .font(.caption.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(WarbleColor.surface))
                    .overlay(Circle().strokeBorder(WarbleColor.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name).font(.headline)
                    HStack(spacing: 4) {
                        Text(summary)
                        if let duplicate {
                            Text("· maybe the same person as \(duplicate.name)").foregroundStyle(CallPanelColor.amber)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(WarbleColor.idle)
                    .lineLimit(1)
                }
                Spacer()
                if let duplicate {
                    Button("Merge") { onMerge(duplicate.name) }
                        .controlSize(.small)
                        .help("Join \(voice.name) into \(duplicate.name)")
                }
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 2) {
                        ForEach(0..<4, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(i < strength.bars ? WarbleColor.green : WarbleColor.line)
                                .frame(width: 5, height: 9)
                        }
                    }
                    Text(strength.label).font(.caption2).foregroundStyle(WarbleColor.idle)
                }
                Menu {
                    Button("Rename…", action: onRename)
                    let others = all.filter { $0.id != voice.id }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    if !others.isEmpty {
                        Menu("Merge into…") {
                            ForEach(others) { other in
                                Button(other.name) { onMerge(other.name) }
                            }
                        }
                    }
                    Divider()
                    Button("Forget…", role: .destructive, action: onForget)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if expanded { detail }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering || expanded ? WarbleColor.surface : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hovering || expanded ? WarbleColor.line : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
    }

    /// "14 calls · last spoke Nov 7 · mostly in Projects/Atlas".
    private var summary: String {
        let count = stats.calls.count
        guard count > 0, let last = stats.last else {
            return "No saved calls yet · voice saved \(voice.updated.formatted(.dateTime.month(.abbreviated).day()))"
        }
        var text = "\(count) call\(count == 1 ? "" : "s") · last spoke \(Self.day(last, midSentence: true))"
        if let folder = stats.mostlyIn {
            text += " · mostly in \(folder.isEmpty ? CallLibraryLogic.unfiledFolder : folder)"
        }
        return text
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("RECENT CALLS")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(WarbleColor.idle)
            if stats.calls.isEmpty {
                Text("No saved calls with \(voice.name) yet.").foregroundStyle(WarbleColor.idle)
            }
            ForEach(stats.calls.prefix(4)) { call in
                Button {
                    NSWorkspace.shared.open(call.url)
                } label: {
                    HStack(spacing: 10) {
                        Text(Self.day(call.started))
                            .foregroundStyle(WarbleColor.idle)
                            .frame(width: 80, alignment: .leading)
                        Text(call.name).lineLimit(1)
                        FolderPill(folder: call.folder)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the note")
            }
            HStack(spacing: 8) {
                if !stats.calls.isEmpty {
                    Button("Show all their calls", action: onShowCalls).buttonStyle(.borderedProminent)
                }
                Button("Rename…", action: onRename)
                Button("Forget…", action: onForget)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .font(.callout)
        .padding(.leading, 44)
    }

    /// "Today", "Yesterday", or "Nov 7" ("today" and "yesterday" mid-sentence).
    static func day(_ date: Date, midSentence: Bool = false) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return midSentence ? "today" : "Today" }
        if calendar.isDateInYesterday(date) { return midSentence ? "yesterday" : "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
