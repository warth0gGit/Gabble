import Foundation

/// A friendly, Plaud-style summary of a call: what it was about, what was
/// decided and who is doing what. Written by Apple Intelligence (see
/// CallSummariser); everything here is pure data and unit tested.
struct CallSummary: Equatable {
    struct ActionItem: Equatable {
        /// "Me", a person's name as it appears in the transcript, or "" if nobody was named.
        var owner: String
        var task: String
        /// When it's due, in the words used on the call ("by Friday"), or "".
        var due: String = ""
    }

    struct Topic: Equatable {
        var offset: TimeInterval
        var title: String
    }

    /// One line for the note's front matter and search results.
    var headline: String
    /// Two to four sentences.
    var overview: String
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
    var openQuestions: [String] = []
    var topics: [Topic] = []
    /// Parts of the call Apple Intelligence wouldn't or couldn't read.
    var skippedParts = 0

    /// Who wrote it, for the front matter.
    static let writer = "Apple Intelligence (on this Mac)"

    // MARK: - Markdown

    /// The summary sections of a call note, from the summary callout down to
    /// the topics. Sections with nothing in them are left out.
    func markdownLines(people: [String], callDate: Date) -> [String] {
        var lines: [String] = ["> [!summary] Summary"]
        lines += Self.quoted(overview)
        if skippedParts > 0 {
            lines.append(">")
            lines.append("> *Part of this call couldn't be summarized, so check the transcript for anything missing.*")
        }
        lines.append("")
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("## \(title)")
            lines += items
            lines.append("")
        }
        section("Key points", keyPoints.map { "- \($0)" })
        section("Decisions", decisions.map { "- \($0)" })
        section("Action items", Self.sortedActions(actionItems).map { Self.task($0, people: people, callDate: callDate) })
        section("Open questions", openQuestions.map { "- \($0)" })
        section("Topics", topics.sorted { $0.offset < $1.offset }
            .map { "- \(CallTranscript.timestamp($0.offset)) \($0.title)" })
        return lines
    }

    /// Your own actions first, then everyone else's in the order they came up.
    static func sortedActions(_ items: [ActionItem]) -> [ActionItem] {
        items.filter { $0.owner == "Me" } + items.filter { $0.owner != "Me" }
    }

    /// An Obsidian task line, e.g. "- [ ] **[[Sarah Jones]]**: send the deck 📅 2026-11-07".
    /// The 📅 date works with the Obsidian Tasks plugin; a due phrase Warble
    /// can't turn into a date is kept in words.
    static func task(_ item: ActionItem, people: [String], callDate: Date, calendar: Calendar = .current) -> String {
        var line = "- [ ] "
        if !item.owner.isEmpty {
            if let person = people.first(where: { $0.caseInsensitiveCompare(item.owner) == .orderedSame }) {
                line += "**\(CallTranscript.link(person))**: "
            } else {
                line += "**\(item.owner)**: "
            }
        }
        line += item.task
        if !item.due.isEmpty {
            if let date = dueDate(item.due, from: callDate, calendar: calendar) {
                line += " 📅 " + dayFormatter(calendar).string(from: date)
            } else {
                line += " (\(item.due))"
            }
        }
        return line
    }

    /// Prefixes every line for an Obsidian callout.
    static func quoted(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
    }

    // MARK: - Due dates

    /// Turns "by Friday", "tomorrow", "end of the week" or "7 November" into a
    /// date, counted from the day of the call. Nil if it can't tell.
    static func dueDate(_ phrase: String, from callDate: Date, calendar: Calendar = .current) -> Date? {
        let text = phrase.lowercased()
        let day = calendar.startOfDay(for: callDate)
        func plus(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: day) }
        func words(_ list: [String]) -> Bool {
            list.contains { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
        }

        if words(["today", "tonight", "end of day", "end of the day", "eod"]) { return day }
        if words(["tomorrow"]) { return plus(1) }

        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let today = calendar.component(.weekday, from: day) // 1 = Sunday
        func next(_ weekday: Int, allowToday: Bool) -> Date? {
            var ahead = (weekday - today + 7) % 7
            if ahead == 0 && !allowToday { ahead = 7 }
            return plus(ahead)
        }
        if words(["end of the week", "end of week", "eow", "this week"]) { return next(6, allowToday: true) }
        if let index = weekdays.firstIndex(where: { words([$0]) }) { return next(index + 1, allowToday: false) }

        // "7 November", "7th Nov", "November 7", "Nov 7th"
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let monthPattern = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*"
        let patterns = ["\\b(\\d{1,2})(?:st|nd|rd|th)?(?: of)? \(monthPattern)\\b",
                        "\\b\(monthPattern) (\\d{1,2})(?:st|nd|rd|th)?\\b"]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let first = Range(match.range(at: 1), in: text),
                  let second = Range(match.range(at: 2), in: text) else { continue }
            let dayText = index == 0 ? text[first] : text[second]
            let monthText = index == 0 ? text[second] : text[first]
            guard let dayNumber = Int(dayText), let month = months.firstIndex(of: String(monthText.prefix(3))) else { continue }
            var parts = calendar.dateComponents([.year], from: day)
            parts.month = month + 1
            parts.day = dayNumber
            guard let date = calendar.date(from: parts) else { continue }
            // A date that has already passed means next year.
            return date < day ? calendar.date(byAdding: .year, value: 1, to: date) : date
        }
        return nil
    }

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    // MARK: - Combining parts

    /// Joins the notes on each part of a long call without the model, used if
    /// Apple Intelligence can't combine them itself. Drops repeats.
    static func combined(_ parts: [CallSummary]) -> CallSummary? {
        guard let first = parts.first else { return nil }
        func unique(_ items: [String]) -> [String] {
            var seen = Set<String>()
            return items.filter { seen.insert($0.lowercased()).inserted }
        }
        var actions: [ActionItem] = []
        for item in parts.flatMap(\.actionItems)
        where !actions.contains(where: { $0.owner == item.owner && $0.task.lowercased() == item.task.lowercased() }) {
            actions.append(item)
        }
        return CallSummary(
            headline: first.headline,
            overview: parts.map(\.overview).filter { !$0.isEmpty }.joined(separator: " "),
            keyPoints: unique(parts.flatMap(\.keyPoints)),
            decisions: unique(parts.flatMap(\.decisions)),
            actionItems: actions,
            openQuestions: unique(parts.flatMap(\.openQuestions)),
            topics: parts.flatMap(\.topics).sorted { $0.offset < $1.offset },
            skippedParts: parts.map(\.skippedParts).reduce(0, +))
    }

    /// The notes on a part of the call as plain text, for the step that
    /// combines parts into notes for the whole call.
    var asNotes: String {
        var lines = ["Overview: \(overview)"]
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("\(title):")
            lines += items.map { "- \($0)" }
        }
        list("Key points", keyPoints)
        list("Decisions", decisions)
        list("Action items", actionItems.map { item in
            let who = item.owner.isEmpty ? "" : "\(item.owner): "
            return who + item.task + (item.due.isEmpty ? "" : " (\(item.due))")
        })
        list("Open questions", openQuestions)
        return lines.joined(separator: "\n")
    }
}

