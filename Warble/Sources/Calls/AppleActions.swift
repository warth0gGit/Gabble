import Foundation
import FoundationModels
import NaturalLanguage

// The action items Apple Intelligence writes when Claude can't. The on-device
// model reads only a few thousand words at a time and is easily led into
// padding, so the work is split into small checked steps:
//
// 1. Map: each part of the call (overlapping its neighbours a little) gives
//    at most four candidates, each with the words from the transcript that
//    show it and the exact timing words that were said.
// 2. Filter, in plain Swift: a candidate whose quote isn't really in the
//    transcript is dropped, and so are fragments, things about the call itself
//    and "next time" advice. Timing words nobody said are removed.
// 3. Reduce: one more request with only the numbered survivors merges
//    duplicates and steps of the same work, drops vague ones and keeps at most
//    eight, saying which candidates each item came from. Then the code merges
//    anything still alike and makes sure there are never more than eight.
//
// Dates are never worked out by the model: CallSummary.dueDate does that from
// the timing words, and an item with no real date gets no date.

/// Map step: the follow-ups in one part of the call.
@Generable
struct ActionCandidates {
    @Guide(description: "Up to four follow-ups from this part of the call, most important first. Empty if there were none.", .maximumCount(4))
    var candidates: [ActionCandidate]
}

@Generable
struct ActionCandidate {
    @Guide(description: "The words from the transcript that show this follow-up, copied exactly, at most 25 words.")
    var evidence: String
    @Guide(description: "Who will do it: Me for the person who recorded the call, a person's name exactly as written in the transcript, or an empty string if nobody was named.")
    var owner: String
    @Guide(description: "The task, starting with a verb, specific enough to act on without reading the transcript.")
    var task: String
    @Guide(description: "The exact words from the transcript saying when it is due, such as by Friday. Empty if no time was said. Never work out or invent a date.")
    var dueText: String
}

/// Reduce step: the final list, built only from the numbered candidates.
@Generable
struct MergedActions {
    @Guide(description: "The final follow-ups, most important first. At most eight.", .maximumCount(8))
    var items: [MergedAction]
}

@Generable
struct MergedAction {
    @Guide(description: "The numbers of the candidates this item comes from.")
    var sources: [Int]
    @Guide(description: "Who will do it, as written in those candidates: Me, a person's name, or an empty string.")
    var owner: String
    @Guide(description: "The task, starting with a verb.")
    var task: String
}

/// A follow-up on its way through the steps. Pure data.
struct ActionDraft: Equatable {
    var owner: String
    var task: String
    var dueText: String = ""
    var evidence: String = ""
    /// A sentence that sounded like a task (ActionSpotter), not yet written as one.
    var isRawSentence = false
}

enum AppleActions {
    /// Never more action items than this.
    static let maxItems = 8

    /// The action items for a call, written with Apple Intelligence.
    static func find(in transcript: CallTranscript, chunks: [SummaryChunker.Chunk], wordList: String,
                     summary: CallSummary) async -> [CallSummary.ActionItem] {
        let names = transcript.people
        let hints = ActionSpotter.candidates(in: transcript)
        let parts = SummaryChunker.withOverlap(chunks)

        // 1 and 2: candidates from each part, checked against that part.
        var drafts: [ActionDraft] = []
        for (index, part) in parts.enumerated() {
            let intro = parts.count == 1
                ? "Here is the transcript of a call."
                : "Here is part \(index + 1) of \(parts.count) of a call."
            for draft in await candidates(in: part, intro: intro + "\n" + wordList, hints: hints) {
                if let kept = ActionFilter.keep(draft, lines: part.lines, names: names) { drafts.append(kept) }
            }
        }

        // A clear commitment with a deadline ("I have to get sign-off by
        // Wednesday") that no candidate covers is added in the speaker's own
        // words, so it can't simply be lost. The reduce step rewrites it.
        let found = drafts.map { CallSummary.ActionItem(owner: $0.owner, task: $0.task, due: $0.dueText) }
        for hint in hints where hint.hasDeadline && !ActionSpotter.isCovered(hint, by: found) {
            let draft = ActionDraft(owner: hint.isOwn ? CallSummariser.owner(hint.speaker) : "", task: hint.sentence,
                                    dueText: ActionSpotter.deadline(in: hint.sentence), evidence: hint.sentence,
                                    isRawSentence: true)
            if let kept = ActionFilter.keep(draft, lines: [hint.line], names: names) { drafts.append(kept) }
        }

        // 3: the final list.
        return await reduce(drafts, summary: summary)
            .map { CallSummary.ActionItem(owner: $0.owner, task: $0.task, due: $0.dueText) }
    }

