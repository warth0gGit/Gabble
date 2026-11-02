import XCTest
@testable import Warble

/// Finding actions in a call, and reading Claude's answer.
final class ActionSpotterTests: XCTestCase {
    /// Friday 15 January 2027, 08:00 UTC.
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Jonny's test call from 1 November 2026, word for word. A pause split
    /// his commitment across two lines, and "close of play" was heard as
    /// "closer play". Apple Intelligence missed the action.
    private var jonnysCall: CallTranscript {
        var t = CallTranscript(appName: "Microsoft Teams", started: start)
        t.add(speaker: "Me", text: "Okay, we're gonna have another go at this. This time we're gonna talk about My day tomorrow. Fortunately, my wife Shadee will be joining us in the office tomorrow, so that's great. We will be talking about Claude code, and We will also be talking about a number of numbers, probably including the numbers 13 and 14. We're very lucky perhaps the number 15 as well. So the meetings tomorrow, I think, will go very, very well. A really important action for Shadee to take is to make sure that she leaves on time. And also, I think I have to go and get",
              at: start.addingTimeInterval(3))
        t.add(speaker: "Me", text: "An agreement from the chief executive by the closer play on Wednesday this week. Yeah, so I think that's probably it. Let's just see if this works. I'm just going to minimize. Oh, interesting, the minimize doesn't work.",
              at: start.addingTimeInterval(49))
        return t
    }

    func testFindsTheCommitmentSplitByAPause() {
        let found = ActionSpotter.candidates(in: jonnysCall)
        let ceo = found.first { $0.sentence.contains("chief executive") }
        XCTAssertNotNil(ceo)
        XCTAssertEqual(ceo?.sentence, "And also, I think I have to go and get An agreement from the chief executive by the closer play on Wednesday this week.")
        XCTAssertEqual(ceo?.offset, 3)
        XCTAssertEqual(ceo?.speaker, "Me")
        XCTAssertEqual(ceo?.isOwn, true)
        XCTAssertEqual(ceo?.hasDeadline, true)
        XCTAssertTrue(found.contains { $0.sentence.contains("Shadee to take") })
        XCTAssertFalse(found.contains { $0.sentence.contains("going to minimize") }, "not a task")
        XCTAssertEqual(ActionSpotter.deadline(in: ceo!.sentence), "by the closer play on wednesday")
    }

    func testCueWords() {
        func spotted(_ s: String) -> Bool { ActionSpotter.candidate(s, speaker: "Me", offset: 0) != nil }
        XCTAssertTrue(spotted("I'll send you the deck tonight."))
        XCTAssertTrue(spotted("We need to book the venue."))
        XCTAssertTrue(spotted("Let me check with finance."))
        XCTAssertTrue(spotted("Could you send me the numbers?"))
        XCTAssertTrue(spotted("Leave it with me."))
        XCTAssertFalse(spotted("I'll be honest, it went well."))
        XCTAssertFalse(spotted("The weather was lovely yesterday."))
        XCTAssertEqual(ActionSpotter.candidate("Sarah, can you send it by COB?", speaker: "Me", offset: 0)?.hasDeadline, true)
    }

    func testCoveredActionsAreNotCheckedAgain() {
        let ceo = ActionSpotter.candidates(in: jonnysCall).first { $0.sentence.contains("chief executive") }!
        XCTAssertFalse(ActionSpotter.isCovered(ceo, by: [.init(owner: "Me", task: "Minimize")]))
        XCTAssertTrue(ActionSpotter.isCovered(ceo, by: [.init(owner: "Me", task: "Get agreement from the chief executive", due: "Wednesday")]))
    }

    func testRepeatedActionsAreNotAddedTwice() {
        var actions: [CallSummary.ActionItem] = [.init(owner: "Me", task: "Get agreement from the chief executive")]
        CallSummariser.add(.init(owner: "Me", task: "get an agreement from the chief executive", due: "Wednesday"), to: &actions)
        CallSummariser.add(.init(owner: "Shadee", task: "Leave on time"), to: &actions)
        XCTAssertEqual(actions.map(\.task), ["Get agreement from the chief executive", "Leave on time"])
    }

