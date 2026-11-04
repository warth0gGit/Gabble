import Foundation

/// Calls whose summary Apple Intelligence wrote only because Claude couldn't
/// answer at the time (usage limit, offline, signed out). Warble asks Claude
/// again later and, when it answers, replaces Apple's draft in the note.
///
/// Tries: when Warble opens, then 30 minutes, 1, 2 and 4 hours after the call,
/// then every 6 hours, for up to 3 days. Never while you're on a recorded call
/// or dictating. Kept in Application Support/Warble/summary-queue.json, so the
/// list survives quitting Warble.
@MainActor
final class SummaryQueue: ObservableObject {
    /// A call waiting for Claude: everything needed to ask again and find its note.
    struct Entry: Codable, Equatable, Identifiable {
        struct Line: Codable, Equatable {
            var offset: TimeInterval
            var speaker: String
            var text: String
        }

        var id = UUID()
        var appName: String
        var started: Date
        var ended: Date?
        var lines: [Line]
        /// Everyone on the call by name, for the links in the action items.
        var people: [String]
        var terms: [String]
        /// The note's "date: …" front matter line, which no rename or move changes.
        var dateLine: String
        /// Where the note was when the call was queued.
        var path: String
        var queuedAt: Date
        var attempts = 0
        var nextAttempt: Date
        var lastProblem: String?

        init(_ transcript: CallTranscript, terms: [String], savedAt url: URL, problem: String?, now: Date = Date()) {
            appName = transcript.appName
            started = transcript.started
            ended = transcript.ended
            lines = transcript.segments.map { Line(offset: $0.offset, speaker: $0.speaker, text: $0.text) }
            people = transcript.people
            self.terms = terms
            dateLine = SummaryQueue.dateLine(for: transcript.started)
            path = url.path
            queuedAt = now
            nextAttempt = now.addingTimeInterval(SummaryQueue.delay(afterAttempts: 0))
            lastProblem = problem
        }

        /// The call again, ready to send to Claude.
        var transcript: CallTranscript {
            var call = CallTranscript(appName: appName, started: started, ended: ended)
            call.segments = lines.map { CallTranscript.Segment(offset: $0.offset, speaker: $0.speaker, text: $0.text) }
            return call
        }

        var minutes: Int {
            max(1, Int((((ended ?? started).timeIntervalSince(started)) / 60).rounded()))
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// Asking Claude now.
    @Published private(set) var isRetrying = false

    /// True while you're on a recorded call or dictating: Warble waits.
    var isBusy: @MainActor () -> Bool = { false }
    /// Where call notes live (the Calls folder).
    var callsFolder: @MainActor () -> URL = { URL(fileURLWithPath: NSTemporaryDirectory()) }
    /// Asks Claude for a summary (replaced in tests).
    var askClaude: @Sendable (CallTranscript, [String]) async -> Result<CallSummary, CleanupFailure> = { call, terms in
        await ClaudeSummariser.summarise(call, terms: terms)
    }
    /// Called after a note's draft is replaced with Claude's summary.
    var onReplaced: @MainActor (Entry, CallSummary) -> Void = { _, _ in }

    private let fileURL: URL
    private var loop: Task<Void, Never>?
    /// "Retry now" was pressed while you were busy: try as soon as you're free.
    private var forceNext = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = support.appendingPathComponent("Warble", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("summary-queue.json")
        }
        load()
    }

    // MARK: - Schedule (pure, unit tested)

    /// Give up asking Claude after this long.
    nonisolated static let lifetime: TimeInterval = 3 * 24 * 3600

    /// How long to wait before the next try, after `attempts` failed tries.
    nonisolated static func delay(afterAttempts attempts: Int) -> TimeInterval {
        let steps: [TimeInterval] = [30 * 60, 3600, 2 * 3600, 4 * 3600]
        return attempts < steps.count ? steps[attempts] : 6 * 3600
    }

    nonisolated static func dateLine(for started: Date) -> String {
        "date: \(CallTranscript.isoFormatter.string(from: started))"
    }

