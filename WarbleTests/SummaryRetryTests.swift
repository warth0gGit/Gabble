import XCTest
@testable import Warble

/// Build 39: dates worked out in code, the Apple backup's checks, and asking
/// Claude again later when it couldn't answer.
final class DueDateTests: XCTestCase {
    /// Friday 15 January 2027, 08:00 UTC.
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ phrase: String) -> String? {
        guard let date = CallSummary.dueDate(phrase, from: start, calendar: utc) else { return nil }
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func testMoreWaysOfSayingWhen() {
        XCTAssertEqual(day("next week"), "2027-01-22")          // the Friday of next week
        XCTAssertEqual(day("by the 14th"), "2027-02-14")        // this month's 14th has passed
        XCTAssertEqual(day("by the 20th"), "2027-01-20")
        XCTAssertEqual(day("this afternoon"), "2027-01-15")
        XCTAssertEqual(day("later today"), "2027-01-15")
        XCTAssertEqual(day("end of the month"), "2027-01-31")
        XCTAssertEqual(day("Feb. 7th"), "2027-02-07")
        XCTAssertEqual(day("February the 7th"), "2027-02-07")
    }

    func testNoDateIsNeverGuessed() {
        XCTAssertNil(day("18:15"), "a moment in the call, not a deadline")
        XCTAssertNil(day("(26:17)"))
        XCTAssertNil(day("next time"))
        XCTAssertNil(day("soon"))
        XCTAssertNil(day(""))
    }

    func testTaskWithoutARealDateHasNoDateOrPhrase() {
        let line = CallSummary.task(.init(owner: "Me", task: "send the deck", due: "(26:17)"),
                                    people: [], callDate: start, calendar: utc)
        XCTAssertEqual(line, "- [ ] **Me**: send the deck")
    }
}

final class AppleActionsTests: XCTestCase {
    private let lines = [
        "Valentina Rossi (12:30): I need to decide on a mentor by Friday, and I'll let you know who.",
        "Me (13:05): Can you send me the Hawaii project plan so I can follow up with the team?",
        "Me (14:00): Let me share my screen with everyone now.",
        "Others (20:00): Next time we should probably start a bit earlier.",
    ]
    private let names = ["Valentina Rossi", "Alex Wylie"]

    private func keep(_ task: String, owner: String = "", due: String = "", evidence: String) -> ActionDraft? {
        ActionFilter.keep(ActionDraft(owner: owner, task: task, dueText: due, evidence: evidence), lines: lines, names: names)
    }

    func testRealFollowUpIsKeptWithFullNameAndSaidDeadline() {
        let kept = keep("Decide on a mentor", owner: "Valentina", due: "by Friday",
                        evidence: "I need to decide on a mentor by Friday")
        XCTAssertEqual(kept?.owner, "Valentina Rossi")
        XCTAssertEqual(kept?.dueText, "by Friday")
    }

    func testQuoteThatIsNotInTheCallIsDropped() {
        XCTAssertNil(keep("Book flights to Hawaii for the team", evidence: "we need to book the flights to Hawaii soon"))
    }

    func testFragmentsCallChatterAndNextTimeAdviceAreDropped() {
        XCTAssertNil(keep("Talk to her", evidence: "I need to decide on a mentor by Friday"))
        XCTAssertNil(keep("Share my screen with everyone", owner: "Me", evidence: "Let me share my screen with everyone now"))
        XCTAssertNil(keep("Start the call a bit earlier", evidence: "Next time we should probably start a bit earlier"))
    }

    func testTimingWordsMustHaveBeenSaidAndNotBeTimestamps() {
        let unsaid = keep("Decide on a mentor", owner: "Valentina", due: "by Monday",
                          evidence: "I need to decide on a mentor by Friday")
        XCTAssertEqual(unsaid?.dueText, "")
        let stamp = keep("Decide on a mentor", owner: "Valentina", due: "12:30",
                         evidence: "I need to decide on a mentor by Friday")
        XCTAssertEqual(stamp?.dueText, "")
    }

    func testIllDoItBelongsToWhoeverSaidIt() {
        XCTAssertEqual(ActionFilter.resolveOwner("", speaker: "Alex Wylie", evidence: "I'll send the Hawaii plan over",
                                                 names: names), "Alex Wylie")
        XCTAssertEqual(ActionFilter.resolveOwner("Me", speaker: "Alex Wylie", evidence: "I'll send the Hawaii plan over",
                                                 names: names), "Alex Wylie")
        XCTAssertEqual(ActionFilter.resolveOwner("alex", speaker: nil, evidence: "", names: names), "Alex Wylie")
        XCTAssertEqual(ActionFilter.resolveOwner("", speaker: "Me", evidence: "Can you send me the plan?",
                                                 names: names), "")
    }

