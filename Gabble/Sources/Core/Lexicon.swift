import Foundation

/// One word or phrase in the user's personal lexicon (acronyms, jargon, names).
struct LexiconEntry: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case manual             // typed or imported by the user
        case correction         // learned when the user fixed a dictation mistake
        case harvested          // spotted in transcripts or documents
    }

    enum State: String, Codable {
        case confirmed          // used to steer recognition and cleanup
        case suggested          // waiting for the user to approve or dismiss
    }

    var id: UUID = UUID()
    /// How it should be written, e.g. "SaaS", "watsonx", "Q3 OKRs".
    var term: String
    /// How it tends to be heard or misheard, e.g. "sass", "what's an x".
    var soundsLike: [String] = []
    /// Optional expansion or note, e.g. "Software as a Service".
    var meaning: String = ""
    var source: Source = .manual
    var state: State = .confirmed
    var timesSeen: Int = 1
    var added: Date = Date()
}

/// Pure text helpers for growing the lexicon automatically. Kept free of UI and
/// storage so they can be unit tested.
enum LexiconLearner {
    /// Common all-caps words that are not worth suggesting.
    static let ignoredAcronyms: Set<String> = [
        "I", "A", "OK", "AM", "PM", "TV", "US", "UK", "EU", "FYI", "ASAP", "ID", "PS"
    ]

    /// Finds acronyms (KPI, Q3, O365) and mixed-case product words (SharePoint,
    /// iPhone, watsonX) in a block of text. Returns them with how often each appears.
    static func candidateTerms(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "&" })
        for raw in tokens {
            let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "-&"))
            guard token.count >= 2, token.count <= 20 else { continue }
            if isAcronym(token) || isMixedCase(token) {
                guard !ignoredAcronyms.contains(token) else { continue }
                counts[token, default: 0] += 1
            }
        }
        return counts
    }

    static func isAcronym(_ token: String) -> Bool {
        guard token.count <= 8 else { return false }
        let letters = token.filter(\.isLetter)
        guard letters.count >= 2 || (letters.count == 1 && token.count >= 2) else { return false }
        return letters.allSatisfy(\.isUppercase)
    }

    static func isMixedCase(_ token: String) -> Bool {
        let letters = Array(token.filter(\.isLetter))
        guard letters.count >= 3 else { return false }
        // An uppercase letter after the first character: SharePoint, iPhone, watsonX.
        let innerUpper = letters.dropFirst().contains(where: \.isUppercase)
        let hasLower = letters.contains(where: \.isLowercase)
        return innerUpper && hasLower
    }

    /// Compares what Gabble typed with what the user changed it to, and returns
    /// (heard, corrected) pairs worth remembering, e.g. ("sass", "SaaS").
    static func corrections(original: String, edited: String) -> [(heard: String, corrected: String)] {
        let a = original.split(separator: " ").map(String.init)
        let b = edited.split(separator: " ").map(String.init)
        let diff = b.difference(from: a)

        var removed: [Int: String] = [:]
        var inserted: [Int: String] = [:]
        for change in diff {
            switch change {
            case let .remove(offset, element, _): removed[offset] = element
            case let .insert(offset, element, _): inserted[offset] = element
            }
        }

        // Pair up runs of removed words with runs of inserted words at the same spot.
        var pairs: [(String, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, removed[i] == nil, inserted[j] == nil {
                i += 1; j += 1; continue
            }
            var heard: [String] = []
            var fixed: [String] = []
            while i < a.count, removed[i] != nil { heard.append(a[i]); i += 1 }
            while j < b.count, inserted[j] != nil { fixed.append(b[j]); j += 1 }
            if heard.isEmpty && fixed.isEmpty { i += 1; j += 1; continue }
            let h = clean(heard.joined(separator: " "))
            let f = clean(fixed.joined(separator: " "))
            if !h.isEmpty, !f.isEmpty, h != f,
               heard.count <= 4, fixed.count <= 4 {
                pairs.append((h, f))
            }
        }
        return pairs.map { (heard: $0.0, corrected: $0.1) }
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}

/// Saves the lexicon as JSON in Application Support and keeps it in memory.
@MainActor
final class LexiconStore: ObservableObject {
    @Published private(set) var entries: [LexiconEntry] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = support.appendingPathComponent("Gabble", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("lexicon.json")
        }
        load()
    }

    var confirmed: [LexiconEntry] { entries.filter { $0.state == .confirmed } }
    var suggested: [LexiconEntry] { entries.filter { $0.state == .suggested } }

    /// Words passed to the speech engine to bias recognition toward the user's jargon.
    var recognitionHints: [String] { confirmed.map(\.term) }

    func add(term: String, soundsLike: [String] = [], meaning: String = "",
             source: LexiconEntry.Source = .manual, state: LexiconEntry.State = .confirmed) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            entries[index].timesSeen += 1
            for s in soundsLike where !entries[index].soundsLike.contains(s) {
                entries[index].soundsLike.append(s)
            }
            if state == .confirmed { entries[index].state = .confirmed }
        } else {
            entries.append(LexiconEntry(term: trimmed, soundsLike: soundsLike, meaning: meaning,
                                        source: source, state: state))
        }
        save()
    }

    /// Imports a pasted list: one term per line, optionally "TERM - meaning" (spaces around the dash).
    func importList(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if let dash = text.range(of: " - ") {
                let term = text[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
                let meaning = text[dash.upperBound...].trimmingCharacters(in: .whitespaces)
                add(term: term, meaning: meaning)
            } else {
                add(term: text)
            }
        }
    }

    /// Scans a transcript or document and suggests new terms seen at least twice.
    func harvest(from text: String, minimumCount: Int = 2) {
        for (term, count) in LexiconLearner.candidateTerms(in: text) where count >= minimumCount {
            if entries.contains(where: { $0.term == term }) { continue }
            add(term: term, source: .harvested, state: .suggested)
        }
    }

    /// Learns from a user's edit of dictated text.
    func learnFromCorrection(original: String, edited: String) {
        for pair in LexiconLearner.corrections(original: original, edited: edited) {
            add(term: pair.corrected, soundsLike: [pair.heard], source: .correction, state: .confirmed)
        }
    }

    func approve(_ entry: LexiconEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].state = .confirmed
        save()
    }

    func remove(_ entry: LexiconEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([LexiconEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
