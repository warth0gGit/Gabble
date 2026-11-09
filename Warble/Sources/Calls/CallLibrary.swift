import Foundation

/// One saved call, as the Transcripts and People tabs show it: read back from
/// its note, so it includes Claude's summary and any edits you made.
struct CallEntry: Identifiable, Equatable {
    var url: URL
    var id: URL { url }
    /// "Atlas weekly sync", or "Teams call" when it has no name.
    var name: String
    var started: Date
    var minutes: Int?
    /// "Microsoft Teams", "zoom.us"…
    var app: String
    /// Where it's filed under Calls, e.g. "Projects/Atlas". Empty when unfiled.
    var folder: String
    /// Everyone else on the call by name (not "Me", not guesses).
    var people: [String]
    /// Voices nobody named: "Others", "Speaker 2", or a guess like "Matt?".
    var unnamedVoices: Int
    /// One line: the summary's headline, or its first point.
    var headline: String
    var summary: [String]
    var actions: [String]
    /// The summary is still being written.
    var summaryPending: Bool
    /// What was said, for searching.
    var lines: [SharedCall.Line]

    var isUnfiled: Bool { folder.isEmpty }
    var shortApp: String {
        app.replacingOccurrences(of: "Microsoft ", with: "").replacingOccurrences(of: "Google ", with: "")
            .replacingOccurrences(of: "zoom.us", with: "Zoom")
    }
}

/// Reads call notes and answers the questions the Transcripts and People tabs
/// ask: which folder, which day, what matches a search, who is on which calls.
/// Pure, unit tested.
enum CallLibraryLogic {
    /// The folder notes go in when Warble couldn't file them.
    static let unfiledFolder = "Unfiled"

    // MARK: Reading a note

