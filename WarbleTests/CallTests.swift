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

    func testDatesAreInLocalTimeNotUTC() {
        var t = CallTranscript(appName: "Microsoft Teams", started: start)
        t.add(speaker: "Me", text: "Hello.", at: start.addingTimeInterval(5))
        t.ended = start.addingTimeInterval(60)
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let md = t.markdown
        XCTAssertTrue(md.contains("date: \(local.string(from: start))\n"))
        XCTAssertTrue(md.contains("ended: \(local.string(from: start.addingTimeInterval(60)))\n"))
        XCTAssertFalse(md.contains("Z\n"))
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

@MainActor
final class LiveSpeakerTests: XCTestCase {
    private func voice(_ id: String, _ start: Double, _ end: Double) -> VoiceSegment {
        VoiceSegment(speakerID: id, start: start, end: end)
    }

    func testBeforeVoicesAreKnownShowsYouAndOthers() {
        let list = CallController.liveSpeakers(meTalking: false, meLevel: 0, meThreshold: 0.02, othersTalking: true,
                                               voices: [], asking: nil, name: { $0 })
        XCTAssertEqual(list.map(\.name), ["You", "Others"])
        XCTAssertEqual(list.map(\.isSpeaking), [false, true])
    }

    func testLatestVoiceLightsUpAndShortBlipsAreHidden() {
        let voices = [voice("S1", 0, 5), voice("S2", 5, 8), voice("S3", 8, 8.5), voice("S1", 9, 12)]
        let list = CallController.liveSpeakers(meTalking: false, meLevel: 0, meThreshold: 0.02, othersTalking: true,
                                               voices: voices, asking: nil, name: { $0 == "S1" ? "Sarah" : "Speaker 2" })
        XCTAssertEqual(list.map(\.name), ["You", "Sarah", "Speaker 2"])
        XCTAssertEqual(list.map(\.isSpeaking), [false, true, false])
    }

    func testVoiceBeingAskedAboutIsNew() {
        let voices = [voice("S1", 0, 1)]
        let list = CallController.liveSpeakers(meTalking: false, meLevel: 0, meThreshold: 0.02, othersTalking: false,
                                               voices: voices, asking: "S1", name: { $0 })
        XCTAssertEqual(list.last?.name, "New voice")
        XCTAssertEqual(list.last?.isNew, true)
    }

    func testYourMicHearingTheSpeakersDoesNotLightYouUp() {
        let quiet = CallController.liveSpeakers(meTalking: true, meLevel: 0.03, meThreshold: 0.02, othersTalking: true,
                                                voices: [], asking: nil, name: { $0 })
        XCTAssertFalse(quiet[0].isSpeaking)
        let loud = CallController.liveSpeakers(meTalking: true, meLevel: 0.2, meThreshold: 0.02, othersTalking: true,
                                               voices: [], asking: nil, name: { $0 })
        XCTAssertTrue(loud[0].isSpeaking)
    }
}

@MainActor
final class SpeakingMeterTests: XCTestCase {
    func testHoldsBrieflyAfterSpeech() {
        let meter = SpeakingMeter(threshold: 0.02)
        let t = Date()
        meter.record(level: 0.1, at: t)
        meter.record(level: 0.001, at: t.addingTimeInterval(0.2))
        XCTAssertTrue(meter.isSpeaking(now: t.addingTimeInterval(0.3)))
        XCTAssertFalse(meter.isSpeaking(now: t.addingTimeInterval(1.0)))
    }

    func testElapsedTimeFormat() {
        XCTAssertEqual(ElapsedTime.format(64), "1:04")
        XCTAssertEqual(ElapsedTime.format(3725), "1:02:05")
    }
}

@MainActor
final class CallDetectorTests: XCTestCase {
    private let teams = MicUser(bundleID: "com.microsoft.teams2", pid: 100)
    private let zoom = MicUser(bundleID: "us.zoom.xos", pid: 200)

    private func detector() -> (CallDetector, () -> [String]) {
        let d = CallDetector()
        d.enabledApps = ["Microsoft Teams", "Zoom"]
        var events: [String] = []
        d.onCallStarted = { events.append("start \($0.app.name)") }
        d.onCallEnded = { events.append("end \($0.app.name)") }
        return (d, { events })
    }

    func testBackToBackCallsWithAShortGapAreTwoCalls() {
        let (d, events) = detector()
        let t = Date()
        d.update(users: [teams], now: t)
        d.update(users: [teams], now: t.addingTimeInterval(60))
        d.update(users: [], now: t.addingTimeInterval(61))
        d.update(users: [], now: t.addingTimeInterval(67))   // 6 s quiet: call over
        d.update(users: [teams], now: t.addingTimeInterval(69))
        XCTAssertEqual(events(), ["start Microsoft Teams", "end Microsoft Teams", "start Microsoft Teams"])
    }

    func testBriefMicDropMidCallIsTheSameCall() {
        let (d, events) = detector()
        let t = Date()
        d.update(users: [teams], now: t)
        d.update(users: [teams], now: t.addingTimeInterval(9))
        d.update(users: [], now: t.addingTimeInterval(10))
        d.update(users: [], now: t.addingTimeInterval(13))   // 4 s quiet: AirPods switching
        d.update(users: [teams], now: t.addingTimeInterval(14))
        XCTAssertEqual(events(), ["start Microsoft Teams"])
    }

    func testAnotherAppUsingTheMicDoesNotEndTheCall() {
        let (d, events) = detector()
        let t = Date()
        d.update(users: [teams], now: t)
        d.update(users: [zoom, teams], now: t.addingTimeInterval(5))
        d.update(users: [teams], now: t.addingTimeInterval(10))
        XCTAssertEqual(events(), ["start Microsoft Teams"])
    }

    func testSwitchingStraightToAnotherCallApp() {
        let (d, events) = detector()
        let t = Date()
        d.update(users: [teams], now: t)
        d.update(users: [zoom], now: t.addingTimeInterval(30))
        d.update(users: [zoom], now: t.addingTimeInterval(36))
        XCTAssertEqual(events(), ["start Microsoft Teams", "end Microsoft Teams", "start Zoom"])
    }
}
