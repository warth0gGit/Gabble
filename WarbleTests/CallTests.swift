import XCTest
@testable import Warble

final class CallTranscriptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testMergesConsecutiveLinesFromSameSpeaker() {
        var t = CallTranscript(appName: "Microsoft Teams", started: start)
        t.add(speaker: "Me", text: "Hi there.", at: start.addingTimeInterval(2))
        t.add(speaker: "Me", text: "Can you hear me?", at: start.addingTimeInterval(5))
        t.add(speaker: "Others", text: "Yes.", at: start.addingTimeInterval(7))
        XCTAssertEqual(t.segments.count, 3)
        XCTAssertEqual(t.merged.count, 2)
        XCTAssertEqual(t.merged[0].text, "Hi there. Can you hear me?")
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

    func testRelabelAndSpokenRange() {
        var t = CallTranscript(appName: "Zoom", started: start)
        t.add(speaker: "Others", text: "one two three four five", at: start.addingTimeInterval(10))
        let range = CallTranscript.spokenRange(of: t.segments[0])
        XCTAssertEqual(range.upperBound, 9.2, accuracy: 0.01)
        XCTAssertLessThan(range.lowerBound, range.upperBound)
        t.relabel { _ in "Sarah" }
        XCTAssertEqual(t.speakers, ["Sarah"])
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

final class SpeakerAssignerTests: XCTestCase {
    private let segments = [
        VoiceSegment(speakerID: "1", start: 0, end: 4),
        VoiceSegment(speakerID: "Sarah", start: 4, end: 10),
    ]

    func testPicksVoiceWithMostOverlap() {
        XCTAssertEqual(SpeakerAssigner.speaker(for: 3...8, in: segments), "Sarah")
        XCTAssertEqual(SpeakerAssigner.speaker(for: 0.5...3, in: segments), "1")
    }

    func testNearestVoiceWhenNoOverlap() {
        XCTAssertEqual(SpeakerAssigner.speaker(for: 11...12, in: segments), "Sarah")
        XCTAssertNil(SpeakerAssigner.speaker(for: 20...21, in: segments))
    }

    func testTalkTime() {
        XCTAssertEqual(SpeakerAssigner.talkTime(segments)["Sarah"], 6)
    }
}

@MainActor
final class VoiceprintStoreTests: XCTestCase {
    func testRemembersAndForgets() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let store = VoiceprintStore(fileURL: url)
        store.remember(name: " Sarah ", embedding: [0.1, 0.2])
        store.remember(name: "sarah", embedding: [0.3, 0.4])
        XCTAssertEqual(store.voices.count, 1)
        XCTAssertEqual(store.voices[0].embedding, [0.3, 0.4])
        XCTAssertEqual(VoiceprintStore(fileURL: url).voices.map(\.name), ["Sarah"])
        store.forget(store.voices[0])
        XCTAssertTrue(VoiceprintStore(fileURL: url).voices.isEmpty)
    }
}
