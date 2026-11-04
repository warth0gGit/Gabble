import Foundation

/// A call note boiled down to what you'd send someone: the meeting's name,
/// when it was, who was on, the summary, the actions and the transcript, with
/// none of the Obsidian extras (front matter, callouts, [[links]]). Read from
/// the saved note, so it includes any summary Claude added later and any
/// edits you made. Pure, unit tested.
struct SharedCall: Equatable {
    struct Action: Equatable {
        var owner: String
        var task: String
        var due: Date?
    }

    struct Line: Equatable {
        var speaker: String
        var time: String
        var text: String
    }

    var name: String
    var started: Date?
    var ended: Date?
    var minutes: Int?
    var people: [String] = []
    var summary: [String] = []
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actions: [Action] = []
    var transcript: [Line] = []

    /// What to put in the PDF.
    struct Options: Equatable {
        var summary = true
        var actions = false
        var transcript = true
    }

    /// - Parameters:
    ///   - note: the saved Markdown note.
    ///   - me: your name, used in place of "Me".
    static func parse(note: String, me: String) -> SharedCall {
        let me = me.trimmingCharacters(in: .whitespacesAndNewlines)
        func person(_ name: String) -> String {
            let plain = plainText(name)
            return plain == "Me" && !me.isEmpty ? me : plain
        }

        var lines = note.components(separatedBy: "\n")
        var front: [String] = []
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            front = Array(lines[1..<close])
            lines = Array(lines[(close + 1)...])
        }
        func value(_ key: String) -> String? {
            guard let line = front.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
            return unquote(String(line.dropFirst(key.count + 1)))
        }

        var call = SharedCall(name: "")
        call.started = value("date").flatMap { CallTranscript.isoFormatter.date(from: $0) }
        call.ended = value("ended").flatMap { CallTranscript.isoFormatter.date(from: $0) }
        call.minutes = value("duration_minutes").flatMap { Int($0) }

        let heading = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        call.name = meetingName(heading ?? value("title") ?? "Call")

        var others: [String] = []
        if let with = lines.first(where: { $0.hasPrefix("With ") }) {
            others = links(in: String(with.dropFirst(5)))
            if others.isEmpty { others = with.dropFirst(5).components(separatedBy: ", ") }
        } else if let people = value("people") {
            others = links(in: people)
        }
        others = others.map(plainText).filter { !$0.isEmpty }
        if !me.isEmpty, !others.contains(where: { $0.caseInsensitiveCompare(me) == .orderedSame }) {
            call.people = [me] + others
        } else {
            call.people = others
        }

        enum Part { case none, summary, skip, keyPoints, decisions, actions, other, transcript }
        var part = Part.none
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let quoted = line.hasPrefix(">")
            let inner = quoted ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line

            if line.hasPrefix("## ") {
                switch line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() {
                case "key points": part = .keyPoints
                case "decisions": part = .decisions
                case "action items": part = .actions
                case "transcript": part = .transcript
                default: part = .other
                }
                continue
            }
            if quoted, inner.hasPrefix("[!") {
                let kind = inner.lowercased()
                if kind.hasPrefix("[!summary] summary on its way") { part = .skip }
                else if kind.hasPrefix("[!summary]") { part = .summary }
                else if kind.hasPrefix("[!quote]") { part = .transcript }
                else { part = .skip }
                continue
            }
            if !quoted, part == .summary || part == .skip, !line.isEmpty { part = .none }

            if let spoken = transcriptLine(inner) {
                if part == .transcript || part == .none || !quoted {
                    call.transcript.append(Line(speaker: person(spoken.speaker), time: spoken.time, text: spoken.text))
                }
                continue
            }
            guard inner.hasPrefix("- ") else { continue }
            let item = String(inner.dropFirst(2))
            switch part {
            case .summary where quoted: call.summary.append(plainText(item))
            case .keyPoints: call.keyPoints.append(plainText(item))
            case .decisions: call.decisions.append(plainText(item))
            case .actions:
                if var action = action(from: item) {
                    action.owner = action.owner.isEmpty ? "" : person(action.owner)
                    call.actions.append(action)
                }
            default: break
            }
        }
        return call
    }

    // MARK: - Pieces

    /// "Orchestrate review, Nov 4, 2026, 2:00 PM" → "Orchestrate review" (the
    /// date has its own line in the PDF).
    static func meetingName(_ title: String) -> String {
        let pattern = #",?\s+[A-Z][a-z]{2} \d{1,2}, \d{4}, \d{1,2}:\d{2}\s?[AP]M$"#
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: pattern, options: .regularExpression) else { return trimmed }
        let name = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? trimmed : name
    }

    /// "**Sarah** (01:02): Hello" → ("Sarah", "01:02", "Hello").
    static func transcriptLine(_ line: String) -> (speaker: String, time: String, text: String)? {
        let pattern = #"^\*\*(.+?)\*\* \((\d{1,2}:\d{2}(?::\d{2})?)\): (.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let speaker = Range(match.range(at: 1), in: line),
              let time = Range(match.range(at: 2), in: line),
              let text = Range(match.range(at: 3), in: line) else { return nil }
        return (String(line[speaker]), String(line[time]), String(line[text]))
    }

    /// "[ ] **[[Sarah Jones]]**: send the deck 📅 2026-11-07".
    static func action(from item: String) -> Action? {
        var text = item
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) { text = String(text.dropFirst(box.count)) }
        var due: Date?
        if let mark = text.range(of: "📅") {
            let day = text[mark.upperBound...].trimmingCharacters(in: .whitespaces).prefix(10)
            due = dayFormatter.date(from: String(day))
            text = String(text[..<mark.lowerBound])
        }
        var owner = ""
        if text.hasPrefix("**"), let close = text.range(of: "**:", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
            owner = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
            text = String(text[close.upperBound...])
        }
        let task = plainText(text)
        return task.isEmpty ? nil : Action(owner: owner, task: task, due: due)
    }

    /// Without Obsidian's [[links]] and Markdown emphasis.
    static func plainText(_ text: String) -> String {
        var result = text
        // [[Note|Shown]] → Shown, [[Note]] → Note
        result = result.replacingOccurrences(of: #"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func links(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func unquote(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return v
    }

    // MARK: - Wording

    /// "Wednesday, November 4, 2026 · 2:00 – 2:31 PM (31 min)".
    var when: String? {
        guard let started else { return nil }
        var text = Self.longDay.string(from: started) + " · " + Self.clock.string(from: started)
        if let ended { text += " – " + Self.clock.string(from: ended) }
        if let minutes, minutes > 0 { text += " (\(minutes) min)" }
        return text
    }

    /// "Sarah Jones: send the deck (due Fri, Nov 7)".
    static func describe(_ action: Action) -> String {
        var text = action.owner.isEmpty ? action.task : "\(action.owner): \(action.task)"
        if let due = action.due { text += " (due \(shortDay.string(from: due)))" }
        return text
    }

    /// A file name for the PDF, e.g. "2026-11-04 Orchestrate review.pdf".
    var fileName: String {
        let day = started.map { Self.dayFormatter.string(from: $0) + " " } ?? ""
        let safe = FolderName.fileName(name).trimmingCharacters(in: .whitespaces)
        return day + String((safe.isEmpty ? "Call" : safe).prefix(80)) + ".pdf"
    }

    static let dayFormatter: DateFormatter = formatter("yyyy-MM-dd")
    private static let longDay: DateFormatter = formatter("EEEE, MMMM d, yyyy")
    private static let shortDay: DateFormatter = formatter("EEE, MMM d")
    private static let clock: DateFormatter = formatter("h:mm a")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = format
        return f
    }
}