    func testBritishDeadlines() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.dateFormat = "yyyy-MM-dd"
        func day(_ phrase: String) -> String? {
            CallSummary.dueDate(phrase, from: start, calendar: utc).map(f.string)
        }
        XCTAssertEqual(day("by close of play"), "2027-01-15")
        XCTAssertEqual(day("COB"), "2027-01-15")
        XCTAssertEqual(day("by the closer play on Wednesday"), "2027-01-20")
        XCTAssertEqual(day("end of day Monday"), "2027-01-18")
        XCTAssertEqual(day("2027-01-20"), "2027-01-20")
    }
}

final class ClaudeSummariserTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadsClaudeCodesAnswer() {
        let reply = """
        ```json
        {"headline": "Planning tomorrow's office day", "overview": "Jonny went over tomorrow's meetings.", \
        "keyPoints": ["Shadee joins the office tomorrow."], "decisions": [], \
        "actionItems": [{"owner": "Me", "task": "Get an agreement from the chief executive", "due": "2027-01-20"}, \
        {"owner": "Shadee", "task": "Leave on time", "due": ""}, {"owner": "", "task": "  ", "due": ""}], \
        "openQuestions": [], "topics": [{"start": "00:49", "title": "Chief executive sign-off"}], \
        "corrections": [{"heard": "closer play", "meant": "close of play"}, {"heard": "ok", "meant": "OK"}]}
        ```
        """
        let wrapper = try! JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false, "result": reply])
        let summary = ClaudeSummariser.parse(String(decoding: wrapper, as: UTF8.self))
        XCTAssertEqual(summary?.headline, "Planning tomorrow's office day")
        XCTAssertEqual(summary?.actionItems, [.init(owner: "Me", task: "Get an agreement from the chief executive", due: "2027-01-20"),
                                              .init(owner: "Shadee", task: "Leave on time", due: "")])
        XCTAssertEqual(summary?.topics, [.init(offset: 49, title: "Chief executive sign-off")])
        XCTAssertEqual(summary?.corrections, [.init(heard: "closer play", meant: "close of play")], "too-short fixes are ignored")
        XCTAssertEqual(summary?.writer, ClaudeSummariser.writer)
    }

    func testErrorsAndNonsenseGiveNoSummary() {
        XCTAssertNil(ClaudeSummariser.parse(#"{"type":"result","is_error":true,"result":"Invalid API key"}"#))
        XCTAssertNil(ClaudeSummariser.parse("Sorry, I can't help with that."))
        XCTAssertNil(ClaudeSummariser.parse(#"{"headline": ""}"#))
    }

    func testPromptCarriesTheCallAndRules() {
        var t = CallTranscript(appName: "Microsoft Teams", started: start)
        t.add(speaker: "Me", text: "I have to get sign-off by Wednesday.", at: start.addingTimeInterval(3))
        t.add(speaker: "Sarah Jones", text: "Great.", at: start.addingTimeInterval(9))
        let prompt = ClaudeSummariser.prompt(for: t, terms: ["Shadee"])
        XCTAssertTrue(prompt.contains("Other speakers: Sarah Jones."))
        XCTAssertTrue(prompt.contains("spelled correctly: Shadee."))
        XCTAssertTrue(prompt.contains("capture EVERY task"))
        XCTAssertTrue(prompt.hasSuffix("Me (00:03): I have to get sign-off by Wednesday.\nSarah Jones (00:09): Great."))
    }

    func testCorrectionsFixTheTranscript() {
        var t = CallTranscript(appName: "Teams", started: start)
        t.add(speaker: "Me", text: "By the closer play on Wednesday. Closer play is fine. Disclosure players.", at: start)
        t.apply([.init(heard: "closer play", meant: "close of play")])
        XCTAssertEqual(t.segments.first?.text, "By the close of play on Wednesday. close of play is fine. Disclosure players.")
    }

    func testSummaryWriterShowsInTheNote() {
        var t = CallTranscript(appName: "Teams", started: start)
        t.add(speaker: "Me", text: "Hello.", at: start)
        t.summary = .done(CallSummary(headline: "Hi", overview: "A test.", writer: ClaudeSummariser.writer))
        XCTAssertTrue(t.markdown.contains("summarized_by: \"Claude (via Claude Code)\"") || t.markdown.contains("summarized_by: Claude (via Claude Code)"))
    }
}
