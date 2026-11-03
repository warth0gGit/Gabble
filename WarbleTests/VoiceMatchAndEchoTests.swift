import XCTest
@testable import Warble

final class VoiceMatcherTests: XCTestCase {
    /// A unit-length voice fingerprint pointing mostly along one axis.
    private func voice(_ axis: Int, blend other: Int? = nil, amount: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[axis] = 1
        if let other { v[other] = amount }
        return v
    }

    func testDistance() {
        XCTAssertEqual(VoiceMatcher.distance(voice(0), voice(0)), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceMatcher.distance(voice(0), voice(1)), 1, accuracy: 0.0001)
        XCTAssertEqual(VoiceMatcher.distance([], voice(1)), 2)
    }

    func testOnlyAClearMatchIsNamed() {
        let shadee = Voiceprint(name: "Shadee Young", embedding: voice(0))
        let sarah = Voiceprint(name: "Sarah", embedding: voice(1))
        // Shadee herself, a little different from last time.
        XCTAssertEqual(VoiceMatcher.match(voice(0, blend: 2, amount: 0.3), known: [shadee, sarah]), "Shadee Young")
        // A colleague who only sounds a bit like her: ask instead.
        XCTAssertNil(VoiceMatcher.match(voice(0, blend: 3, amount: 2), known: [shadee, sarah]))
        // Someone else entirely.
        XCTAssertNil(VoiceMatcher.match(voice(4), known: [shadee, sarah]))
        // Close to two people on file: too close to call.
        XCTAssertNil(VoiceMatcher.match(voice(0, blend: 1, amount: 0.9), known: [shadee, sarah]))
        XCTAssertNil(VoiceMatcher.match(voice(0), known: []))
    }

    func testANewVoiceMidCallIsSomeoneAlreadyOnIt() {
        let shadee = Voiceprint(name: "Shadee Young", embedding: voice(0))
        let jala = Voiceprint(name: "Jala", embedding: voice(1))
        // Jala's voice drifted partway between her and Shadee, slightly nearer Shadee.
        let drifted = voice(1, blend: 0, amount: 1.1)
        XCTAssertEqual(VoiceMatcher.matchInCall(drifted, onCall: [jala], saved: [shadee]), "Jala")
        // Shadee really joins: a near-perfect match to her beats a loose one to Jala.
        XCTAssertEqual(VoiceMatcher.matchInCall(voice(0, blend: 2, amount: 0.1), onCall: [jala], saved: [shadee, jala]),
                       "Shadee Young")
        // Nobody on the call yet: the usual rules.
        XCTAssertEqual(VoiceMatcher.matchInCall(voice(0), onCall: [], saved: [shadee]), "Shadee Young")
    }

    func testAFifthPersonOnABigCallIsNotFoldedIntoTheFirstFour() {
        let onCall = (1...4).map { Voiceprint(name: "Person \($0)", embedding: voice($0)) }
        // Someone new who only sounds a bit like Person 1: ask, don't merge.
        XCTAssertNil(VoiceMatcher.matchInCall(voice(1, blend: 5, amount: 1.8), onCall: onCall, saved: []))
        // Sits between two people on the call: too close to call.
        XCTAssertNil(VoiceMatcher.matchInCall(voice(1, blend: 2, amount: 0.9), onCall: onCall, saved: []))
        // Person 1 again, slightly different: still them.
        XCTAssertEqual(VoiceMatcher.matchInCall(voice(1, blend: 5, amount: 0.3), onCall: onCall, saved: []), "Person 1")
    }
}

final class EchoFilterTests: XCTestCase {
    private func seg(_ speaker: String, _ offset: TimeInterval, _ text: String) -> CallTranscript.Segment {
        CallTranscript.Segment(offset: offset, speaker: speaker, text: text)
    }

    /// Lines from Jonny's call on the MacBook speakers, 2 November 2026.
    func testEchoesOfTheOthersAreRemovedAndYourWordsKept() {
        let segments = [
            seg("Others", 21, "A sentence or two to test your audio"),
            seg("Me", 21, "A sentence or two to test your audio. Shit, I didn't know"),
            seg("Others", 81, "Yeah, that's funny. So, how did you build it?"),
            seg("Me", 85, "So, how did you build it? Claude. Nice."),
            seg("Others", 1093, "Okay. I think we can get somebody to, you know, get us some preview of what they're how we could really partner with them specifically. What is the best way, right?"),
            seg("Me", 1094, "We can get somebody to Get us some preview of what they're how we could really partner with them specifically. What is the best way, right?"),
        ]
        let cleaned = EchoFilter.removeEchoes(from: segments)
        XCTAssertEqual(cleaned.filter { $0.speaker == "Me" }.map(\.text), ["Shit, I didn't know", "Claude. Nice."])
        XCTAssertEqual(cleaned.filter { $0.speaker == "Others" }.count, 3, "the others' lines are untouched")
    }

    func testYourOwnWordsAreKeptWhenNobodyElseSaidThem() {
        let segments = [
            seg("Others", 10, "What's for breakfast?"),
            seg("Me", 14, "Raisin bran with blueberries."),
            seg("Me", 300, "A sentence or two to test your audio."),   // long after: not an echo
        ]
        XCTAssertEqual(EchoFilter.removeEchoes(from: segments), segments)
    }

    func testCallsWithOnlyYouAreUnchanged() {
        let segments = [seg("Me", 0, "Just me talking to myself.")]
        XCTAssertEqual(EchoFilter.removeEchoes(from: segments), segments)
    }
}
