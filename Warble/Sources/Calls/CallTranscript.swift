import Foundation

/// A finished or in-progress call transcript. Pure data, unit tested.
struct CallTranscript: Equatable {
    struct Segment: Equatable {
        var offset: TimeInterval   // seconds since the call started
        var speaker: String
        var text: String
        /// Exactly when it was spoken, if known (Parakeet's re-read of the recording gives this).
        var spoken: ClosedRange<TimeInterval>? = nil
    }

    var appName: String
    var started: Date
    var ended: Date?
    var segments: [Segment] = []
    var category: String = "Unfiled"
    /// The calendar meeting this call was, if Warble could tell.
    var meeting: MeetingInfo?
    /// The friendly summary at the top of the note, once Apple Intelligence has written it.
    var summary: CallSummaryState = .none

    /// Labels that aren't real names.
    static func isPlaceholder(_ speaker: String) -> Bool {
        speaker == "Me" || speaker == "Others" || speaker.hasPrefix("Speaker ")
    }

    /// Everyone else on the call by name: invitees and recognised voices.
    var people: [String] {
        var names: [String] = []
        for name in (meeting?.attendees.map(\.name) ?? []) + speakers where !Self.isPlaceholder(name) {
            if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        }
        return names
    }

    var speakers: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }

    var plainText: String { segments.map(\.text).joined(separator: "\n") }

    /// Adds a phrase as it is recognised. Phrases are kept separate so each can
    /// be matched to the right voice later; they are merged when rendered.
    mutating func add(speaker: String, text: String, at date: Date) {
        let offset = max(0, date.timeIntervalSince(started))
        segments.append(Segment(offset: offset, speaker: speaker, text: text))
    }

    /// Roughly when a phrase was spoken. Phrases are reported just after they
    /// finish, so they span a little before their offset.
    static func spokenRange(of segment: Segment) -> ClosedRange<TimeInterval> {
        if let spoken = segment.spoken { return spoken }
        let words = Double(segment.text.split(separator: " ").count)
        let end = max(0, segment.offset - 0.8)
        let start = max(0, end - max(1.0, words * 0.38))
        return start...max(start, end)
    }

    /// Segments sorted by time, so lines from both sides interleave correctly.
    var ordered: [Segment] { segments.sorted { $0.offset < $1.offset } }

    /// Consecutive phrases from the same person joined into one line.
    var merged: [Segment] {
        var result: [Segment] = []
        for segment in ordered {
            if let last = result.last, last.speaker == segment.speaker, segment.offset - last.offset < 45 {
                result[result.count - 1].text += " " + segment.text
            } else {
                result.append(segment)
            }
        }
        return result
    }

    /// Fixes words speech recognition misheard, e.g. "closer play" to "close
    /// of play". Whole words only, ignoring case.
    mutating func apply(_ corrections: [CallSummary.Correction]) {
        for fix in corrections {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: fix.heard) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: fix.meant)
            segments = segments.map { segment in
                var s = segment
                s.text = regex.stringByReplacingMatches(in: s.text, range: NSRange(s.text.startIndex..., in: s.text),
                                                        withTemplate: template)
                return s
            }
        }
    }

    /// Renames speakers, e.g. "Others" phrases to the person recognised by voice.
    mutating func relabel(_ label: (Segment) -> String) {
        segments = segments.map { segment in
            var s = segment
            s.speaker = label(segment)
            return s
        }
    }

    var title: String {
        if let name = meeting?.title, !name.isEmpty {
            return "\(name), \(Self.titleFormatter.string(from: started))"
        }
        return "\(shortAppName) call \(Self.titleFormatter.string(from: started))"
    }

    var shortAppName: String {
        appName.replacingOccurrences(of: "Microsoft ", with: "").replacingOccurrences(of: "Google ", with: "")
    }

    /// File name, safe for every file system, e.g. "2026-10-31 1400 Teams call.md".
    var fileName: String {
        let name = meeting.map { FolderName.fileName($0.title) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(shortAppName) call"
        return "\(Self.fileFormatter.string(from: started)) \(String(name.prefix(80))).md"
    }

    /// An Obsidian link to a person's note, e.g. [[Sarah Jones]].
    static func link(_ name: String) -> String {
        "[[\(FolderName.fileName(name))]]"
    }

    /// Markdown with YAML front matter, ready for Obsidian.
    var markdown: String {
        var lines: [String] = ["---"]
        lines.append("title: \(yaml(title))")
        lines.append("date: \(Self.isoFormatter.string(from: started))")
        if let ended { lines.append("ended: \(Self.isoFormatter.string(from: ended))") }
        lines.append("duration_minutes: \(Int((duration / 60).rounded()))")
        lines.append("app: \(yaml(appName))")
        lines.append("speakers: [\(speakers.map(yaml).joined(separator: ", "))]")
        if !people.isEmpty {
            lines.append("people: [\(people.map { "\"\(Self.link($0))\"" }.joined(separator: ", "))]")
        }
        if let meeting {
            lines.append("meeting: \(yaml(meeting.title))")
            if let organizer = meeting.organizer { lines.append("organizer: \(yaml(organizer))") }
        }
        lines.append("category: \(yaml(category))")
        if let summary = summary.summary {
            if !summary.headline.isEmpty { lines.append("summary: \(yaml(summary.headline))") }
            lines.append("summarized_by: \(yaml(summary.writer))")
        }
        lines.append("tags: [\((["call", "warble"] + (meeting?.seriesID != nil ? ["recurring"] : [])).joined(separator: ", "))]")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        lines.append("")
        if !people.isEmpty {
            lines.append("With " + people.map(Self.link).joined(separator: ", "))
            lines.append("")
        }
        let transcriptLines = merged.map { "**\($0.speaker)** (\(Self.timestamp($0.offset))): \($0.text)" }
        switch summary {
        case .none:
            for line in transcriptLines { lines += [line, ""] }
        case .pending:
            lines.append("> [!summary] Summary on its way")
            lines.append("> A summary and action items are being written. They will appear here in a minute or two.")
            lines.append("")
            lines += ["## Transcript", ""]
            for line in transcriptLines { lines += [line, ""] }
        case .failed(let reason):
            lines.append("> [!warning] No summary")
            lines.append("> Warble couldn't write a summary of this call: \(reason)")
            lines.append("")
            lines += ["## Transcript", ""]
            for line in transcriptLines { lines += [line, ""] }
        case .done(let summary):
            lines += summary.markdownLines(people: people, callDate: started)
            // The full transcript, folded away at the bottom (click to open it in Obsidian).
            let words = SummaryChunker.wordCount(plainText)
            let minutes = max(1, Int((duration / 60).rounded()))
            lines.append("> [!quote]- Full transcript (\(minutes) min, \(Self.countFormatter.string(from: NSNumber(value: words)) ?? "\(words)") words)")
            for (index, line) in transcriptLines.enumerated() {
                if index > 0 { lines.append(">") }
                lines.append("> " + line)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ offset: TimeInterval) -> String {
        let total = Int(offset)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func yaml(_ value: String) -> String {
        let needsQuotes = value.contains { ":#[]{},&*!|>'\"%@`".contains($0) } || value.hasPrefix(" ")
        return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : value
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "MMM d, yyyy, h:mm a"
        return f
    }()

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f
    }()

    /// The Mac's current time zone (e.g. 2026-10-31T20:55:01), never UTC. It
    /// follows the Mac's clock when you travel, even if Warble stays open. Obsidian
    /// reads this as a date and time and shows it as you'd expect.
    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}
