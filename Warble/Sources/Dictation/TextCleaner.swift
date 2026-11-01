import Foundation

/// Fast, predictable cleanup applied to every dictation before (and as a
/// fallback for) the on-device AI cleanup. Pure functions, unit tested.
enum TextCleaner {
    static let fillers = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm"]

    /// Phrases that throw away what was said just before them in the same dictation.
    static let scratchPhrases = ["scratch that", "scratched that", "stratch that", "scrap that", "delete that", "strike that"]

    struct Replacement: Equatable {
        var heard: String
        var written: String
    }

    static func clean(_ input: String, replacements: [Replacement] = []) -> String {
        var text = input
        text = applyScratch(text)
        text = applyReplacements(text, replacements)
        text = removeFillers(text)
        text = removeInterruptingFillers(text)
        text = removeStutters(text)
        text = applySpokenCommands(text)
        text = tidySpacing(text)
        text = capitaliseSentences(text)
        return text
    }

    static func applyScratch(_ text: String) -> String {
        var result = text
        for phrase in scratchPhrases {
            while let range = result.range(of: phrase, options: [.caseInsensitive, .backwards]) {
                let before = result[..<range.lowerBound]
                let after = String(result[range.upperBound...]
                    .drop(while: { " ,.;:!".contains($0) }))
                // "Her birthday is in December, scratch that, her birthday is in
                // November": the speaker re-says the start of what they're
                // replacing, so cut back to exactly there.
                if let restart = restartPoint(in: String(before), for: after) {
                    let keep = String(before[..<restart]).trimmingCharacters(in: .whitespaces)
                    result = keep.isEmpty ? after : keep + " " + after
                    continue
                }
                // Drop the sentence (or clause) immediately before the phrase.
                let trimmed = before.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
                let withoutLastPunct = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
                    ? String(trimmed.dropLast()) : trimmed
                var keep = ""
                if let cut = withoutLastPunct.lastIndex(where: { ".!?\n".contains($0) }) {
                    keep = String(withoutLastPunct[...cut])
                }
                result = keep.isEmpty ? after : keep + " " + after
            }
        }
        return result
    }

    /// Where the speaker began the words they re-say after "scratch that":
    /// the last place the first two words that follow it appear, if that's
    /// recent. Nil when they started afresh.
    static func restartPoint(in before: String, for after: String) -> String.Index? {
        let lead = after.split(whereSeparator: \.isWhitespace).prefix(2)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard lead.count == 2, lead.allSatisfy({ !$0.isEmpty }) else { return nil }
        let pattern = "(?i)(?<![\\p{L}\\p{N}'])" + NSRegularExpression.escapedPattern(for: lead[0])
            + "[\\s,]+" + NSRegularExpression.escapedPattern(for: lead[1]) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: before, range: NSRange(before.startIndex..., in: before))
        guard let last = matches.last, let found = Range(last.range, in: before) else { return nil }
        // Only a recent restart, not something said long before.
        guard before[found.lowerBound...].split(whereSeparator: \.isWhitespace).count <= 40 else { return nil }
        return found.lowerBound
    }

    static func applyReplacements(_ text: String, _ replacements: [Replacement]) -> String {
        var result = text
        // Longest first so "what's an x" wins over "x".
        for r in replacements.sorted(by: { $0.heard.count > $1.heard.count }) where !r.heard.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: r.heard) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: r.written)
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: template)
        }
        return result
    }

    static func removeFillers(_ text: String) -> String {
        let alternatives = fillers.joined(separator: "|")
        let pattern = "(?i)(?<![\\p{L}])(?:\(alternatives))(?![\\p{L}])[,.]?\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Removes a filler "like" or "you know" that interrupts a repeated word,
    /// e.g. "the like the like the tidy up" becomes "the the the tidy up",
    /// which stutter removal then turns into "the tidy up".
    static func removeInterruptingFillers(_ text: String) -> String {
        let pattern = "(?i)\\b(\\w+)\\s+(?:like|you know|I mean),?\\s+(?=\\1\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        // Repeat for chains like "the like the like the".
        for _ in 0..<4 {
            let next = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                      withTemplate: "$1 ")
            if next == result { break }
            result = next
        }
        return result
    }

    /// "the the plan" -> "the plan"
    static func removeStutters(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?i)\\b(\\w+)(\\s+\\1\\b)+") else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    static func applySpokenCommands(_ text: String) -> String {
        var result = text
        let commands: [(String, String)] = [("new paragraph", "\n\n"), ("new line", "\n")]
        for (spoken, output) in commands {
            let pattern = "(?i)[,.]?\\s*\\b\(spoken)\\b[,.]?\\s*"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                        withTemplate: NSRegularExpression.escapedTemplate(for: output))
            }
        }
        return result
    }

    static func tidySpacing(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            ("[ \\t]+", " "),             // collapse spaces
            (" +([,.;:!?])", "$1"),       // no space before punctuation
            ("([,;:])(?=[^\\s\\d])", "$1 "), // space after commas
            (",\\s*([.!?])", "$1"),       // ", ." -> "."
            (" *\\n *", "\n"),
        ]
        for (pattern, template) in rules {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                        withTemplate: template)
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    static func capitaliseSentences(_ text: String) -> String {
        var result = ""
        var capitaliseNext = true
        for ch in text {
            if capitaliseNext, ch.isLetter {
                result.append(contentsOf: ch.uppercased())
                capitaliseNext = false
            } else {
                result.append(ch)
                if ".!?\n".contains(ch) { capitaliseNext = true }
                else if !ch.isWhitespace { capitaliseNext = false }
            }
        }
        return result
    }
}

