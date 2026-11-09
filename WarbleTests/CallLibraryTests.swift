import XCTest
@testable import Warble

/// The Transcripts and People tabs: reading notes back, folders, day groups,
/// search and who is on which calls.
final class CallLibraryTests: XCTestCase {
    private let calls = URL(fileURLWithPath: "/tmp/Warble Test/Calls", isDirectory: true)

    private func date(_ text: String) -> Date {
        CallTranscript.isoFormatter.date(from: text)!
    }

    private func note(category: String = "Projects/Atlas", started: String = "2026-11-09T09:30:00") -> String {
        var call = CallTranscript(appName: "Microsoft Teams", started: date(started))
        call.ended = call.started.addingTimeInterval(32 * 60)
        call.category = category
        call.customName = "Atlas weekly sync"
        call.add(speaker: "Me", text: "Morning all", at: call.started.addingTimeInterval(5))
        call.add(speaker: "Sarah Jones", text: "The data fix lands by Friday close of play", at: call.started.addingTimeInterval(20))
        call.add(speaker: "Others", text: "Sounds good", at: call.started.addingTimeInterval(40))
        call.add(speaker: "Matt?", text: "I'll take the budget", at: call.started.addingTimeInterval(60))
        return call.markdown
    }

    private func entry(category: String = "Projects/Atlas", started: String = "2026-11-09T09:30:00") -> CallEntry {
        let folder = category == "Unfiled" ? "Unfiled" : category
        let url = calls.appendingPathComponent(folder).appendingPathComponent("note.md")
        return CallLibraryLogic.entry(note: note(category: category, started: started), url: url, callsFolder: calls)!
    }

    func testReadsTheNoteBack() {
        let call = entry()
        XCTAssertEqual(call.name, "Atlas weekly sync")
        XCTAssertEqual(call.started, date("2026-11-09T09:30:00"))
        XCTAssertEqual(call.minutes, 32)
        XCTAssertEqual(call.shortApp, "Teams")
        XCTAssertEqual(call.folder, "Projects/Atlas")
        XCTAssertEqual(call.people, ["Sarah Jones"])
        XCTAssertEqual(call.unnamedVoices, 2)   // "Others" and the guess "Matt?"
        XCTAssertEqual(call.lines.count, 4)
        XCTAssertFalse(call.summaryPending)
    }

    func testNotesThatArentCallsAreSkipped() {
        XCTAssertNil(CallLibraryLogic.entry(note: "# My own note\nHello", url: calls.appendingPathComponent("x.md"), callsFolder: calls))
    }

    func testUnfiledNotesHaveNoFolder() {
        XCTAssertTrue(entry(category: "Unfiled").isUnfiled)
        XCTAssertEqual(CallLibraryLogic.folder(of: calls.appendingPathComponent("a.md"), callsFolder: calls), "")
    }

