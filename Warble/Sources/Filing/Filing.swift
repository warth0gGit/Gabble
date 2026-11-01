import Foundation

/// What Warble knows about a call when deciding where to file it.
struct CallFeatures: Equatable {
    /// Same for every meeting in a repeating calendar series.
    var seriesID: String?
    /// The meeting's calendar title, if there was one.
    var meetingTitle: String?
    /// The other people on the call: calendar attendees and voices Warble recognised.
    var people: [String]
    var weekday: Int
    var hour: Int

    init(seriesID: String? = nil, meetingTitle: String? = nil, people: [String] = [], date: Date,
         calendar: Calendar = .current) {
        self.seriesID = seriesID
        self.meetingTitle = meetingTitle
        self.people = people
        weekday = calendar.component(.weekday, from: date)
        hour = calendar.component(.hour, from: date)
    }

    var peopleKeys: Set<String> { Set(people.map { $0.lowercased() }) }
}

/// A folder Warble files calls into, and what calls filed there have had in common.
struct FilingRule: Codable, Identifiable, Equatable {
    struct Slot: Codable, Hashable {
        var weekday: Int
        var hour: Int
    }

    var id = UUID()
    /// Path under the Calls folder, e.g. "1-1s/Sarah Jones" or "Projects/Atlas".
    var folder: String
    var seriesIDs: [String] = []
    var titles: [String] = []
    var peopleSets: [[String]] = []
    var slots: [Slot] = []
    var timesUsed = 0
    var lastUsed = Date()
}

/// A suggested folder and how sure Warble is about it.
struct FilingSuggestion: Equatable {
    var folder: String
    var confidence: Double
    /// Plain-English reason, e.g. "same repeating meeting".
    var reason: String
}

/// Decides where a call should go and learns from where you put calls. Pure, unit tested.
enum FilingBrain {
    /// At or above this, Warble files the call itself and says where.
    static let autoFileConfidence = 0.85

    static func suggestions(for call: CallFeatures, rules: [FilingRule], limit: Int = 3) -> [FilingSuggestion] {
        var scored = rules.compactMap { rule -> FilingSuggestion? in
            let (score, reason) = self.score(call, against: rule)
            return score > 0.3 ? FilingSuggestion(folder: rule.folder, confidence: score, reason: reason) : nil
        }
        scored.sort { a, b in
            a.confidence != b.confidence ? a.confidence > b.confidence : a.folder < b.folder
        }
        var result = Array(scored.prefix(limit))
        // Offer a sensible new folder when nothing known fits well.
        if let fresh = newFolder(for: call), !result.contains(where: { $0.folder == fresh }),
           (result.first?.confidence ?? 0) < autoFileConfidence, result.count < limit {
            result.append(FilingSuggestion(folder: fresh, confidence: 0.3, reason: "new folder"))
        }
        return result
    }

    /// The folder to file into without asking, if Warble is sure enough.
    static func autoFolder(for call: CallFeatures, rules: [FilingRule]) -> FilingSuggestion? {
        guard let best = suggestions(for: call, rules: rules, limit: 1).first,
              best.confidence >= autoFileConfidence else { return nil }
        return best
    }

    static func score(_ call: CallFeatures, against rule: FilingRule) -> (Double, String) {
        var best = 0.0
        var reason = ""
        func consider(_ value: Double, _ why: String) {
            if value > best { best = value; reason = why }
        }
        if let series = call.seriesID, rule.seriesIDs.contains(series) {
            consider(0.97, "same repeating meeting")
        }
        if let title = call.meetingTitle.map(normalisedTitle), !title.isEmpty,
           rule.titles.contains(title) {
            consider(0.9, "same meeting name")
        }
        let people = call.peopleKeys
        if !people.isEmpty {
            for set in rule.peopleSets {
                let other = Set(set)
                let overlap = Double(people.intersection(other).count) / Double(people.union(other).count)
                if overlap == 1 {
                    consider(people.count == 1 ? 0.92 : 0.88, people.count == 1 ? "same person" : "same people")
                } else if overlap >= 0.5 {
                    consider(0.5 + overlap * 0.3, "mostly the same people")
                }
            }
        }
        let slotMatch = rule.slots.contains(FilingRule.Slot(weekday: call.weekday, hour: call.hour))
        if slotMatch {
            if best > 0 {
                best = min(0.99, best + 0.08)
            } else {
                consider(0.45, "same day and time")
            }
        }
        return (best, reason)
    }

