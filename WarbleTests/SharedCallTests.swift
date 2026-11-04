import XCTest
@testable import Warble

/// Sharing a call: the saved note boiled down to what goes in the PDF.
final class SharedCallTests: XCTestCase {
    private let note = """
    ---
    title: "Orchestrate review, Nov 4, 2026, 2:00 PM"
    date: 2026-11-04T14:00:00
    ended: 2026-11-04T14:31:00
    duration_minutes: 31
    app: Microsoft Teams
    people: ["[[Sarah Jones]]", "[[Matt]]"]
    category: Projects/Orchestrate
    summarized_by: Claude
    ---

    # Orchestrate review, Nov 4, 2026, 2:00 PM

    With [[Sarah Jones]], [[Matt]]

    > [!summary] Summary
    > - The sandbox is ready for **testing**.
    > - Launch moves to next week.

    ## Key points
    - Matt owns the [[Hawaii]] follow-up.

    ## Decisions
    - Go with the smaller pilot.

    ## Action items
    - [ ] **Me**: send the deck 📅 2026-11-07
    - [ ] **[[Sarah Jones]]**: book the room

    ## Topics
    - 00:00 Intro

    > [!quote]- Full transcript (31 min, 1,234 words)
    > **Sarah Jones** (00:05): Shall we start?
    >
    > **Me** (00:09): Yes, let's go.
    """

    func testTheNoteBecomesATidyCall() {
        let call = SharedCall.parse(note: note, me: "Jonny Smith")
        XCTAssertEqual(call.name, "Orchestrate review", "the date has its own line")
        XCTAssertEqual(call.people, ["Jonny Smith", "Sarah Jones", "Matt"])
        XCTAssertEqual(call.summary, ["The sandbox is ready for testing.", "Launch moves to next week."])
        XCTAssertEqual(call.keyPoints, ["Matt owns the Hawaii follow-up."])
        XCTAssertEqual(call.decisions, ["Go with the smaller pilot."])
        XCTAssertEqual(call.actions.count, 2)
        XCTAssertEqual(call.actions.first?.owner, "Jonny Smith")
        XCTAssertEqual(call.actions.first?.task, "send the deck")
        XCTAssertNotNil(call.actions.first?.due)
        XCTAssertEqual(call.actions.last?.owner, "Sarah Jones")
        XCTAssertEqual(call.transcript, [
            SharedCall.Line(speaker: "Sarah Jones", time: "00:05", text: "Shall we start?"),
            SharedCall.Line(speaker: "Jonny Smith", time: "00:09", text: "Yes, let's go."),
        ])
        XCTAssertEqual(call.when, "Wednesday, November 4, 2026 · 2:00 PM – 2:31 PM (31 min)")
        XCTAssertEqual(call.fileName, "2026-11-04 Orchestrate review.pdf")
        XCTAssertEqual(SharedCall.describe(call.actions[0]), "Jonny Smith: send the deck (due Sat, Nov 7)")
    }

    func testAnApplePrevisionalDraftAndNoSummaryYet() {
        let draft = """
        ---
        date: 2026-11-04T09:00:00
        ---

        # Teams call Nov 4, 2026, 9:00 AM

        > [!note] Draft by Apple Intelligence. Claude will replace this when it's available.

        > [!summary] Summary
        > - Budget agreed.
        """
        XCTAssertEqual(SharedCall.parse(note: draft, me: "").summary, ["Budget agreed."])
        XCTAssertEqual(SharedCall.parse(note: draft, me: "").name, "Teams call")

        let pending = """
        # Teams call Nov 4, 2026, 9:00 AM

        > [!summary] Summary on its way
        > A summary and action items are being written.

        ## Transcript

        **Me** (00:01): Hello there.
        """
        let call = SharedCall.parse(note: pending, me: "")
        XCTAssertTrue(call.summary.isEmpty)
        XCTAssertEqual(call.transcript.map(\.speaker), ["Me"], "no name given, so Me stays")
    }

    func testCleaningUpObsidianMarkup() {
        XCTAssertEqual(SharedCall.plainText("Ask [[Sarah Jones|Sarah]] about **the deck**"), "Ask Sarah about the deck")
        XCTAssertEqual(SharedCall.meetingName("Weekly sync"), "Weekly sync")
    }
}
