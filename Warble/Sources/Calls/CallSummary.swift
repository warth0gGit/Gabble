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
    /// Words speech recognition misheard, fixed in the transcript when the summary is added.
    var corrections: [Correction] = []
    /// Who wrote it, for the front matter.
    var writer = CallSummary.appleWriter
    /// Apple Intelligence's stand-in because Claude couldn't answer; Warble
    /// asks Claude again later and replaces it (see SummaryQueue).
    var provisional = false

    struct Correction: Equatable {
        var heard: String
        var meant: String
    }

    static let appleWriter = "Apple Intelligence (on this Mac)"

    /// The line above a stand-in summary, and the front matter that marks it.
    static let draftCallout = "> [!note] Draft by Apple Intelligence. Claude will replace this when it's available."
    static let provisionalStatus = "summary_status: provisional"

    // MARK: - Markdown

    /// The summary sections of a call note, from the summary callout down to
    /// the topics. Sections with nothing in them are left out.
    func markdownLines(people: [String], callDate: Date) -> [String] {
        var lines: [String] = provisional ? [Self.draftCallout, ""] : []
        lines.append("> [!summary] Summary")
        lines += Self.bullets(from: overview).map { "> - \($0)" }
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
    /// The 📅 date works with the Obsidian Tasks plugin. It's only there when
    /// a real day can be worked out from what was said: a phrase Warble can't
    /// turn into a date, or a timestamp, is left out rather than guessed.
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
        if !item.due.isEmpty, let date = dueDate(item.due, from: callDate, calendar: calendar) {
            line += " 📅 " + dayFormatter(calendar).string(from: date)
        }
        return line
    }

    /// The summary as bullet points, which are easier to skim. Claude writes
    /// one point per line; otherwise each sentence becomes a point.
    static func bullets(from overview: String) -> [String] {
        let text = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let pieces = text.contains("\n")
            ? text.components(separatedBy: "\n")
            : ActionSpotter.sentences(in: text, keepShort: true)
        return pieces.map(CallSummariser.clean).filter { !$0.isEmpty }
    }

    /// Prefixes every line for an Obsidian callout.
    static func quoted(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
    }

    // MARK: - Due dates

    /// Turns what was said about timing into a day, counted from the day of
    /// the call (never from today, so a summary written later is still right):
    /// "today", "close of play", "tomorrow", "by Friday", "end of the week",
    /// "next week", "end of the month", "by the 14th", "7 November", or
    /// Claude's 2026-11-07. Nil when it can't tell: Warble never guesses a date.
    static func dueDate(_ phrase: String, from callDate: Date, calendar: Calendar = .current) -> Date? {
        let text = phrase.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()[].,;:"))
        guard !text.isEmpty else { return nil }
        // A transcript timestamp such as 18:15 is not a due date.
        if text.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil { return nil }
        let day = calendar.startOfDay(for: callDate)
        func plus(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: day) }
        func words(_ list: [String]) -> Bool {
            list.contains { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
        }

        // Claude gives an exact day as 2026-11-04.
        if let match = text.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) {
            let f = dayFormatter(calendar)
            if let date = f.date(from: String(text[match])) { return date }
        }
        if words(["tomorrow"]) { return plus(1) }

        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let today = calendar.component(.weekday, from: day) // 1 = Sunday
        func next(_ weekday: Int, allowToday: Bool) -> Date? {
            var ahead = (weekday - today + 7) % 7
            if ahead == 0 && !allowToday { ahead = 7 }
            return plus(ahead)
        }
        // A named day wins: "close of play on Wednesday" is Wednesday.
        if let index = weekdays.firstIndex(where: { words([$0]) }) { return next(index + 1, allowToday: false) }
        // "Next week" means by the Friday of next week.
        if words(["next week"]) {
            return next(2, allowToday: false).flatMap { calendar.date(byAdding: .day, value: 4, to: $0) }
        }
        if words(["end of the week", "end of week", "eow", "this week"]) { return next(6, allowToday: true) }
        if words(["end of the month", "end of month", "eom", "this month"]) {
            guard let month = calendar.dateInterval(of: .month, for: day) else { return nil }
            return calendar.date(byAdding: .day, value: -1, to: month.end).map { calendar.startOfDay(for: $0) }
        }
        if words(["today", "tonight", "this morning", "this afternoon", "this evening", "later today",
                  "end of day", "end of the day", "eod", "close of play", "end of play",
                  "cop", "closer play", "close a play", "close of business", "end of business", "cob", "eob"]) { return day }

        // "7 November", "7th Nov", "November 7", "Nov. 7th"
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let monthPattern = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?"
        func onOrAfterCallDay(month: Int, day dayNumber: Int) -> Date? {
            var parts = calendar.dateComponents([.year], from: day)
            parts.month = month
            parts.day = dayNumber
            guard let date = calendar.date(from: parts),
                  calendar.component(.day, from: date) == dayNumber else { return nil }
            // A date that has already passed means next year.
            return date < day ? calendar.date(byAdding: .year, value: 1, to: date) : date
        }
        let patterns = ["\\b(\\d{1,2})(?:st|nd|rd|th)?(?: of)? \(monthPattern)(?![a-z])",
                        "\\b\(monthPattern) (?:the )?(\\d{1,2})(?:st|nd|rd|th)?\\b"]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let first = Range(match.range(at: 1), in: text),
                  let second = Range(match.range(at: 2), in: text) else { continue }
            let dayText = index == 0 ? text[first] : text[second]
            let monthText = index == 0 ? text[second] : text[first]
            guard let dayNumber = Int(dayText), let month = months.firstIndex(of: String(monthText.prefix(3))) else { continue }
            if let date = onOrAfterCallDay(month: month + 1, day: dayNumber) { return date }
        }

        // "By the 14th": the next 14th, this month or next.
        let ordinals = [#"\bthe (\d{1,2})(?:st|nd|rd|th)?\b"#, #"\b(\d{1,2})(?:st|nd|rd|th)\b"#]
        for pattern in ordinals {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let dayNumber = Int(text[range]), (1...31).contains(dayNumber) else { continue }
            for monthsAhead in 0...2 {
                guard let month = calendar.date(byAdding: .month, value: monthsAhead, to: day) else { continue }
                var parts = calendar.dateComponents([.year, .month], from: month)
                parts.day = dayNumber
                guard let date = calendar.date(from: parts),
                      calendar.component(.day, from: date) == dayNumber, date >= day else { continue }
                return date
            }
            return nil
        }

        // Anything else that names a month, e.g. "November the 14th": let
        // macOS read it, but take only the month and day from its answer.
        if text.range(of: "\\b" + monthPattern, options: .regularExpression) != nil,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let found = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date {
            var local = Calendar.current
            local.timeZone = .autoupdatingCurrent
            let parts = local.dateComponents([.month, .day], from: found)
            if let month = parts.month, let dayNumber = parts.day {
                return onOrAfterCallDay(month: month, day: dayNumber)
            }
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
        for item in parts.flatMap(\.actionItems) { CallSummariser.add(item, to: &actions) }
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

    /// The same chunks, each starting with the last tenth or so of the one
    /// before it, so a task said across the join isn't cut in two.
    static func withOverlap(_ chunks: [Chunk], fraction: Double = 0.1) -> [Chunk] {
        guard chunks.count > 1 else { return chunks }
        var result = [chunks[0]]
        for index in 1..<chunks.count {
            let previous = chunks[index - 1]
            var carried: [String] = []
            var words = 0
            let wanted = max(1, Int((Double(previous.words) * fraction).rounded()))
            for line in previous.lines.reversed() where words < wanted && carried.count < previous.lines.count - 1 {
                carried.insert(line, at: 0)
                words += wordCount(parse(line)?.text ?? line)
            }
            var chunk = chunks[index]
            if !carried.isEmpty {
                chunk.lines = carried + chunk.lines
                chunk.words += words
                chunk.start = carried.first.flatMap { parse($0)?.offset } ?? chunk.start
            }
            result.append(chunk)
        }
        return result
    }

    /// "Sarah Jones (07:40): what she said" taken apart, or nil.
    static func parse(_ line: String) -> (speaker: String, offset: TimeInterval, text: String)? {
        guard let regex = lineRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let speaker = Range(match.range(at: 1), in: line),
              let time = Range(match.range(at: 2), in: line),
              let text = Range(match.range(at: 3), in: line),
              let seconds = Self.offset(fromTimestamp: String(line[time])) else { return nil }
        return (String(line[speaker]), seconds, String(line[text]))
    }

    private static let lineRegex = try? NSRegularExpression(pattern: #"^(.*?) \((\d{1,2}:\d{2}(?::\d{2})?)\): (.*)$"#,
                                                            options: [.dotMatchesLineSeparators])

    /// "07:40" or "1:07:40" as seconds.
    static func offset(fromTimestamp text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]")).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ (0..<60).contains($0) }) else { return nil }
        return TimeInterval(numbers.reduce(0) { $0 * 60 + $1 })
    }
}

extension SummaryChunker.Chunk {
    /// The chunk cut in two by lines, for when it's too long for the model after all.
    var halves: [SummaryChunker.Chunk] {
        guard lines.count > 1 else { return [self] }
        let half = lines.count / 2
        return [Array(lines[..<half]), Array(lines[half...])].map { part in
            let start = SummaryChunker.parse(part[0])?.offset ?? self.start
            let end = part.last.flatMap { SummaryChunker.parse($0)?.offset } ?? self.end
            return SummaryChunker.Chunk(start: start, end: end, lines: part,
                                        words: SummaryChunker.wordCount(part.joined(separator: " ")))
        }
    }
}
