import XCTest
@testable import Warble

final class CallTranscriptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testMergesConsecutiveLinesFromSameSpeaker() {
        var t = CallTranscript(appName: "Microsoft Teams", started: start)
        t.add(speaker: "Me", text: "Hi there.", at: start.addingTimeInterval(2))
        t.add(speaker: "Me", text: "Can you hear me?", at: start.addingTimeInterval(5))
        t.add(speaker: "Others", text: "Yes.", at: start.addingTimeInterval(7))
        XCTAssertEqual(t.segments.count, 2)
        XCTAssertEqual(t.segments[0].text, "Hi there. Can you hear me?")
        XCTAssertEqual(t.speakers, ["Me", "Others"])
    }

    func testMarkdownHasFrontMatterAndLines() {
        var t = CallTranscript(appName: "Microsoft Teams", started: start)
        t.add(speaker: "Others", text: "Morning.", at: start.addingTimeInterval(65))
        t.ended = start.addingTimeInterval(600)
        let md = t.markdown
        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("app: Microsoft Teams"))
        XCTAssertTrue(md.contains("duration_minutes: 10"))
        XCTAssertTrue(md.contains("speakers: [Others]"))
        XCTAssertTrue(md.contains("**Others** (01:05): Morning."))
        XCTAssertTrue(t.fileName.hasSuffix(" Teams call.md"))
    }

    func testTimestamps() {
        XCTAssertEqual(CallTranscript.timestamp(5), "00:05")
        XCTAssertEqual(CallTranscript.timestamp(3725), "1:02:05")
    }
}

final class CallAppTests: XCTestCase {
    func testMatchesEnabledAppsOnly() {
        XCTAssertEqual(CallApp.matching(bundleID: "com.microsoft.teams2", enabledNames: ["Microsoft Teams"])?.name,
                       "Microsoft Teams")
        XCTAssertEqual(CallApp.matching(bundleID: "us.zoom.xos", enabledNames: ["Zoom"])?.name, "Zoom")
        XCTAssertNil(CallApp.matching(bundleID: "us.zoom.xos", enabledNames: ["Microsoft Teams"]))
        XCTAssertEqual(CallApp.matching(bundleID: "com.google.Chrome.helper", enabledNames: ["Google Meet"])?.name,
                       "Google Meet")
    }
}
