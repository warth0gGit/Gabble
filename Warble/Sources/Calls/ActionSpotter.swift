import Foundation

/// Finds the sentences in a call that sound like someone taking on a task
/// ("I have to get sign-off by close of play on Wednesday", "Can you send me
/// the deck?"), without any AI. The summariser uses them two ways: it points
/// the action-items pass at them, and any strong one that ends up with no
/// action is checked again on its own, so a clear commitment can't simply be
/// dropped. Pure, unit tested.
enum ActionSpotter {
    struct Candidate: Equatable {
        var speaker: String
        var offset: TimeInterval
        var sentence: String
        /// It names a deadline ("by Wednesday", "close of play").
        var hasDeadline: Bool
        /// The speaker is talking about something they themselves will do.
        var isOwn: Bool

        /// Worth a second look if no action covers it.
        var isStrong: Bool { hasDeadline || isOwn }

        /// "Me (12:30): I have to …" for prompts.
        var line: String { "\(speaker) (\(CallTranscript.timestamp(offset))): \(sentence)" }
    }

    // Things you say when you take something on yourself.
    private static let ownCue = #"\b(i|we)\s*(('ll|will|shall)\s+(?!be\s+honest|tell\s+you\s+what|see\s+you|talk\s+to\s+you)|(need|needs|have|has|had|got|ought)\s+to\b|'ve\s+got\s+to\b|have\s+got\s+to\b|must\b|should\b|('m|am|are|'re)\s+going\s+to\b|can\s+take\b|promise\b|owe\s+you\b)"#
        + #"|\blet\s+me\s+(check|find|get|send|look|follow|ask|see|chase|sort|confirm|speak|talk|book|set|share|draft|write|circle|loop)\b"#
        + #"|\b(i'll|i will|we'll|we will)\s+(take|own|handle|pick)\b"#
        + #"|\b(leave\s+it\s+with\s+me|on\s+me|i'm\s+on\s+it|remind\s+me\s+to)\b"#
    // Things you say when you hand something to someone else.
    private static let otherCue = #"\b(can|could|would|will)\s+you\b|\bplease\b|\byou\s+(need|have|'ll\s+need|will\s+need|should|must)\s+to\b|\b(action|to-do|todo|follow[\s-]?up|takeaway|take\s+away|make\s+sure)\b"#
    // Deadlines, including the British ones.
    private static let deadlineWords = #"today|tonight|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|this\s+week|next\s+week|end\s+of\s+(the\s+)?(day|week|month|play|business)|close\s+of\s+(play|business)|closer\s+play|close\s+a\s+play|cop|cob|eod|eob|eow|asap|first\s+thing|by\s+(the\s+)?\d{1,2}(st|nd|rd|th)?|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2}|\d{1,2}(st|nd|rd|th)?\s+(of\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"#
    private static let deadlineCue = #"\b("# + deadlineWords + #")\b"#

    /// Every sentence in the call that sounds like a task, in order.
    static func candidates(in transcript: CallTranscript) -> [Candidate] {
        var found: [Candidate] = []
        let turns = transcript.merged
        // A pause can cut a sentence in two ("I have to go and get" / "an
        // agreement from the chief executive by Wednesday"), so an unfinished
        // sentence is carried into the same person's next turn.
        var carried: (text: String, offset: TimeInterval)?
        for (index, segment) in turns.enumerated() {
            var pieces = sentences(in: segment.text, keepShort: true)
            var offsets = Array(repeating: segment.offset, count: pieces.count)
            if let carry = carried, !pieces.isEmpty {
                pieces[0] = carry.text + " " + pieces[0]
                offsets[0] = carry.offset
            } else if let carry = carried {
                pieces = [carry.text]
                offsets = [carry.offset]
            }
            carried = nil
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let unfinished = !(trimmed.last.map { ".?!".contains($0) } ?? true)
            if unfinished, index + 1 < turns.count, turns[index + 1].speaker == segment.speaker, let last = pieces.last {
                carried = (last, offsets[offsets.count - 1])
                pieces.removeLast()
                offsets.removeLast()
            }
            for (sentence, offset) in zip(pieces, offsets) where sentence.split(separator: " ").count >= 3 {
                if let candidate = candidate(sentence, speaker: segment.speaker, offset: offset) {
                    found.append(candidate)
                }
            }
        }
        return found
    }

    static func candidate(_ sentence: String, speaker: String, offset: TimeInterval) -> Candidate? {
        let lowered = normalised(sentence)
        let own = matches(ownCue, lowered)
        let other = matches(otherCue, lowered)
        guard own || other else { return nil }
        return Candidate(speaker: speaker, offset: offset, sentence: sentence,
                         hasDeadline: matches(deadlineCue, lowered), isOwn: own)
    }

    /// Splits a turn into sentences. A very long run-on turn (speech
    /// recognition sometimes leaves out full stops) is cut into pieces of
    /// about 30 words so a prompt line stays short.
    static func sentences(in text: String, keepShort: Bool = false) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!".contains(character) {
                append(current, to: &result, keepShort: keepShort)
                current = ""
            }
        }
        append(current, to: &result, keepShort: keepShort)
        return result
    }

    private static func append(_ piece: String, to list: inout [String], keepShort: Bool) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, keepShort || trimmed.split(separator: " ").count >= 3 else { return }
        let words = trimmed.split(separator: " ")
        guard words.count > 40 else { return list.append(trimmed) }
        stride(from: 0, to: words.count, by: 30).forEach { start in
            let slice = words[start..<min(start + 30, words.count)].joined(separator: " ")
            if slice.split(separator: " ").count >= 3 { list.append(slice) }
        }
    }

    /// Whether an action item already says what this sentence says: enough
    /// of the sentence's meaningful words appear in the task.
    static func isCovered(_ candidate: Candidate, by actions: [CallSummary.ActionItem]) -> Bool {
        let words = contentWords(candidate.sentence)
        guard !words.isEmpty else { return true }
        return actions.contains { action in
            let taskWords = contentWords(action.task + " " + action.due)
            let shared = words.intersection(taskWords).count
            return shared >= min(3, words.count) || Double(shared) / Double(words.count) >= 0.5
        }
    }

    /// The deadline phrase in a sentence, such as "by close of play on Wednesday", or "".
    static func deadline(in sentence: String) -> String {
        let lowered = normalised(sentence)
        let pattern = #"\b(by|before|on|for|until|due)?\s*(the\s+)?("# + deadlineWords
            + #")(\s+(on|this|next)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday))?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let range = Range(match.range, in: lowered) else { return "" }
        return String(lowered[range]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "at", "by", "for", "with", "from",
        "i", "we", "you", "he", "she", "they", "it", "me", "us", "my", "our", "your", "is", "are", "was",
        "be", "been", "have", "has", "had", "got", "get", "need", "will", "ll", "going", "can", "could",
        "would", "should", "must", "that", "this", "so", "just", "then", "do", "also", "really", "okay",
        "ok", "yeah", "um", "uh", "like", "some", "any", "all", "up", "out", "about", "there", "if",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        let words = normalised(text).components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
        return Set(words.filter { $0.count > 1 && !stopWords.contains($0) }.map(stem))
    }

    /// "agreements" and "agreement" count as the same word.
    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