    // MARK: - Map

    private static func candidates(in chunk: SummaryChunker.Chunk, intro: String,
                                   hints: [ActionSpotter.Candidate]) async -> [ActionDraft] {
        let inChunk = hints.filter { $0.offset >= chunk.start - 1 && $0.offset <= chunk.end + 1 }
        var prompt = intro + """
        List the follow-ups in this part of the call: things someone said they will do after the call, \
        or asked someone else to do. Leave out the call itself (sharing a screen, hearing each other, joining \
        or leaving), small talk, thanks, general advice and things already done. \
        For each one, first copy the words from the transcript that show it.
        """
        if !inChunk.isEmpty {
            prompt += "\n\nThese lines may contain follow-ups:\n" + inChunk.prefix(12).map { "- " + $0.line }.joined(separator: "\n")
        }
        prompt += "\n\nTranscript:\n" + chunk.text
        switch await CallSummariser.respond(to: prompt, generating: ActionCandidates.self) {
        case .success(let answer):
            return answer.candidates.map {
                ActionDraft(owner: $0.owner, task: $0.task, dueText: $0.dueText, evidence: $0.evidence)
            }
        case .failure(let problem) where problem.reason == CallSummariser.tooLong && chunk.lines.count > 1:
            // Too long for the model after all: each half on its own.
            var drafts: [ActionDraft] = []
            for half in chunk.halves {
                drafts += await candidates(in: half, intro: intro, hints: hints)
            }
            return drafts
        case .failure:
            return []
        }
    }

    // MARK: - Reduce

    /// The final list: merged, vague ones dropped, at most eight, most
    /// important first. A long list is reduced in two rounds.
    static func reduce(_ drafts: [ActionDraft], summary: CallSummary) async -> [ActionDraft] {
        var round = mergeSimilar(drafts)
        guard !round.isEmpty else { return [] }
        if round.count > 20 {
            var next: [ActionDraft] = []
            for start in stride(from: 0, to: round.count, by: 16) {
                let group = Array(round[start..<min(start + 16, round.count)])
                next += await reduceOnce(group, summary: summary) ?? fallback(group)
            }
            round = mergeSimilar(next)
        }
        let final = await reduceOnce(round, summary: summary) ?? fallback(round)
        return Array(mergeSimilar(final).prefix(maxItems))
    }

    private static func reduceOnce(_ drafts: [ActionDraft], summary: CallSummary) async -> [ActionDraft]? {
        let list = drafts.enumerated().map { index, draft in
            let who = draft.owner.isEmpty ? "" : "\(draft.owner): "
            let what = draft.isRawSentence ? "(in their words) \u{201C}\(draft.task)\u{201D}" : draft.task
            return "\(index + 1). \(who)\(what)"
        }.joined(separator: "\n")
        let prompt = """
        These are possible follow-ups from a call, numbered. Turn them into the final list of action items for the notes.
        - Merge items that are the same task, or steps of the same piece of work, into one item.
        - Leave out anything vague, trivial, already done, small talk, or about the call itself.
        - Keep at most 8, most important first.
        - Keep each owner as written. Never add a task that isn't in the list.
        - For each item, give the numbers of the candidates it comes from.

        What the call was about: \(summary.headline) \(summary.overview)

        Candidates:
        \(list)
        """
        guard case .success(let answer) = await CallSummariser.respond(to: prompt, generating: MergedActions.self) else {
            return nil
        }
        return assemble(answer.items.map { (sources: $0.sources, owner: $0.owner, task: $0.task) }, from: drafts)
    }

    /// Builds the final items from the model's answer, taking owners and
    /// timing words only from the candidates each item says it came from. An
    /// item that names no real candidate is dropped, so nothing is invented.
    /// Pure, unit tested.
    static func assemble(_ items: [(sources: [Int], owner: String, task: String)],
                         from drafts: [ActionDraft]) -> [ActionDraft] {
        var result: [ActionDraft] = []
        for item in items {
            let picked = Set(item.sources).sorted().filter { (1...max(1, drafts.count)).contains($0) && $0 <= drafts.count }
                .map { drafts[$0 - 1] }
            guard let first = picked.first else { continue }
            var task = CallSummariser.clean(item.task)
            if !ActionFilter.isActionable(task) {
                guard !first.isRawSentence, ActionFilter.isActionable(first.task) else { continue }
                task = first.task
            }
            let said = CallSummariser.owner(item.owner)
            let owner = picked.first { $0.owner.caseInsensitiveCompare(said) == .orderedSame }?.owner
                ?? picked.first { !$0.owner.isEmpty }?.owner ?? ""
            let due = picked.first { !$0.dueText.isEmpty && CallSummary.dueDate($0.dueText, from: Date()) != nil }?.dueText
                ?? ""
            result.append(ActionDraft(owner: owner, task: task, dueText: due,
                                      evidence: picked.map(\.evidence).joined(separator: " … ")))
        }
        return result
    }

