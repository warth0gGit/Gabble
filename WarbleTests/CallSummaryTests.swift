import XCTest
@testable import Warble

final class CallSummaryTests: XCTestCase {
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

    private var sample: CallSummary {
        CallSummary(
            headline: "Acme renewal at risk: revised offer by Friday",
            overview: "Acme wants to renew but pushed back on price.",
            keyPoints: ["Renewal due 15 December."],
            decisions: [],
            actionItems: [
                .init(owner: "Sarah Jones", task: "get the competitor's quote", due: "by Wednesday"),
                .init(owner: "Me", task: "send the revised offer", due: "by Friday"),
            ],
            openQuestions: ["Will finance approve 6%?"],
            topics: [.init(offset: 460, title: "Pricing"), .init(offset: 0, title: "Where things stand")])
    }

    // MARK: - Due dates

    func testDueDatesCountFromTheCallDay() {
        XCTAssertEqual(day("by Friday"), "2027-01-22")      // the call is on a Friday, so next week's
        XCTAssertEqual(day("Wednesday"), "2027-01-20")
        XCTAssertEqual(day("tomorrow"), "2027-01-16")
        XCTAssertEqual(day("end of the day"), "2027-01-15")
        XCTAssertEqual(day("by the end of the week"), "2027-01-15")
        XCTAssertEqual(day("by 7th February"), "2027-02-07")
        XCTAssertEqual(day("Feb 7"), "2027-02-07")
        XCTAssertEqual(day("January 3"), "2028-01-03")      // already passed, so next year
        XCTAssertNil(day("soon"))
        XCTAssertNil(day("next quarter"))
    }

    func testTaskLinesLinkPeopleAndDates() {
        let people = ["Sarah Jones"]
        XCTAssertEqual(CallSummary.task(.init(owner: "sarah jones", task: "send the deck", due: "by Friday"),
                                        people: people, callDate: start, calendar: utc),
                       "- [ ] **[[Sarah Jones]]**: send the deck 📅 2027-01-22")
        XCTAssertEqual(CallSummary.task(.init(owner: "Speaker 2", task: "check the numbers", due: "next quarter"),
                                        people: people, callDate: start, calendar: utc),
                       "- [ ] **Speaker 2**: check the numbers (next quarter)")
        XCTAssertEqual(CallSummary.task(.init(owner: "", task: "book a room"), people: people, callDate: start, calendar: utc),
                       "- [ ] book a room")
    }

    // MARK: - The note

    func testNoteWithSummaryFoldsTheTranscript() {
        var t = CallTranscript(appName: "Microsoft Teams", started: start)
        t.add(speaker: "Others", text: "Morning.", at: start.addingTimeInterval(65))
        t.add(speaker: "Me", text: "Hi Sarah.", at: start.addingTimeInterval(70))
        t.ended = start.addingTimeInterval(600)
        t.summary = .done(sample)
        let md = t.markdown
        XCTAssertTrue(md.contains("summary: \"Acme renewal at risk: revised offer by Friday\""))
        XCTAssertTrue(md.contains("summarized_by: Apple Intelligence (on this Mac)"))
        XCTAssertTrue(md.contains("> [!summary] Summary\n> Acme wants to renew but pushed back on price."))
        XCTAssertTrue(md.contains("## Key points\n- Renewal due 15 December."))
        XCTAssertFalse(md.contains("## Decisions"), "empty sections are left out")
        XCTAssertTrue(md.contains("## Open questions\n- Will finance approve 6%?"))
        XCTAssertTrue(md.contains("## Topics\n- 00:00 Where things stand\n- 07:40 Pricing"))
        XCTAssertTrue(md.contains("> [!quote]- Full transcript (10 min, 3 words)"))
        XCTAssertTrue(md.contains("> **Others** (01:05): Morning.\n>\n> **Me** (01:10): Hi Sarah."))
        // Your own actions come first.
        let mine = md.range(of: "send the revised offer")!.lowerBound
        let hers = md.range(of: "get the competitor's quote")!.lowerBound
        XCTAssertLessThan(mine, hers)
        // The summary sits between the title and the transcript.
        XCTAssertLessThan(md.range(of: "# ")!.lowerBound, md.range(of: "[!summary]")!.lowerBound)
        XCTAssertLessThan(md.range(of: "## Topics")!.lowerBound, md.range(of: "[!quote]-")!.lowerBound)
    }

    func testNoteSaysWhenSummaryIsComingOrFailed() {
        var t = CallTranscript(appName: "Zoom", started: start)
        t.add(speaker: "Others", text: "Morning.", at: start.addingTimeInterval(65))
        t.summary = .pending
        XCTAssertTrue(t.markdown.contains("[!summary] Summary on its way"))
        XCTAssertTrue(t.markdown.contains("## Transcript\n\n**Others** (01:05): Morning."))
        XCTAssertFalse(t.markdown.contains("summarized_by"))
        t.summary = .failed("Apple Intelligence took too long to answer.")
        XCTAssertTrue(t.markdown.contains("> [!warning] No summary\n> Warble couldn't write a summary of this call: Apple Intelligence took too long to answer."))
    }

