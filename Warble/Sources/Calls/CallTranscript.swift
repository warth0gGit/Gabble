import Foundation

/// A finished or in-progress call transcript. Pure data, unit tested.
struct CallTranscript: Equatable {
    struct Segment: Equatable {
        var offset: TimeInterval   // seconds since the call started
        var speaker: String
        var text: String
    }

    var appName: String
    var started: Date
    var ended: Date?
    var segments: [Segment] = []
    var category: String = "Unfiled"

    var speakers: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }

    var plainText: String { segments.map(\.text).joined(separator: "\n") }

    mutating func add(speaker: String, text: String, at date: Date) {
        let offset = max(0, date.timeIntervalSince(started))
        // Merge with the previous line if the same person is still talking.
        if let last = segments.last, last.speaker == speaker, offset - last.offset < 30 {
            segments[segments.count - 1].text += " " + text
        } else {
            segments.append(Segment(offset: offset, speaker: speaker, text: text))
        }
    }

    /// Segments sorted by time, so lines from both sides interleave correctly.
    var ordered: [Segment] { segments.sorted { $0.offset < $1.offset } }

    var title: String {
        "\(shortAppName) call \(Self.titleFormatter.string(from: started))"
    }

    var shortAppName: String {
        appName.replacingOccurrences(of: "Microsoft ", with: "").replacingOccurrences(of: "Google ", with: "")
    }

    /// File name, safe for every file system, e.g. "2026-10-31 1400 Teams call.md".
    var fileName: String {
        "\(Self.fileFormatter.string(from: started)) \(shortAppName) call.md"
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
        lines.append("category: \(yaml(category))")
        lines.append("tags: [call, warble]")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        lines.append("")
        for segment in ordered {
            lines.append("**\(segment.speaker)** (\(Self.timestamp(segment.offset))): \(segment.text)")
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
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