    func testEvidenceMatchAllowsSmallDifferences() {
        let exact = EvidenceMatch.best("decide on a mentor by Friday", in: lines)
        XCTAssertEqual(exact?.score, 1)
        XCTAssertEqual(exact?.speaker, "Valentina Rossi")
        XCTAssertGreaterThanOrEqual(EvidenceMatch.best("decide on the mentor by Friday", in: lines)?.score ?? 0, 0.8)
        XCTAssertLessThan(EvidenceMatch.best("book flights to Hawaii for the whole team", in: lines)?.score ?? 0, 0.8)
        XCTAssertNil(EvidenceMatch.best("hi there", in: lines), "too short to check")
        XCTAssertTrue(EvidenceMatch.contains("I need to decide by Friday.", phrase: "by friday"))
        XCTAssertFalse(EvidenceMatch.contains("I need to decide by Friday.", phrase: "by Monday"))
    }

    func testAlikeItemsAreMerged() {
        let merged = AppleActions.mergeSimilar([
            ActionDraft(owner: "Me", task: "Send the revised offer to Acme"),
            ActionDraft(owner: "Me", task: "Send Acme the revised offer", dueText: "by Friday"),
            ActionDraft(owner: "Sarah Jones", task: "Send the revised offer to Acme"),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].dueText, "by Friday")
    }

    func testFinalListComesOnlyFromRealCandidates() {
        let drafts = [
            ActionDraft(owner: "Valentina Rossi", task: "Decide on a mentor", dueText: "by Friday"),
            ActionDraft(owner: "Me", task: "Follow up on the Hawaii project plan"),
        ]
        let items = AppleActions.assemble([
            (sources: [1], owner: "Valentina", task: "Decide on a mentor for the program"),
            (sources: [9], owner: "Me", task: "Invent a brand new task"),
            (sources: [2], owner: "someone", task: "Follow up on the Hawaii project"),
        ], from: drafts)
        XCTAssertEqual(items.count, 2, "an item from no real candidate is dropped")
        XCTAssertEqual(items[0].owner, "Valentina Rossi")
        XCTAssertEqual(items[0].dueText, "by Friday")
        XCTAssertEqual(items[1].owner, "Me")
    }

    func testFallbackKeepsAtMostEight() {
        let tasks = ["Email the budget to finance", "Book the venue for March", "Draft the hiring plan",
                     "Call the landlord about repairs", "Order new laptops for interns", "Renew the software license",
                     "Prepare slides for the board", "Chase the overdue invoice", "Update the client contract",
                     "Schedule the quarterly review", "Write the press release", "Fix the broken dashboard"]
        let drafts = tasks.map { ActionDraft(owner: "Me", task: $0) }
            + [ActionDraft(owner: "Me", task: "I have to get sign-off by Wednesday", dueText: "by Wednesday", isRawSentence: true)]
        let list = AppleActions.fallback(drafts)
        XCTAssertLessThanOrEqual(list.count, AppleActions.maxItems)
        XCTAssertEqual(list.first?.task, "Check: \u{201C}I have to get sign-off by Wednesday\u{201D}", "dated items first")
    }

    func testFirstPersonCommitments() {
        XCTAssertTrue(ActionSpotter.isFirstPersonCommitment("I'll send you the deck"))
        XCTAssertTrue(ActionSpotter.isFirstPersonCommitment("Let me check with finance"))
        XCTAssertFalse(ActionSpotter.isFirstPersonCommitment("Can you send me the deck?"))
    }

    func testChunksOverlapAndSplit() {
        let first = SummaryChunker.Chunk(start: 0, end: 10, lines: ["A (00:00): one two three four five",
                                                                   "B (00:10): six seven eight nine ten"], words: 10)
        let second = SummaryChunker.Chunk(start: 20, end: 20, lines: ["A (00:20): eleven twelve"], words: 2)
        let parts = SummaryChunker.withOverlap([first, second])
        XCTAssertEqual(parts[0], first)
        XCTAssertEqual(parts[1].lines, ["B (00:10): six seven eight nine ten", "A (00:20): eleven twelve"])
        XCTAssertEqual(parts[1].start, 10)
        XCTAssertEqual(first.halves.map(\.lines.count), [1, 1])

        let parsed = SummaryChunker.parse("Sarah Jones (1:07:40): what she said")
        XCTAssertEqual(parsed?.speaker, "Sarah Jones")
        XCTAssertEqual(parsed?.offset, 4060)
        XCTAssertEqual(parsed?.text, "what she said")
        XCTAssertNil(SummaryChunker.parse("no timestamp here"))
    }
}