/// Where a call's summary has got to. Shown in the note itself, so you can
/// always tell whether a summary is coming, there, or not possible.
enum CallSummaryState: Equatable {
    /// Not attempted, e.g. a very short call.
    case none
    case pending
    case done(CallSummary)
    case failed(String)

    var summary: CallSummary? {
        if case .done(let summary) = self { return summary }
        return nil
    }
}

/// Splits a transcript into pieces small enough for Apple Intelligence,
/// which can only read a few thousand words at once. Pure, unit tested.
enum SummaryChunker {
    struct Chunk: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var lines: [String]
        var words: Int

        var text: String { lines.joined(separator: "\n") }
    }

    /// Calls shorter than this aren't worth summarizing.
    static let minimumWords = 60

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    /// "Sarah Jones (07:40): what she said" lines, grouped into chunks of at
    /// most `maxWords` words. A very long turn is split across chunks.
    static func chunks(of transcript: CallTranscript, maxWords: Int = 1000) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: Chunk?
        for segment in transcript.merged {
            let words = segment.text.split(separator: " ")
            var index = 0
            while index < words.count {
                let room = maxWords - (current?.words ?? 0)
                let remaining = words.count - index
                // Start a new chunk rather than split a turn that would fit in one,
                // and don't leave a sliver at the end of a chunk.
                if let full = current, (remaining > room && remaining <= maxWords) || room < min(40, maxWords) {
                    chunks.append(full)
                    current = nil
                    continue
                }
                let take = min(room, words.count - index)
                let piece = words[index..<(index + take)].joined(separator: " ")
                let line = "\(segment.speaker) (\(CallTranscript.timestamp(segment.offset))): \(piece)"
                if current == nil {
                    current = Chunk(start: segment.offset, end: segment.offset, lines: [], words: 0)
                }
                current?.lines.append(line)
                current?.words += take
                current?.end = segment.offset
                index += take
            }
        }
        if let current, !current.lines.isEmpty { chunks.append(current) }
        return chunks
    }

    /// "07:40" or "1:07:40" as seconds.
    static func offset(fromTimestamp text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]")).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ (0..<60).contains($0) }) else { return nil }
        return TimeInterval(numbers.reduce(0) { $0 * 60 + $1 })
    }
}
