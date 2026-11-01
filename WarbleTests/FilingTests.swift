import XCTest
@testable import Warble

final class FilingBrainTests: XCTestCase {
    /// Monday 2 Nov 2026, 12:00 in a fixed time zone.
    private let monday: Date = {
        var c = DateComponents(year: 2026, month: 11, day: 2, hour: 12, minute: 0)
        c.timeZone = TimeZone(identifier: "America/Chicago")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        return cal
    }

    private func call(series: String? = nil, title: String? = nil, people: [String] = [],
                      daysLater: Int = 0) -> CallFeatures {
        CallFeatures(seriesID: series, meetingTitle: title, people: people,
                     date: monday.addingTimeInterval(Double(daysLater) * 86_400), calendar: calendar)
    }

    func testNewOneToOneSuggestsAFolderForThePerson() {
        let suggestions = FilingBrain.suggestions(for: call(people: ["Sarah Jones"]), rules: [])
        XCTAssertEqual(suggestions.first?.folder, "1-1s/Sarah Jones")
        XCTAssertNil(FilingBrain.autoFolder(for: call(people: ["Sarah Jones"]), rules: []))
    }

    func testRepeatingMeetingIsFiledAutomaticallyAfterOneAnswer() {
        var rules: [FilingRule] = []
        FilingBrain.learn(call(series: "abc", title: "Weekly sync", people: ["Sarah", "Tom"]),
                          folder: "Team/Weekly sync", rules: &rules)
        let nextWeek = call(series: "abc", title: "Weekly sync", people: ["Sarah"], daysLater: 7)
        let auto = FilingBrain.autoFolder(for: nextWeek, rules: rules)
        XCTAssertEqual(auto?.folder, "Team/Weekly sync")
        XCTAssertEqual(auto?.reason, "same repeating meeting")
    }

    func testSamePersonWithoutCalendarStillMatches() {
        var rules: [FilingRule] = []
        FilingBrain.learn(call(people: ["Sarah Jones"]), folder: "1-1s/Sarah Jones", rules: &rules)
        let auto = FilingBrain.autoFolder(for: call(people: ["sarah jones"], daysLater: 7), rules: rules)
        XCTAssertEqual(auto?.folder, "1-1s/Sarah Jones")
    }

    func testTimeSlotAloneOnlySuggests() {
        var rules: [FilingRule] = []
        FilingBrain.learn(call(people: ["Sarah"]), folder: "1-1s/Sarah", rules: &rules)
        let unknown = call(daysLater: 7)
        XCTAssertNil(FilingBrain.autoFolder(for: unknown, rules: rules))
        XCTAssertEqual(FilingBrain.suggestions(for: unknown, rules: rules).first?.folder, "1-1s/Sarah")
    }

    func testCorrectionMovesTheMeetingToTheNewFolder() {
        var rules: [FilingRule] = []
        let weekly = call(series: "abc", title: "Weekly sync")
        FilingBrain.learn(weekly, folder: "Wrong", rules: &rules)
        FilingBrain.learn(weekly, folder: "Right", rules: &rules)
        XCTAssertEqual(FilingBrain.autoFolder(for: weekly, rules: rules)?.folder, "Right")
    }

    func testUnfiledIsNeverLearned() {
        var rules: [FilingRule] = []
        FilingBrain.learn(call(series: "abc"), folder: "Unfiled", rules: &rules)
        XCTAssertTrue(rules.isEmpty)
    }

    func testTitlesIgnoreDatesAndRescheduling() {
        XCTAssertEqual(FilingBrain.normalisedTitle("Weekly Sync – 3 Nov (moved)"), "weekly sync")
        XCTAssertEqual(FilingBrain.normalisedTitle("Updated invitation: Weekly sync"), "weekly sync")
    }

    func testFolderNamesAreSafe() {
        XCTAssertEqual(FolderName.clean(" 1:1s / Sarah: Jones. "), "1 1s/Sarah Jones")
        XCTAssertEqual(FolderName.clean("a//b"), "a/b")
        XCTAssertEqual(FolderName.fileName("Q3 / Q4 planning"), "Q3 - Q4 planning")
    }

    func testPicksTheMeetingUnderWay() {
        let now = monday
        let earlier = MeetingCandidate(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600),
                                       attendeeCount: 3, mentionsCallApp: true, payload: "earlier")
        let current = MeetingCandidate(start: now.addingTimeInterval(-120), end: now.addingTimeInterval(1800),
                                       attendeeCount: 1, mentionsCallApp: true, payload: "current")
        let focusBlock = MeetingCandidate(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600),
                                          attendeeCount: 0, mentionsCallApp: false, payload: "focus")
        XCTAssertEqual(MeetingCandidate.best(of: [earlier, current, focusBlock], at: now)?.payload, "current")
        XCTAssertTrue(MeetingCandidate<String>.mentionsCallApp("Join: https://teams.microsoft.com/l/x", appName: "Microsoft Teams"))
    }
}

final class CallFilingMarkdownTests: XCTestCase {
    func testMeetingNameAndPeopleLinks() {
        var t = CallTranscript(appName: "Microsoft Teams", started: Date(timeIntervalSince1970: 1_800_000_000))
        t.meeting = MeetingInfo(title: "Weekly sync: Atlas", attendees: [.init(name: "Sarah Jones", email: "s@x.com")],
                                organizer: "Sarah Jones", seriesID: "abc",
                                start: t.started, end: t.started.addingTimeInterval(1800))
        t.add(speaker: "Me", text: "Hi.", at: t.started.addingTimeInterval(3))
        t.add(speaker: "Speaker 2", text: "Hello.", at: t.started.addingTimeInterval(5))
        XCTAssertEqual(t.people, ["Sarah Jones"])
        XCTAssertTrue(t.fileName.hasSuffix(" Weekly sync Atlas.md"))
        let md = t.markdown
        XCTAssertTrue(md.contains("people: [\"[[Sarah Jones]]\"]"))
        XCTAssertTrue(md.contains("meeting: \"Weekly sync: Atlas\""))
        XCTAssertTrue(md.contains("tags: [call, warble, recurring]"))
        XCTAssertTrue(md.contains("With [[Sarah Jones]]"))
    }
}
