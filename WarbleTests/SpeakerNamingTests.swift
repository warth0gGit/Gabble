import XCTest
@testable import Warble

final class NameSuggestionTests: XCTestCase {
    func testHeardNameAndSoundsLikeBecomeOneSuggestion() {
        let list = NameSuggestion.build(hint: "Matt", candidates: [("Matt Kern", 0.4), ("Priya", 0.55)], onCall: [])
        XCTAssertEqual(list.map(\.name), ["Matt Kern", "Priya"])
        XCTAssertEqual(list.first?.reason, "heard “Matt”, sounds like them")
    }

    func testHeardNameAloneIsStillOffered() {
        let list = NameSuggestion.build(hint: "Priya", candidates: [("Matt Kern", 0.4)], onCall: [])
        XCTAssertEqual(list.map(\.name), ["Priya", "Matt Kern"])
        XCTAssertEqual(list.first?.reason, "heard “Priya”")
    }

    func testSomeoneOnTheCallComesLastAndJoins() {
        let list = NameSuggestion.build(hint: nil, candidates: [("Priya", 0.5)], onCall: [("AJ", "S2", 0.3)])
        XCTAssertEqual(list.map(\.title), ["Priya", "Same person as AJ"])
        XCTAssertEqual(list.last?.joins, "S2")
        XCTAssertNil(list.first?.joins)
    }

    func testAtMostThreeAndEachNameOnce() {
        let list = NameSuggestion.build(hint: "Matt", candidates: [("matt", 0.3), ("A", 0.4), ("B", 0.5), ("C", 0.6)],
                                        onCall: [("D", "S3", 0.2)])
        XCTAssertEqual(list.map(\.name), ["matt", "A", "B"])
    }
}

@MainActor
final class LiveSpeakerNamingTests: XCTestCase {
    private func voice(_ id: String, _ start: Double, _ end: Double) -> VoiceSegment {
        VoiceSegment(speakerID: id, start: start, end: end)
    }

    func testAGuessIsMarked() {
        let voices = [voice("S1", 0, 5), voice("S2", 5, 9)]
        let list = CallController.liveSpeakers(meTalking: false, meLevel: 0, meThreshold: 0.02, othersTalking: true,
                                               voices: voices, asking: nil,
                                               name: { $0 == "S1" ? "Jordan Smith" : "Shadee" },
                                               confidence: ["S1": .tentative, "S2": .recognised])
        XCTAssertEqual(list.map(\.isTentative), [false, true, false])
        XCTAssertEqual(list[1].fullName, "Jordan Smith")
        XCTAssertEqual(list[1].name, "Jordan")
    }

    func testTwoDifferentVoicesWithOneNameShowAsShared() {
        let voices = [voice("S1", 0, 5), voice("S2", 5, 9)]
        let list = CallController.liveSpeakers(meTalking: false, meLevel: 0, meThreshold: 0.02, othersTalking: true,
                                               voices: voices, asking: nil, name: { _ in "Jordan" },
                                               confidence: ["S1": .recognised, "S2": .recognised],
                                               conflicted: ["jordan"])
        XCTAssertEqual(list.map(\.name), ["You", "Jordan"])
        XCTAssertEqual(list[1].shared, 2)
        XCTAssertTrue(list[1].isSpeaking)
    }
}

@MainActor
final class KnownVoicesTests: XCTestCase {
    private func person(_ name: String, _ embedding: [Float], samples: Int = 1) -> Voiceprint {
        Voiceprint(name: name, embedding: embedding, samples: Array(repeating: embedding, count: samples))
    }

    func testInitialsTellSimilarNamesApart() {
        XCTAssertEqual(KnownVoicesSection.initials("AJ Patel", among: []), "AP")
        XCTAssertEqual(KnownVoicesSection.initials("AJ", among: []), "AJ")
        XCTAssertEqual(KnownVoicesSection.initials("Matt Kern", among: []), "MK")
        XCTAssertEqual(KnownVoicesSection.initials("Matt", among: []), "M")
    }

    func testStrengthGrowsWithRecordings() {
        XCTAssertEqual(KnownVoicesSection.strength(person("A", [1, 0], samples: 1)).label, "Still learning")
        XCTAssertEqual(KnownVoicesSection.strength(person("A", [1, 0], samples: 3)).bars, 2)
        XCTAssertEqual(KnownVoicesSection.strength(person("A", [1, 0], samples: 8)).bars, 4)
    }

    func testShortNameWithACloseVoiceIsALikelyDuplicate() {
        let matt = person("Matt", [1, 0])
        let mattKern = person("Matt Kern", [0.99, 0.05])
        let other = person("Matthew Lee", [0, 1])
        XCTAssertEqual(KnownVoicesSection.likelyDuplicate(of: matt, in: [matt, mattKern, other])?.name, "Matt Kern")
        XCTAssertNil(KnownVoicesSection.likelyDuplicate(of: mattKern, in: [matt, mattKern]))
        XCTAssertNil(KnownVoicesSection.likelyDuplicate(of: person("Matt", [0, 1]), in: [mattKern]))
    }
}