    /// Records that a call with these features went into `folder`.
    static func learn(_ call: CallFeatures, folder: String, rules: inout [FilingRule], now: Date = Date()) {
        let folder = FolderName.clean(folder)
        // "Unfiled" means "not sure", not a place calls belong.
        guard !folder.isEmpty, folder.caseInsensitiveCompare("Unfiled") != .orderedSame else { return }
        // A call belongs to one folder: forget the strong signals elsewhere, so a
        // correction ("not there, here") takes effect next time.
        for index in rules.indices where rules[index].folder != folder {
            if let series = call.seriesID { rules[index].seriesIDs.removeAll { $0 == series } }
            if let title = call.meetingTitle.map(normalisedTitle) { rules[index].titles.removeAll { $0 == title } }
            let people = call.peopleKeys
            if !people.isEmpty { rules[index].peopleSets.removeAll { Set($0) == people } }
        }
        var rule = rules.first(where: { $0.folder == folder }) ?? FilingRule(folder: folder)
        if let series = call.seriesID, !rule.seriesIDs.contains(series) { rule.seriesIDs.append(series) }
        if let title = call.meetingTitle.map(normalisedTitle), !title.isEmpty, !rule.titles.contains(title) {
            rule.titles.append(title)
        }
        let people = call.peopleKeys.sorted()
        if !people.isEmpty, !rule.peopleSets.contains(people) { rule.peopleSets.append(people) }
        let slot = FilingRule.Slot(weekday: call.weekday, hour: call.hour)
        if !rule.slots.contains(slot) { rule.slots.append(slot) }
        rule.timesUsed += 1
        rule.lastUsed = now
        if let index = rules.firstIndex(where: { $0.folder == folder }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
    }

    /// A folder to suggest for a call Warble hasn't seen the like of: a 1:1
    /// gets the person's name, a named meeting gets its name.
    static func newFolder(for call: CallFeatures) -> String? {
        if call.people.count == 1, let person = call.people.first {
            return FolderName.clean("1-1s/\(person)")
        }
        if let title = call.meetingTitle, !normalisedTitle(title).isEmpty {
            return FolderName.clean("Meetings/\(title)")
        }
        return nil
    }

    /// "Weekly Sync – 3 Nov (moved)" and "weekly sync" are the same meeting.
    static func normalisedTitle(_ title: String) -> String {
        var text = title.lowercased()
        for noise in ["(moved)", "(updated)", "(rescheduled)", "updated invitation:", "invitation:", "fw:", "re:"] {
            text = text.replacingOccurrences(of: noise, with: " ")
        }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { word in !word.allSatisfy(\.isNumber) && !months.contains(String(word)) }
        return words.joined(separator: " ")
    }

    private static let months: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "january", "february", "march", "april", "june", "july", "august", "september", "october",
        "november", "december",
    ]
}

/// Folder paths that are safe on every disk and in Obsidian.
enum FolderName {
    /// Cleans each part of a path like "1-1s/Sarah: Jones" → "1-1s/Sarah Jones".
    static func clean(_ path: String) -> String {
        path.split(separator: "/")
            .map { part in
                let cleaned = part.map { ":\\*?\"<>|#^[]".contains($0) ? " " : $0 }
                return String(cleaned)
                    .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    /// A file name that is safe on every disk and in Obsidian links.
    static func fileName(_ name: String) -> String {
        clean(name.replacingOccurrences(of: "/", with: "-"))
    }
}

/// Saves the filing rules as JSON in Application Support.
@MainActor
final class FilingStore: ObservableObject {
    @Published private(set) var rules: [FilingRule] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = support.appendingPathComponent("Warble", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("filing.json")
        }
        load()
    }

    /// Every folder Warble has filed into, most used first.
    var folders: [String] {
        rules.sorted { $0.timesUsed != $1.timesUsed ? $0.timesUsed > $1.timesUsed : $0.folder < $1.folder }
            .map(\.folder)
    }

    /// Warble's best guesses, topped up with your most-used folders.
    func suggestions(for call: CallFeatures) -> [FilingSuggestion] {
        var result = FilingBrain.suggestions(for: call, rules: rules)
        for folder in folders where result.count < 4 && !result.contains(where: { $0.folder == folder }) {
            result.append(FilingSuggestion(folder: folder, confidence: 0.1, reason: "used before"))
        }
        return result
    }

    func autoFolder(for call: CallFeatures) -> FilingSuggestion? {
        FilingBrain.autoFolder(for: call, rules: rules)
    }

    func learn(_ call: CallFeatures, folder: String) {
        FilingBrain.learn(call, folder: folder, rules: &rules)
        save()
    }

    func forget(_ rule: FilingRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([FilingRule].self, from: data) else { return }
        rules = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(rules) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