    /// When Apple Intelligence can't do the reduce step: the candidates as
    /// they are, alike ones merged, dated ones first. A sentence that was never
    /// written up as a task is shown as one to check.
    static func fallback(_ drafts: [ActionDraft]) -> [ActionDraft] {
        let merged = mergeSimilar(drafts).map { draft -> ActionDraft in
            guard draft.isRawSentence else { return draft }
            var checked = draft
            checked.task = "Check: \u{201C}\(draft.task)\u{201D}"
            checked.isRawSentence = false
            return checked
        }
        let dated = merged.filter { !$0.dueText.isEmpty && CallSummary.dueDate($0.dueText, from: Date()) != nil }
        let rest = merged.filter { $0.dueText.isEmpty || CallSummary.dueDate($0.dueText, from: Date()) == nil }
        return Array((dated + rest).prefix(maxItems))
    }

    /// Merges items with the same owner whose meaningful words mostly overlap
    /// (60% of the shorter one), keeping the first. Pure, unit tested.
    static func mergeSimilar(_ drafts: [ActionDraft]) -> [ActionDraft] {
        var result: [ActionDraft] = []
        for draft in drafts {
            let words = ActionSpotter.contentWords(draft.task)
            let match = result.firstIndex { existing in
                guard existing.owner.caseInsensitiveCompare(draft.owner) == .orderedSame else { return false }
                let other = ActionSpotter.contentWords(existing.task)
                let smaller = min(words.count, other.count)
                return smaller > 0 && Double(words.intersection(other).count) / Double(smaller) >= 0.6
            }
            if let match {
                if result[match].dueText.isEmpty { result[match].dueText = draft.dueText }
                continue
            }
            result.append(draft)
        }
        return result
    }
}

/// The plain-Swift checks between the map and reduce steps. Pure, unit tested.
enum ActionFilter {
    /// Keeps a candidate only if it's a real follow-up that was really said,
    /// with its timing words and owner put right. Nil means drop it.
    static func keep(_ draft: ActionDraft, lines: [String], names: [String]) -> ActionDraft? {
        var d = draft
        d.owner = CallSummariser.owner(d.owner)
        d.task = CallSummariser.clean(d.task).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        d.evidence = CallSummariser.clean(d.evidence).trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D} "))
        d.dueText = CallSummariser.nothingToEmpty(CallSummariser.clean(d.dueText))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()[]."))

        // The quote must really be in this part of the transcript.
        guard let match = EvidenceMatch.best(d.evidence, in: lines), match.score >= 0.8 else { return nil }

        // "Next time" advice ("next time we should start earlier") isn't a
        // follow-up, unless the task is specific anyway (names someone or something).
        let mentionsNextTime = [d.task, d.dueText, d.evidence].contains { $0.lowercased().contains("next time") }
        if mentionsNextTime, !isSpecific(d.task) { return nil }

        // Timing words must have been said, and must be timing words.
        if !d.dueText.isEmpty {
            let said = EvidenceMatch.contains(match.line + " " + d.evidence, phrase: d.dueText)
            if !said || isTimestamp(d.dueText) || d.dueText.lowercased().contains("next time") { d.dueText = "" }
        }