/// Joins phrases that are typed live, one at a time, into a natural sentence flow.
enum LiveJoiner {
    /// Returns the text to type for `phrase`, given everything typed so far in
    /// this dictation: a leading space when needed, and a lower-case start when
    /// the previous phrase didn't end a sentence.
    static func piece(for phrase: String, after typed: String,
                      replacements: [TextCleaner.Replacement] = []) -> String {
        var text = TextCleaner.clean(phrase, replacements: replacements)
        guard !text.isEmpty else { return "" }
        guard let last = typed.last else { return text }
        let endsSentence = ".!?\n".contains(last)
        if !endsSentence, let first = text.first, first.isUppercase {
            let firstWord = text.prefix { !$0.isWhitespace && !$0.isPunctuation }
            let keepCapital = firstWord == "I" || firstWord.count > 1 && firstWord.allSatisfy { $0.isUppercase || $0.isNumber }
                || replacements.contains { $0.written.hasPrefix(String(firstWord)) }
            if !keepCapital {
                text = first.lowercased() + text.dropFirst()
            }
        }
        if last.isWhitespace || text.first == "\n" || text.first.map({ ",.;:!?".contains($0) }) == true {
            return text
        }
        return " " + text
    }
}

/// Types words while a phrase is still being spoken, instead of waiting for the
/// speech engine to finish the phrase. A word is typed once it has stayed the
/// same in two updates in a row and isn't the last word heard (which may still
/// be changing). When the phrase is final, the rest is typed, or the phrase is
/// corrected if the engine changed its mind. Pure, unit tested.
struct LivePhraseTyper {
    enum Action: Equatable {
        case type(String)
        /// Replace `old` (just before the cursor) with `new`.
        case replace(old: String, new: String)
    }

    /// Everything typed before the current phrase.
    private(set) var typedBefore = ""
    /// What has been typed for the current phrase.
    private(set) var phraseTyped = ""
    private var previousWords: [String] = []

    var typedSoFar: String { typedBefore + phraseTyped }

    /// Handles an in-progress update for the current phrase. Returns text to type now.
    mutating func volatile(_ text: String, replacements: [TextCleaner.Replacement] = []) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        defer { previousWords = words }
        var stable = 0
        while stable < words.count - 1, stable < previousWords.count,
              Self.key(words[stable]) == Self.key(previousWords[stable]) {
            stable += 1
        }
        guard stable > 0 else { return "" }
        let wanted = LiveJoiner.piece(for: words[0..<stable].joined(separator: " "), after: typedBefore,
                                      replacements: replacements)
        // Only ever add to the end; never take back what is already typed mid-phrase.
        guard wanted.hasPrefix(phraseTyped), wanted.count > phraseTyped.count else { return "" }
        let extra = String(wanted.dropFirst(phraseTyped.count))
        // Hold back a trailing full stop: the sentence may carry on.
        let trimmed = extra.hasSuffix(".") ? String(extra.dropLast()) : extra
        guard !trimmed.isEmpty, !trimmed.allSatisfy(\.isWhitespace) else { return "" }
        phraseTyped += trimmed
        return trimmed
    }

    /// Handles the finished phrase. Returns what to do, or nil if nothing.
    mutating func final(_ text: String, replacements: [TextCleaner.Replacement] = []) -> Action? {
        let wanted = LiveJoiner.piece(for: text, after: typedBefore, replacements: replacements)
        let typed = phraseTyped
        typedBefore += wanted
        phraseTyped = ""
        previousWords = []
        if wanted == typed { return nil }
        if !wanted.isEmpty, typed.hasPrefix(wanted) {
            // The engine finished the phrase earlier than the words already typed;
            // the extra words belong to the next phrase.
            phraseTyped = String(typed.dropFirst(wanted.count))
            previousWords = phraseTyped.split(whereSeparator: \.isWhitespace).map(String.init)
            return nil
        }
        if wanted.hasPrefix(typed) { return .type(String(wanted.dropFirst(typed.count))) }
        if typed.isEmpty { return wanted.isEmpty ? nil : .type(wanted) }
        return .replace(old: typed, new: wanted)
    }

    /// Records that a replacement couldn't be made, so `typed` stayed in the field.
    mutating func replacementFailed(old: String, new: String) {
        // Keep the record accurate: the field still has `old`, and nothing of `new`.
        typedBefore = String(typedBefore.dropLast(new.count)) + old
    }

    private static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