    static func entry(note: String, url: URL, callsFolder: URL, modified: Date = Date()) -> CallEntry? {
        let front = NoteRewriter.frontMatter(of: note)
        guard front.contains(where: { $0.hasPrefix("date:") }) else { return nil }
        func value(_ key: String) -> String? {
            guard let line = front.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
            return unquote(String(line.dropFirst(key.count + 1)))
        }
        let shared = SharedCall.parse(note: note, me: "")
        let speakers = inlineList(value("speakers") ?? "")
        let unnamed = speakers.filter { $0 != "Me" && CallTranscript.isPlaceholder($0) }.count
        var people: [String] = []
        for name in shared.people + speakers.filter({ !CallTranscript.isPlaceholder($0) })
        where !name.isEmpty && !people.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            people.append(name)
        }
        let headline = value("summary").map(SharedCall.plainText)
            ?? shared.summary.first ?? shared.keyPoints.first ?? ""
        return CallEntry(
            url: url,
            name: shared.name,
            started: shared.started ?? modified,
            minutes: shared.minutes,
            app: value("app") ?? "",
            folder: folder(of: url, callsFolder: callsFolder),
            people: people,
            unnamedVoices: unnamed,
            headline: headline,
            summary: shared.summary,
            actions: shared.actions.map(SharedCall.describe),
            summaryPending: note.contains("[!summary] Summary on its way"),
            lines: shared.transcript
        )
    }

    /// "Projects/Atlas" for Calls/Projects/Atlas/note.md; "" for unfiled notes.
    static func folder(of note: URL, callsFolder: URL) -> String {
        let dir = note.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let root = callsFolder.resolvingSymlinksInPath().standardizedFileURL.path
        guard dir.hasPrefix(root + "/") else { return "" }
        let path = String(dir.dropFirst(root.count + 1))
        return path == unfiledFolder ? "" : path
    }

    /// `[Me, "Jordan?", Speaker 2]` → ["Me", "Jordan?", "Speaker 2"].
    static func inlineList(_ text: String) -> [String] {
        var body = text.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("["), body.hasSuffix("]") else { return [] }
        body = String(body.dropFirst().dropLast())
        var items: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for char in body {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" && quoted { escaped = true; continue }
            if char == "\"" { quoted.toggle(); continue }
            if char == "," && !quoted {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(char)
        }
        items.append(current.trimmingCharacters(in: .whitespaces))
        return items.filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return v
    }

    // MARK: Folders

    struct FolderNode: Equatable, Identifiable {
        var path: String
        var id: String { path }
        var name: String { path.components(separatedBy: "/").last ?? path }
        var depth: Int { path.components(separatedBy: "/").count - 1 }
        var count: Int
    }

    /// Every folder with calls in it, and the folders above them, in order:
    /// Clients, Clients/Acme, Projects, Projects/Atlas…
    static func folderTree(_ entries: [CallEntry]) -> [FolderNode] {
        var paths = Set<String>()
        for entry in entries where !entry.isUnfiled {
            let parts = entry.folder.components(separatedBy: "/")
            for n in 1...parts.count { paths.insert(parts.prefix(n).joined(separator: "/")) }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            FolderNode(path: path, count: entries.filter { isIn($0, folder: path) }.count)
        }
    }

    /// In this folder, or a folder inside it.
    static func isIn(_ entry: CallEntry, folder: String) -> Bool {
        entry.folder == folder || entry.folder.hasPrefix(folder + "/")
    }

    // MARK: Days

    /// "Today", "Yesterday", "Earlier this week", "Last week", then the month
    /// ("October", or "October 2025" for another year).
    static func dayGroup(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if date <= now, calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "Earlier this week" }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) {
            return "Last week"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMM" : "MMMM yyyy"
        return f.string(from: date)
    }

    struct DayGroup: Identifiable, Equatable {
        var day: String
        var id: String { day }
        var calls: [CallEntry]
    }

    /// Newest first, in day groups, keeping their order.
    static func byDay(_ entries: [CallEntry], now: Date = Date(), calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        for entry in entries.sorted(by: { $0.started > $1.started }) {
            let day = dayGroup(entry.started, now: now, calendar: calendar)
            if groups.last?.day == day {
                groups[groups.count - 1].calls.append(entry)
            } else {
                groups.append(DayGroup(day: day, calls: [entry]))
            }
        }
        return groups
    }

    // MARK: Search

    /// Whether a call matches what you typed (ignoring case and accents), and
    /// if the match is in what was said, that line so you can see why.
    static func match(_ entry: CallEntry, query: String) -> (matches: Bool, said: String?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return (true, nil) }
        let fields = [entry.name, entry.folder, entry.app, entry.headline] + entry.people + entry.summary + entry.actions
        if fields.contains(where: { $0.localizedStandardContains(q) }) { return (true, nil) }
        if let line = entry.lines.first(where: { $0.text.localizedStandardContains(q) }) {
            return (true, "\(line.speaker): " + snippet(line.text, around: q))
        }
        return (false, nil)
    }

    /// About `width` characters of the text with the match in the middle.
    static func snippet(_ text: String, around query: String, width: Int = 110) -> String {
        guard text.count > width,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return text }
        let at = text.distance(from: text.startIndex, to: range.lowerBound)
        let start = max(0, min(at - width / 3, text.count - width))
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
        return (start > 0 ? "…" : "") + text[from..<to].trimmingCharacters(in: .whitespaces) + (to < text.endIndex ? "…" : "")
    }

    // MARK: Needs a look

    /// A summary still on its way, or recent voices nobody named.
    static func needsLook(_ entry: CallEntry, now: Date = Date()) -> Bool {
        entry.summaryPending || (entry.unnamedVoices > 0 && now.timeIntervalSince(entry.started) < 7 * 86_400)
    }

    // MARK: People

    struct PersonStats: Equatable {
        var calls: [CallEntry] = []
        var last: Date? { calls.map(\.started).max() }
        /// The folder most of their calls are filed in (most recent wins a tie).
        var mostlyIn: String?
    }

    static func stats(for name: String, in entries: [CallEntry]) -> PersonStats {
        let theirs = entries.filter { $0.people.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            .sorted { $0.started > $1.started }
        var counts: [String: Int] = [:]
        for call in theirs { counts[call.folder, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        let mostly = theirs.first { counts[$0.folder] == top }?.folder
        return PersonStats(calls: theirs, mostlyIn: mostly)
    }

    static let noCallsGroup = "Not on a saved call yet"

    /// Where you meet them: the top folder most of their calls are in.
    static func placeGroup(_ stats: PersonStats) -> String {
        guard let folder = stats.mostlyIn else { return noCallsGroup }
        if folder.isEmpty { return unfiledFolder }
        return folder.components(separatedBy: "/").first ?? folder
    }

    /// "This week", "This month", "Earlier", or no calls yet.
    static func recentGroup(_ stats: PersonStats, now: Date = Date()) -> String {
        guard let last = stats.last else { return noCallsGroup }
        let age = now.timeIntervalSince(last)
        if age < 7 * 86_400 { return "This week" }
        if age < 31 * 86_400 { return "This month" }
        return "Earlier"
    }

    // MARK: Moving

    /// Moves a note into another folder under Calls (empty = Unfiled) and
    /// updates its category, so Obsidian and Warble agree on where it is.
    static func move(note: URL, to folder: String, callsFolder: URL) throws -> URL {
        let target = callsFolder.appendingPathComponent(folder.isEmpty ? unfiledFolder : folder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let base = note.deletingPathExtension().lastPathComponent
        var dest = target.appendingPathComponent(note.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = target.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        let text = try String(contentsOf: note, encoding: .utf8)
        try recategorised(text, folder: folder.isEmpty ? unfiledFolder : folder).write(to: dest, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: note)
        return dest
    }

    /// The note with `category:` in its front matter set to `folder`.
    static func recategorised(_ note: String, folder: String) -> String {
        var lines = note.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return note }
        let line = "category: \(CallTranscript.yamlValue(folder))"
        if let i = lines[1..<close].firstIndex(where: { $0.hasPrefix("category:") }) {
            lines[i] = line
        } else {
            lines.insert(line, at: close)
        }
        return lines.joined(separator: "\n")
    }
}

/// Every saved call note, read in the background and kept up to date.
@MainActor
final class CallLibrary: ObservableObject {
    @Published private(set) var entries: [CallEntry] = []
    @Published private(set) var loaded = false

    struct Cached {
        var modified: Date
        var entry: CallEntry?
    }

    private var cache: [URL: Cached] = [:]
    private var scanning = false
    private var again = false

    /// Re-reads the Calls folder. Only notes that changed are read again.
    func refresh(callsFolder: URL) {
        guard !scanning else { again = true; return }
        scanning = true
        let cache = self.cache
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CallLibrary.scan(callsFolder, cache: cache)
            }.value
            self.cache = result
            self.entries = result.values.compactMap(\.entry).sorted { $0.started > $1.started }
            self.loaded = true
            self.scanning = false
            if self.again {
                self.again = false
                self.refresh(callsFolder: callsFolder)
            }
        }
    }

    nonisolated static func scan(_ callsFolder: URL, cache: [URL: Cached]) -> [URL: Cached] {
        var result: [URL: Cached] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: callsFolder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in enumerator where url.pathExtension == "md" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let hit = cache[url], hit.modified == modified {
                result[url] = hit
                continue
            }
            let entry = (try? String(contentsOf: url, encoding: .utf8)).flatMap {
                CallLibraryLogic.entry(note: $0, url: url, callsFolder: callsFolder, modified: modified)
            }
            result[url] = Cached(modified: modified, entry: entry)
        }
        return result
    }

    func move(_ entry: CallEntry, to folder: String, callsFolder: URL) throws {
        _ = try CallLibraryLogic.move(note: entry.url, to: folder, callsFolder: callsFolder)
        refresh(callsFolder: callsFolder)
    }
}