        guard isActionable(d.task) else { return nil }
        d.owner = resolveOwner(d.owner, speaker: match.speaker, evidence: d.evidence, names: names)
        return d
    }

    /// Long enough to act on, names a thing (not just "it" or "her"), and
    /// isn't about the call itself.
    static func isActionable(_ task: String) -> Bool {
        let words = task.split(whereSeparator: { $0 == " " }).filter { $0.contains(where: \.isLetter) }
        guard words.count >= 4 else { return false }
        guard ActionSpotter.contentWords(task).count >= 2 else { return false }
        guard !isAboutTheCall(task) else { return false }
        return hasNoun(task)
    }

    private static let aboutTheCall = [
        #"\bshar(e|ing) (my |your |the |his |her |their )?screen\b"#, #"\bsee (my|your|the) screen\b"#,
        #"\bhear (me|you|us|them)\b"#, #"\b(on|off) (the )?camera\b"#, #"\bcamera (on|off)\b"#,
        #"\b(un)?mute\b"#, #"\bon mute\b"#, #"\b(join|leave|drop off|hop off|jump off|dial into?) (the |this )?(call|meeting|teams|zoom)\b"#,
        #"\bsign (you |me |them |him |her )?in\b"#, #"\bwaiting room\b"#, #"\bin the chat\b"#, #"\bnext slide\b"#,
        #"\bscroll (up|down)\b"#, #"\breconnect\b"#, #"\bbad connection\b"#, #"\brecord(ing)? (the|this) (call|meeting)\b"#,
        #"\bcan you see\b"#, #"\bgo off camera\b"#,
    ]

    static func isAboutTheCall(_ task: String) -> Bool {
        let lowered = task.lowercased()
        return aboutTheCall.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    /// "18:15", "(26:17)" and the like: a moment in the call, not a deadline.
    static func isTimestamp(_ text: String) -> Bool {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]."))
            .range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    /// A noun or a name, not only pronouns and verbs.
    static func hasNoun(_ text: String) -> Bool {
        if hasName(text) { return true }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if tag == .noun { found = true }
            return !found
        }
        return found
    }

    /// Names a person, place or organization, or has a number in it.
    static func isSpecific(_ text: String) -> Bool {
        hasName(text) || text.contains(where: \.isNumber)
    }

    private static func hasName(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) { found = true }
            return !found
        }
        return found
    }

    /// Who the follow-up belongs to. "I'll send it" belongs to whoever said
    /// it, and a first name for someone on the call becomes their full name,
    /// so the task links to their note.
    static func resolveOwner(_ owner: String, speaker: String?, evidence: String, names: [String]) -> String {
        var result = owner
        if let speaker, ActionSpotter.isFirstPersonCommitment(evidence), result.isEmpty || result == "Me" {
            if speaker == "Me" {
                result = "Me"
            } else if speaker != "Others" {
                result = speaker
            }
        }
        guard !result.isEmpty, result != "Me" else { return result }
        if let exact = names.first(where: { $0.caseInsensitiveCompare(result) == .orderedSame }) { return exact }
        let parts = result.split(separator: " ")
        if parts.count == 1 {
            let first = result.lowercased()
            let matches = names.filter { $0.split(separator: " ").first.map { $0.lowercased() } == first }
            if matches.count == 1 { return matches[0] }
        }
        return result
    }
}

/// Finds a quote in transcript lines, allowing for small differences in
/// wording. Pure, unit tested.
struct EvidenceMatch: Equatable {
    /// The share of the quote's words found together in the transcript, 0 to 1.
    var score: Double
    /// The transcript line the quote is in (the one in the middle, if it spans lines).
    var line: String
    /// Who said it, from that line.
    var speaker: String?

    /// The best place for `quote` in `lines` ("Name (mm:ss): text"), or nil if
    /// the quote is too short to check (under three words).
    static func best(_ quote: String, in lines: [String]) -> EvidenceMatch? {
        let wanted = words(quote)
        guard wanted.count >= 3 else { return nil }
        var tokens: [String] = []
        var lineOf: [Int] = []
        for (index, line) in lines.enumerated() {
            let text = SummaryChunker.parse(line)?.text ?? line
            for word in words(text) {
                tokens.append(word)
                lineOf.append(index)
            }
        }
        guard !tokens.isEmpty else { return nil }
        var need: [String: Int] = [:]
        for word in wanted { need[word, default: 0] += 1 }
        let size = min(tokens.count, wanted.count + max(2, wanted.count / 5))
        var window: [String: Int] = [:]
        for word in tokens[0..<size] { window[word, default: 0] += 1 }
        func hits() -> Int { need.reduce(0) { $0 + min($1.value, window[$1.key] ?? 0) } }
        var best = (hits: hits(), start: 0)
        if tokens.count > size {
            for start in 1...(tokens.count - size) {
                window[tokens[start - 1], default: 0] -= 1
                window[tokens[start + size - 1], default: 0] += 1
                let now = hits()
                if now > best.hits { best = (now, start) }
            }
        }
        let line = lines[lineOf[min(tokens.count - 1, best.start + size / 2)]]
        return EvidenceMatch(score: Double(best.hits) / Double(wanted.count), line: line,
                             speaker: SummaryChunker.parse(line)?.speaker)
    }

    /// Whether `phrase` appears, word for word, in `text`.
    static func contains(_ text: String, phrase: String) -> Bool {
        let wanted = words(phrase)
        guard !wanted.isEmpty else { return false }
        return (" " + words(text).joined(separator: " ") + " ").contains(" " + wanted.joined(separator: " ") + " ")
    }

    /// Lower-case words without punctuation; "don't" and "dont" are the same.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