final class ClaudeRetryTests: XCTestCase {
    /// Friday 15 January 2027, 08:00 UTC.
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private var call: CallTranscript {
        var t = CallTranscript(appName: "Microsoft Teams", started: start)
        t.add(speaker: "Valentina Rossi", text: "I need to decide on a mentor by Friday.", at: start.addingTimeInterval(65))
        t.add(speaker: "Me", text: "Great. Send me the Hawaii plan by closer play.", at: start.addingTimeInterval(70))
        t.ended = start.addingTimeInterval(600)
        return t
    }

    private var appleDraft: CallSummary {
        var s = CallSummary(headline: "Mentoring and the Hawaii project", overview: "Valentina is choosing a mentor.",
                            actionItems: [.init(owner: "Valentina Rossi", task: "Decide on a mentor", due: "by Friday")])
        s.provisional = true
        return s
    }

    private var claudes: CallSummary {
        var s = CallSummary(headline: "Valentina picks a mentor; Hawaii plan to follow",
                            overview: "Valentina will choose a mentor by Friday.",
                            actionItems: [.init(owner: "Valentina Rossi", task: "Decide on a mentor", due: "2027-01-22"),
                                          .init(owner: "Me", task: "Follow up on the Hawaii project plan")])
        s.writer = ClaudeSummariser.writer
        return s
    }

    func testDraftIsMarkedInTheNote() {
        var t = call
        t.summary = .done(appleDraft)
        let md = t.markdown
        XCTAssertTrue(md.contains("summarized_by: Apple Intelligence (on this Mac)\nsummary_status: provisional\n"))
        XCTAssertTrue(md.contains(CallSummary.draftCallout + "\n\n> [!summary] Summary"))
    }

    func testNoteIsUnchangedWhenClaudeAnswersFirstTime() {
        var t = call
        t.summary = .done(claudes)
        XCTAssertFalse(t.markdown.contains("summary_status"))
        XCTAssertFalse(t.markdown.contains("[!note] Draft"))
        XCTAssertTrue(t.markdown.contains("summarized_by: Claude (via Claude Code)"))
    }

    func testReplacingTheDraftGivesTheNoteClaudeWouldHaveWritten() {
        var draft = call
        draft.summary = .done(appleDraft)
        var final = call
        final.summary = .done(claudes)
        let rewritten = NoteRewriter.replacingSummary(in: draft.markdown, with: claudes, people: call.people,
                                                      callDate: start, minutes: 10, words: 15)
        XCTAssertEqual(rewritten, final.markdown)
    }

    func testReplacingNoSummaryFoldsTheTranscriptAndFixesMishearings() {
        var failed = call
        failed.summary = .failed("Claude's usage limit was reached. Apple Intelligence couldn't do it either: busy.")
        var claude = claudes
        claude.corrections = [.init(heard: "closer play", meant: "close of play")]
        var final = call
        final.summary = .done(claude)
        final.apply(claude.corrections)
        let rewritten = NoteRewriter.replacingSummary(
            in: failed.markdown, with: claude, people: call.people, callDate: start,
            minutes: 10, words: SummaryChunker.wordCount(final.plainText))
        XCTAssertEqual(rewritten, final.markdown)
    }

    func testYourOwnNotesInTheFileAreKept() {
        var draft = call
        draft.summary = .done(appleDraft)
        let edited = draft.markdown + "\n## My notes\nRemember to thank Valentina.\n"
        let rewritten = NoteRewriter.replacingSummary(in: edited, with: claudes, people: call.people,
                                                      callDate: start, minutes: 10, words: 15)
        XCTAssertTrue(rewritten?.hasSuffix("## My notes\nRemember to thank Valentina.\n") ?? false)
        XCTAssertNil(NoteRewriter.replacingSummary(in: "Not a Warble note", with: claudes, people: [],
                                                   callDate: start, minutes: 1, words: 1))
    }

