import Foundation

/// A piece of a word with its timing, as the speech model reports it.
/// A piece that begins with a space (or "▁") starts a new word.
struct TimedToken: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// A run of speech without a long pause, with where it sits in the audio.
struct TimedPhrase: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// Which tokens make up this phrase.
    var tokens: Range<Int>
}

/// Splits a long transcript into phrases at natural pauses, so each line of a
/// call transcript can be matched to the voice that said it. Pure, unit tested.
enum PhraseSplitter {
    static func phrases(from tokens: [TimedToken],
                        pause: TimeInterval = 0.7,
                        sentencePause: TimeInterval = 0.3,
                        sentenceMinLength: TimeInterval = 4,
                        maxLength: TimeInterval = 20) -> [TimedPhrase] {
        var result: [TimedPhrase] = []
        var first: Int?

        func close(_ endIndex: Int) {
            guard let start = first, endIndex > start else { return }
            let text = joined(tokens[start..<endIndex])
            if !text.isEmpty {
                result.append(TimedPhrase(text: text, start: tokens[start].start,
                                          end: tokens[endIndex - 1].end, tokens: start..<endIndex))
            }
            first = nil
        }

        for (i, token) in tokens.enumerated() {
            guard let start = first else {
                first = i
                continue
            }
            if startsWord(token) {
                let previous = tokens[i - 1]
                let gap = token.start - previous.end
                let length = previous.end - tokens[start].start
                let endedSentence = previous.text.last.map { ".?!".contains($0) } ?? false
                if gap >= pause
                    || length >= maxLength
                    || (endedSentence && gap >= sentencePause && length >= sentenceMinLength) {
                    close(i)
                    first = i
                }
            }
        }
        close(tokens.count)
        return result
    }

    static func startsWord(_ token: TimedToken) -> Bool {
        token.text.hasPrefix(" ") || token.text.hasPrefix("▁")
    }

    static func joined<C: Collection>(_ tokens: C) -> String where C.Element == TimedToken {
        tokens.map(\.text).joined()
            .replacingOccurrences(of: "▁", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
