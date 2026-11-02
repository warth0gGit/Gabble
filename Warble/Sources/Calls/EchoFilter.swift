import Foundation

/// When you take a call on the Mac's speakers, your microphone also hears the
/// other people, so their words turn up twice: once from the call audio and
/// again as "Me". This finds the sentences in your lines that repeat what
/// someone else said at about the same time, and removes them. Your own words
/// in the same line are kept. Pure, unit tested.
enum EchoFilter {
    /// How far apart in time (seconds) an echo and the original can be.
    static let window: TimeInterval = 20
    /// Share of a sentence's word pairs/triples that must match the others' words.
    static let threshold = 0.6

    static func removeEchoes(from segments: [CallTranscript.Segment],
                             me: String = CallRecorder.meLabel) -> [CallTranscript.Segment] {
        let others = segments.filter { $0.speaker != me }
        guard !others.isEmpty else { return segments }
        return segments.compactMap { segment in
            guard segment.speaker == me else { return segment }
            let length = Double(segment.text.split(separator: " ").count) * 0.4
            let nearby = others.filter {
                $0.offset >= segment.offset - window && $0.offset <= segment.offset + length + window
            }
            guard !nearby.isEmpty else { return segment }
            let heard = words(nearby.map(\.text).joined(separator: " "))
            let kept = ActionSpotter.sentences(in: segment.text, keepShort: true)
                .filter { !isEcho(words($0), of: heard) }
            guard !kept.isEmpty else { return nil }
            var s = segment
            s.text = kept.joined(separator: " ")
            return s
        }
    }

    /// Whether a sentence is a near-copy of something in `heard`.
    static func isEcho(_ sentence: [String], of heard: [String]) -> Bool {
        guard !sentence.isEmpty, !heard.isEmpty else { return false }
        if sentence.count <= 3 {
            // Short: the same words in the same order.
            return contains(heard, sentence)
        }
        let n = sentence.count >= 6 ? 3 : 2
        let theirs = Set(grams(heard, n))
        let mine = grams(sentence, n)
        let shared = mine.filter { theirs.contains($0) }.count
        return Double(shared) / Double(mine.count) >= threshold
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func grams(_ words: [String], _ n: Int) -> [String] {
        guard words.count >= n else { return [words.joined(separator: " ")] }
        return (0...(words.count - n)).map { words[$0..<($0 + n)].joined(separator: " ") }
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