    func testPartSkippedIsMentioned() {
        var summary = sample
        summary.skippedParts = 1
        XCTAssertTrue(summary.markdownLines(people: [], callDate: start).joined(separator: "\n")
            .contains("Part of this call couldn't be summarized"))
    }

    // MARK: - Chunks

    func testChunksKeepEveryWordAndStayUnderTheLimit() {
        var t = CallTranscript(appName: "Teams", started: start)
        let hundred = Array(repeating: "word", count: 100).joined(separator: " ")
        for i in 0..<12 {
            t.add(speaker: i % 2 == 0 ? "Me" : "Sarah", text: hundred, at: start.addingTimeInterval(Double(i * 30 + 1)))
        }
        t.add(speaker: "Me", text: Array(repeating: "long", count: 600).joined(separator: " "), at: start.addingTimeInterval(500))
        let chunks = SummaryChunker.chunks(of: t, maxWords: 250)
        XCTAssertEqual(chunks.map(\.words).reduce(0, +), 1800)
        XCTAssertTrue(chunks.allSatisfy { $0.words <= 250 })
        XCTAssertTrue(chunks.allSatisfy { chunk in chunk.words == SummaryChunker.wordCount(
            chunk.lines.map { $0.components(separatedBy: "): ").dropFirst().joined(separator: "): ") }.joined(separator: " ")) })
        XCTAssertTrue(chunks[0].lines[0].hasPrefix("Me (00:01): word"))
        // Turns that fit aren't split: 100-word turns go two to a 250-word chunk.
        XCTAssertEqual(chunks[0].words, 200)
        XCTAssertEqual(chunks.first?.start, 1)
        XCTAssertLessThan(chunks[0].start, chunks[1].start)
    }

    func testShortCallsAreNotSummarised() {
        var t = CallTranscript(appName: "Teams", started: start)
        t.add(speaker: "Me", text: "Can you hear me? I'll call you back.", at: start.addingTimeInterval(3))
        XCTAssertFalse(CallSummariser.isWorthSummarising(t))
        t.add(speaker: "Others", text: Array(repeating: "yes", count: 80).joined(separator: " "), at: start.addingTimeInterval(9))
        XCTAssertTrue(CallSummariser.isWorthSummarising(t))
    }

    func testTimestamps() {
        XCTAssertEqual(SummaryChunker.offset(fromTimestamp: "07:40"), 460)
        XCTAssertEqual(SummaryChunker.offset(fromTimestamp: "(12:05)"), 725)
        XCTAssertEqual(SummaryChunker.offset(fromTimestamp: "1:07:40"), 4060)
        XCTAssertNil(SummaryChunker.offset(fromTimestamp: "7.40"))
        XCTAssertNil(SummaryChunker.offset(fromTimestamp: "07:75"))
    }

    // MARK: - Tidying and combining

    func testOwnersAndEmptyAnswers() {
        XCTAssertEqual(CallSummariser.owner("I"), "Me")
        XCTAssertEqual(CallSummariser.owner("me"), "Me")
        XCTAssertEqual(CallSummariser.owner("Unassigned"), "")
        XCTAssertEqual(CallSummariser.owner("N/A"), "")
        XCTAssertEqual(CallSummariser.owner("Sarah Jones"), "Sarah Jones")
        XCTAssertEqual(CallSummariser.cleanList(["- First", "None", "  ", "• Second"]), ["First", "Second"])
        XCTAssertEqual(CallSummariser.nothingToEmpty("Not specified."), "")
    }

    func testCombiningPartsDropsRepeats() {
        var a = sample
        a.topics = [.init(offset: 0, title: "Start")]
        var b = sample
        b.overview = "They agreed a 6% offer."
        b.keyPoints = ["renewal due 15 December.", "Usage is up 40%."]
        b.actionItems = [.init(owner: "Me", task: "Send the revised offer"), .init(owner: "Mark", task: "confirm dates")]
        b.topics = [.init(offset: 700, title: "Agreeing the offer")]
        b.skippedParts = 1
        let combined = CallSummary.combined([a, b])!
        XCTAssertEqual(combined.overview, "Acme wants to renew but pushed back on price. They agreed a 6% offer.")
        XCTAssertEqual(combined.keyPoints, ["Renewal due 15 December.", "Usage is up 40%."])
        XCTAssertEqual(combined.actionItems.map(\.task), ["get the competitor's quote", "send the revised offer", "confirm dates"])
        XCTAssertEqual(combined.topics.map(\.title), ["Start", "Agreeing the offer"])
        XCTAssertEqual(combined.skippedParts, 1)
        XCTAssertTrue(b.asNotes.contains("Action items:\n- Me: Send the revised offer\n- Mark: confirm dates"))
    }
}
