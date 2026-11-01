import Foundation

/// Word error rate: how many words a transcript got wrong compared with what
/// was really said (substituted, missing or extra words), as a share of the
/// words really said. Pure, unit tested.
struct WordErrorRate: Equatable {
    var referenceWords: Int
    var substitutions: Int
    var deletions: Int
    var insertions: Int

    var errors: Int { substitutions + deletions + insertions }
    var rate: Double { referenceWords == 0 ? 0 : Double(errors) / Double(referenceWords) }
    /// Share of words right, e.g. 0.96 for 96%.
    var accuracy: Double { max(0, 1 - rate) }

    /// Lower-case words without punctuation, so "Q3," and "q3" match.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-/")))
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'"))) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    static func compute(reference: String, hypothesis: String) -> WordErrorRate {
        let ref = words(reference)
        let hyp = words(hypothesis)
        if ref.isEmpty { return WordErrorRate(referenceWords: 0, substitutions: 0, deletions: 0, insertions: hyp.count) }
        if hyp.isEmpty { return WordErrorRate(referenceWords: ref.count, substitutions: 0, deletions: ref.count, insertions: 0) }
        // Edit distance table; each cell keeps its cost and how it was made up.
        struct Cell { var cost, s, d, i: Int }
        var previous = (0...hyp.count).map { Cell(cost: $0, s: 0, d: 0, i: $0) }
        for r in 1...ref.count {
            var current = [Cell(cost: r, s: 0, d: r, i: 0)]
            for h in 1...hyp.count {
                let same = ref[r - 1] == hyp[h - 1]
                let diag = previous[h - 1], up = previous[h], left = current[h - 1]
                var best = Cell(cost: diag.cost + (same ? 0 : 1), s: diag.s + (same ? 0 : 1), d: diag.d, i: diag.i)
                if up.cost + 1 < best.cost { best = Cell(cost: up.cost + 1, s: up.s, d: up.d + 1, i: up.i) }
                if left.cost + 1 < best.cost { best = Cell(cost: left.cost + 1, s: left.s, d: left.d, i: left.i + 1) }
                current.append(best)
            }
            previous = current
        }
        let last = previous[hyp.count]
        return WordErrorRate(referenceWords: ref.count, substitutions: last.s, deletions: last.d, insertions: last.i)
    }

    /// Word List terms that appear in what was said but not in the transcript.
    static func missedTerms(_ terms: [String], reference: String, hypothesis: String) -> [String] {
        let ref = " " + words(reference).joined(separator: " ") + " "
        let hyp = " " + words(hypothesis).joined(separator: " ") + " "
        return terms.filter { term in
            let t = " " + words(term).joined(separator: " ") + " "
            return t.count > 2 && ref.contains(t) && !hyp.contains(t)
        }
    }
}