    /// The next try in the list, for Settings.
    var nextAttempt: Date? { entries.map(\.nextAttempt).min() }
    var lastProblem: String? { entries.compactMap(\.lastProblem).last }

    // MARK: - Running

    /// Starts the timer, with a first try a minute after Warble opens.
    func start() {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.tick(forced: true)
            while !Task.isCancelled, self != nil {
                try? await Task.sleep(for: .seconds(5 * 60))
                await self?.tick(forced: false)
            }
        }
    }

    /// Adds a call whose summary is Apple's draft.
    func add(_ transcript: CallTranscript, terms: [String], savedAt url: URL, problem: String?) {
        let entry = Entry(transcript, terms: terms, savedAt: url, problem: problem)
        entries.removeAll { $0.started == entry.started && $0.appName == entry.appName }
        entries.append(entry)
        save()
    }

    /// "Retry now" in Settings: every waiting call, straight away.
    func retryNow() {
        Task { await tick(forced: true) }
    }

    /// Tries the calls that are due (or all of them, if forced). A forced try
    /// that fails doesn't push the next scheduled one back.
    func tick(forced: Bool, now: Date = Date()) async {
        let forced = forced || forceNext
        guard !isRetrying, !entries.isEmpty else { return }
        guard !isBusy() else {
            if forced { forceNext = true }
            return
        }
        guard ClaudeSummariser.engine == .claude else { return }
        forceNext = false

        let expired = entries.filter { now.timeIntervalSince($0.queuedAt) > Self.lifetime }
        if !expired.isEmpty {
            entries.removeAll { entry in expired.contains { $0.id == entry.id } }
            save()
        }
        let due = entries.filter { forced || $0.nextAttempt <= now }
        guard !due.isEmpty else { return }

        isRetrying = true
        defer { isRetrying = false }
        for (index, entry) in due.enumerated() {
            guard !isBusy() else { break }   // a call or dictation started: later
            guard let note = locate(entry) else {
                // The note was deleted: nothing to replace.
                remove(entry)
                continue
            }
            let call = entry.transcript
            let terms = entry.terms
            let ask = askClaude
            let result = await Task.detached(priority: .utility) { await ask(call, terms) }.value
            switch result {
            case .success(let summary):
                if replace(entry, in: note, with: summary) {
                    remove(entry)
                    onReplaced(entry, summary)
                } else {
                    failed([entry], problem: "Warble couldn't update the note.", forced: forced, now: now)
                }
            case .failure(let problem):
                // Most likely the same for every call (a usage limit), so wait on all of them.
                failed(Array(due[index...]), problem: problem.reason, forced: forced, now: now)
                return
            }
        }
    }

    private func failed(_ failed: [Entry], problem: String, forced: Bool, now: Date) {
        for entry in failed {
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
            entries[index].lastProblem = problem
            if !forced {
                entries[index].attempts += 1
                entries[index].nextAttempt = now.addingTimeInterval(Self.delay(afterAttempts: entries[index].attempts))
            }
        }
        save()
    }

    private func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func replace(_ entry: Entry, in note: URL, with summary: CallSummary) -> Bool {
        guard let text = try? String(contentsOf: note, encoding: .utf8),
              let updated = NoteRewriter.replacingSummary(
                in: text, with: summary, people: entry.people, callDate: entry.started, minutes: entry.minutes,
                words: SummaryChunker.wordCount(entry.lines.map(\.text).joined(separator: "\n"))) else { return false }
        return (try? updated.write(to: note, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - Finding the note

    /// Where the note is now. Filing moves it and renaming changes its name, so
    /// it's found by its path, then its file name, then its "date:" line in
    /// notes from the same minute.
    func locate(_ entry: Entry) -> URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: entry.path), hasDateLine(URL(fileURLWithPath: entry.path), entry.dateLine) {
            return URL(fileURLWithPath: entry.path)
        }
        let name = URL(fileURLWithPath: entry.path).lastPathComponent
        let prefix = String(name.prefix(15))   // "2026-11-04 1430"
        guard let enumerator = manager.enumerator(at: callsFolder(), includingPropertiesForKeys: nil) else { return nil }
        let notes = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
        if let same = notes.first(where: { $0.lastPathComponent == name && hasDateLine($0, entry.dateLine) }) {
            return same
        }
        return notes.first { $0.lastPathComponent.hasPrefix(prefix) && hasDateLine($0, entry.dateLine) }
    }

    private func hasDateLine(_ url: URL, _ line: String) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return NoteRewriter.frontMatter(of: text).contains(line)
    }

