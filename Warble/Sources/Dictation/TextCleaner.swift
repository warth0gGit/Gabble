import Foundation

/// Fast, predictable cleanup applied to every dictation before (and as a
/// fallback for) the on-device AI cleanup. Pure functions, unit tested.
enum TextCleaner {
    static let fillers = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm"]

    /// Phrases that throw away what was said just before them in the same dictation.
    static let scratchPhrases = ["scratch that", "delete that", "strike that"]

    struct Replacement: Equatable {
        var heard: String
        var written: String
    }

    static func clean(_ input: String, replacements: [Replacement] = []) -> String {
        var text = input
        text = applyScratch(text)
        text = applyReplacements(text, replacements)
        text = removeFillers(text)
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