    func testRetrySchedule() {
        XCTAssertEqual(SummaryQueue.delay(afterAttempts: 0), 30 * 60)
        XCTAssertEqual(SummaryQueue.delay(afterAttempts: 1), 3600)
        XCTAssertEqual(SummaryQueue.delay(afterAttempts: 2), 2 * 3600)
        XCTAssertEqual(SummaryQueue.delay(afterAttempts: 3), 4 * 3600)
        XCTAssertEqual(SummaryQueue.delay(afterAttempts: 4), 6 * 3600)
        XCTAssertEqual(SummaryQueue.delay(afterAttempts: 12), 6 * 3600)
    }

    func testClaudeCodeCommandLineAndProblems() {
        XCTAssertEqual(ClaudeSummariser.arguments(for: .standard), ["-p", "--output-format", "json"])
        XCTAssertEqual(ClaudeSummariser.arguments(for: .haiku), ["-p", "--output-format", "json", "--model", "haiku"])
        XCTAssertEqual(ClaudeSummariser.arguments(for: .sonnet).suffix(2), ["--model", "sonnet"])
        XCTAssertEqual(ClaudeSummariser.problem(in: "Claude AI usage limit reached|1762300000", stoppedWithError: true),
                       "Claude's usage limit was reached.")
        XCTAssertEqual(ClaudeSummariser.problem(in: "Invalid API key · Please run /login", stoppedWithError: true),
                       "Claude Code isn't signed in. Open Terminal, type claude, and sign in.")
        XCTAssertEqual(ClaudeSummariser.problem(in: "segfault", stoppedWithError: true), "Claude Code stopped with an error.")
    }

    /// The plan's test: a usage-limit failure leaves the draft queued, the
    /// queue survives quitting Warble, and once Claude works the note (moved
    /// and renamed by filing meanwhile) gets Claude's summary.
    @MainActor
    func testUsageLimitDraftIsReplacedOnceClaudeWorks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warble-queue-\(UUID().uuidString)")
        let calls = root.appendingPathComponent("Calls", isDirectory: true)
        let unfiled = calls.appendingPathComponent("Unfiled", isDirectory: true)
        try FileManager.default.createDirectory(at: unfiled, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queueFile = root.appendingPathComponent("summary-queue.json")

        var draft = call
        draft.summary = .done(appleDraft)
        let note = unfiled.appendingPathComponent(draft.fileName)
        try draft.markdown.write(to: note, atomically: true, encoding: .utf8)

        let queue = SummaryQueue(fileURL: queueFile)
        queue.callsFolder = { calls }
        queue.askClaude = { _, _ in .failure(CleanupFailure(reason: "Claude's usage limit was reached.")) }
        queue.add(draft, terms: [], savedAt: note, problem: "Claude's usage limit was reached.")
        await queue.tick(forced: false, now: Date().addingTimeInterval(31 * 60))
        XCTAssertEqual(queue.entries.count, 1)
        XCTAssertEqual(queue.entries.first?.attempts, 1)
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains(CallSummary.draftCallout))

        // Warble quits and opens again; meanwhile the note was filed and renamed.
        let relaunched = SummaryQueue(fileURL: queueFile)
        XCTAssertEqual(relaunched.entries.count, 1)
        XCTAssertEqual(relaunched.entries.first?.attempts, 1)
        let folder = calls.appendingPathComponent("1-1s/Valentina Rossi", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent(String(draft.fileName.prefix(15)) + " Mentoring chat.md")
        try FileManager.default.moveItem(at: note, to: moved)

        relaunched.callsFolder = { calls }
        let answer = claudes
        relaunched.askClaude = { _, _ in .success(answer) }
        var replaced = false
        relaunched.onReplaced = { _, _ in replaced = true }
        await relaunched.tick(forced: true)

        XCTAssertTrue(replaced)
        XCTAssertTrue(relaunched.entries.isEmpty)
        XCTAssertTrue(SummaryQueue(fileURL: queueFile).entries.isEmpty)
        let text = try String(contentsOf: moved, encoding: .utf8)
        XCTAssertFalse(text.contains(CallSummary.draftCallout))
        XCTAssertFalse(text.contains("summary_status"))
        XCTAssertTrue(text.contains("summarized_by: Claude (via Claude Code)"))
        XCTAssertTrue(text.contains("- [ ] **[[Valentina Rossi]]**: Decide on a mentor 📅 2027-01-22"))
    }
}