    func testInlineList() {
        XCTAssertEqual(CallLibraryLogic.inlineList(#"[Me, "Jordan?", Speaker 2, "A, B"]"#), ["Me", "Jordan?", "Speaker 2", "A, B"])
        XCTAssertEqual(CallLibraryLogic.inlineList("[]"), [])
        XCTAssertEqual(CallLibraryLogic.inlineList("nope"), [])
    }

    func testFolderTreeIncludesParents() {
        var a = entry(); a.folder = "Projects/Atlas"
        var b = entry(); b.folder = "Clients/Acme"
        var c = entry(); c.folder = ""
        let tree = CallLibraryLogic.folderTree([a, b, c])
        XCTAssertEqual(tree.map(\.path), ["Clients", "Clients/Acme", "Projects", "Projects/Atlas"])
        XCTAssertEqual(tree.first { $0.path == "Projects" }?.count, 1)
        XCTAssertEqual(tree.first { $0.path == "Projects/Atlas" }?.depth, 1)
        XCTAssertEqual(tree.first { $0.path == "Projects/Atlas" }?.name, "Atlas")
    }

    func testDayGroups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = date("2026-11-11T12:00:00")   // a Wednesday
        XCTAssertEqual(CallLibraryLogic.dayGroup(date("2026-11-11T08:00:00"), now: now, calendar: calendar), "Today")
        XCTAssertEqual(CallLibraryLogic.dayGroup(date("2026-11-10T08:00:00"), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(CallLibraryLogic.dayGroup(date("2026-11-09T08:00:00"), now: now, calendar: calendar), "Earlier this week")
        XCTAssertEqual(CallLibraryLogic.dayGroup(date("2026-11-04T08:00:00"), now: now, calendar: calendar), "Last week")
        XCTAssertEqual(CallLibraryLogic.dayGroup(date("2026-10-20T08:00:00"), now: now, calendar: calendar), "October")
        XCTAssertEqual(CallLibraryLogic.dayGroup(date("2025-12-20T08:00:00"), now: now, calendar: calendar), "December 2025")
    }

    func testByDayKeepsNewestFirst() {
        let older = entry(started: "2026-11-02T09:00:00")
        let newer = entry(started: "2026-11-09T09:00:00")
        let groups = CallLibraryLogic.byDay([older, newer], now: date("2026-11-09T12:00:00"))
        XCTAssertEqual(groups.first?.day, "Today")
        XCTAssertEqual(groups.first?.calls.first?.started, newer.started)
    }

    func testSearch() {
        let call = entry()
        XCTAssertTrue(CallLibraryLogic.match(call, query: "").matches)
        XCTAssertTrue(CallLibraryLogic.match(call, query: "atlas").matches)
        XCTAssertNil(CallLibraryLogic.match(call, query: "atlas").said)
        XCTAssertTrue(CallLibraryLogic.match(call, query: "sarah").matches)
        let said = CallLibraryLogic.match(call, query: "close of play")
        XCTAssertTrue(said.matches)
        XCTAssertEqual(said.said, "Sarah Jones: The data fix lands by Friday close of play")
        XCTAssertFalse(CallLibraryLogic.match(call, query: "giraffe").matches)
    }

    func testSnippetCentersOnTheMatch() {
        let text = String(repeating: "word ", count: 60) + "needle " + String(repeating: "more ", count: 60)
        let snippet = CallLibraryLogic.snippet(text, around: "needle", width: 60)
        XCTAssertTrue(snippet.contains("needle"))
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testPeopleStatsAndGroups() {
        var a = entry(started: "2026-11-09T09:00:00"); a.folder = "Projects/Atlas"
        var b = entry(started: "2026-11-05T09:00:00"); b.folder = "Projects/Atlas"
        var c = entry(started: "2026-11-08T09:00:00"); c.folder = "1-1s/Sarah Jones"
        let stats = CallLibraryLogic.stats(for: "sarah jones", in: [a, b, c])
        XCTAssertEqual(stats.calls.count, 3)
        XCTAssertEqual(stats.last, a.started)
        XCTAssertEqual(stats.mostlyIn, "Projects/Atlas")
        XCTAssertEqual(CallLibraryLogic.placeGroup(stats), "Projects")

        let nobody = CallLibraryLogic.stats(for: "Tom", in: [a, b, c])
        XCTAssertEqual(nobody.calls.count, 0)
        XCTAssertEqual(CallLibraryLogic.placeGroup(nobody), CallLibraryLogic.noCallsGroup)
        XCTAssertEqual(CallLibraryLogic.recentGroup(stats, now: date("2026-11-10T09:00:00")), "This week")
        XCTAssertEqual(CallLibraryLogic.recentGroup(stats, now: date("2027-01-10T09:00:00")), "Earlier")
    }

    func testRecategorisedUpdatesTheFrontMatter() {
        let moved = CallLibraryLogic.recategorised(note(), folder: "Clients/Acme")
        XCTAssertTrue(NoteRewriter.frontMatter(of: moved).contains("category: Clients/Acme"))
        XCTAssertFalse(moved.contains("category: Projects/Atlas"))
    }

    func testMoveFilesTheNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Calls")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let from = root.appendingPathComponent("Unfiled/2026-11-09 0930 Atlas weekly sync.md")
        try FileManager.default.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note(category: "Unfiled").write(to: from, atomically: true, encoding: .utf8)
        let to = try CallLibraryLogic.move(note: from, to: "Projects/Atlas", callsFolder: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: from.path))
        XCTAssertEqual(CallLibraryLogic.folder(of: to, callsFolder: root), "Projects/Atlas")
        let text = try String(contentsOf: to, encoding: .utf8)
        XCTAssertTrue(text.contains("category: Projects/Atlas"))
    }

    func testNeedsLook() {
        let call = entry(started: "2026-11-09T09:30:00")
        XCTAssertTrue(CallLibraryLogic.needsLook(call, now: date("2026-11-10T09:00:00")))
        XCTAssertFalse(CallLibraryLogic.needsLook(call, now: date("2026-12-10T09:00:00")))
    }
}