    // MARK: - Saving

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        entries = (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Puts Claude's summary in place of Apple's draft (or the "No summary"
/// note) in a saved call note, leaving everything else as it is: the file
/// name, folder, your own edits, and the front matter apart from the summary
/// lines. Pure, unit tested.
enum NoteRewriter {
    static let transcriptCallout = "> [!quote]- Full transcript"

    /// The note with the new summary, or nil if the note isn't laid out as
    /// Warble wrote it (so nothing is changed).
    static func replacingSummary(in note: String, with summary: CallSummary, people: [String], callDate: Date,
                                 minutes: Int, words: Int) -> String? {
        var lines = note.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return nil }

        // Front matter: the summary lines, nothing else.
        var front = Array(lines[1..<close]).filter {
            !$0.hasPrefix("summary:") && !$0.hasPrefix("summarized_by:") && !$0.hasPrefix("summary_status:")
        }
        var added: [String] = []
        if !summary.headline.isEmpty { added.append("summary: \(CallTranscript.yamlValue(summary.headline))") }
        added.append("summarized_by: \(CallTranscript.yamlValue(summary.writer))")
        if summary.provisional { added.append(CallSummary.provisionalStatus) }
        let at = front.firstIndex { $0.hasPrefix("tags:") } ?? front.count
        front.insert(contentsOf: added, at: at)

        // Body: Warble's summary sections, from the first callout to the transcript.
        let body = Array(lines[(close + 1)...])
        guard let start = body.firstIndex(where: {
            $0 == CallSummary.draftCallout || $0.hasPrefix("> [!summary]") || $0.hasPrefix("> [!warning] No summary")
        }) else { return nil }
        guard let end = body[start...].firstIndex(where: { $0.hasPrefix(transcriptCallout) || $0 == "## Transcript" })
        else { return nil }

        var transcript: [String]
        if body[end] == "## Transcript" {
            // Written before there was a summary: fold the transcript away as a finished note does.
            var turns: [String] = []
            var index = end + 1
            while index < body.count, body[index].isEmpty || body[index].hasPrefix("**") {
                if !body[index].isEmpty { turns.append(body[index]) }
                index += 1
            }
            transcript = ["\(transcriptCallout) (\(minutes) min, \(countFormatter.string(from: NSNumber(value: words)) ?? "\(words)") words)"]
            for (n, turn) in turns.enumerated() {
                if n > 0 { transcript.append(">") }
                transcript.append("> " + corrected(turn, summary.corrections))
            }
            transcript.append("")
            transcript += body[index...]
        } else {
            transcript = body[end...].map { line in
                line.hasPrefix("> **") ? corrected(line, summary.corrections) : line
            }
        }

        lines = ["---"] + front + ["---"] + Array(body[..<start])
            + summary.markdownLines(people: people, callDate: callDate) + transcript
        return lines.joined(separator: "\n")
    }

    /// The front matter lines of a note.
    static func frontMatter(of note: String) -> [String] {
        let lines = note.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return [] }
        return Array(lines[1..<close])
    }

    /// Misheard words fixed in what was said, not in the speaker's name.
    private static func corrected(_ line: String, _ corrections: [CallSummary.Correction]) -> String {
        guard !corrections.isEmpty, let split = line.range(of: "): ") else { return line }
        return String(line[..<split.upperBound]) + CallTranscript.applying(corrections, to: String(line[split.upperBound...]))
    }

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f
    }()
}
