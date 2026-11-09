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

final class SpeakerCheckTests: XCTestCase {
    private func voice(_ id: String, _ start: Double, _ end: Double) -> VoiceSegment {
        VoiceSegment(speakerID: id, start: start, end: end)
    }

    func testStatusesAndSharedNames() {
        let voices = [voice("A", 0, 10), voice("B", 10, 20), voice("C", 20, 30), voice("D", 30, 40), voice("E", 40, 41)]
        let names = ["A": "AJ", "B": "Jordan", "C": "Jordan", "D": "Priya?"]
        let prints: [String: [Float]] = ["A": [1, 0, 0], "B": [0, 1, 0], "C": [0, 0, 1], "D": [1, 1, 0]]
        let rows = SpeakerCheck.rows(voices: voices, names: names, namedLive: ["aj"], prints: prints) { _ in "" }
        XCTAssertEqual(rows.map(\.id), ["A", "B", "C", "D"])   // E spoke for 1 s: not listed
        XCTAssertEqual(rows.map(\.status), [.namedLive, .shared, .shared, .guess])
        XCTAssertEqual(rows.map(\.part), [nil, 1, 2, nil])
        XCTAssertEqual(rows[3].name, "Priya")
        XCTAssertEqual(rows[0].clip, 0...10)
        XCTAssertEqual(rows.filter(\.needsCheck).count, 3)
    }

    func testAClipRunsOnThroughTheirTurnUpToFifteenSeconds() {
        let turn = [voice("A", 0, 7), voice("A", 7.5, 12), voice("B", 12, 15), voice("A", 15, 18)]
        XCTAssertEqual(SpeakerCheck.clip(for: "A", in: turn), 0...12)   // stops when B talks
        let long = [voice("A", 0, 9), voice("A", 10, 31)]
        XCTAssertEqual(SpeakerCheck.clip(for: "A", in: long), 10...25)   // the longest stretch, capped
        XCTAssertNil(SpeakerCheck.clip(for: "Z", in: turn))
        let yeah = [voice("A", 0, 8), voice("B", 8.2, 8.8), voice("A", 9, 13), voice("B", 13, 20)]
        XCTAssertEqual(SpeakerCheck.clip(for: "A", in: yeah), 0...13)   // runs past B's "yeah", stops when B talks
    }

    func testAQuoteIsTheirLongestLinesInOrderUpToSixtyWords() {
        let lines = [CallTranscript.Segment(offset: 0, speaker: "Others", text: "Hi."),
                     CallTranscript.Segment(offset: 0, speaker: "Others", text: "We shipped the new build on Friday."),
                     CallTranscript.Segment(offset: 0, speaker: "Others", text: "Yes."),
                     CallTranscript.Segment(offset: 0, speaker: "Others", text: "The numbers look good this week.")]
        let quote = CallController.quote(of: "A", in: lines, voices: [voice("A", 0, 100)])
        // Short enough that all of it fits, in the order it was said.
        XCTAssertEqual(quote, "Hi. We shipped the new build on Friday. Yes. The numbers look good this week.")
        let long = (1...20).map { CallTranscript.Segment(offset: 0, speaker: "Others", text: String(repeating: "word ", count: $0)) }
        let capped = CallController.quote(of: "A", in: long, voices: [voice("A", 0, 100)])
        XCTAssertEqual(capped.split(separator: " ").count, CallController.quoteWords)
        XCTAssertTrue(capped.hasSuffix("…"))
    }

    func testAClickIsAboutWhoeverWasTalkingThenOrHadJustStopped() {
        let voices = [voice("A", 0, 5), voice("B", 6, 10), voice("A", 14, 20)]
        XCTAssertEqual(CallController.voice(at: 3, in: voices), "A")
        XCTAssertEqual(CallController.voice(at: 9.8, in: voices), "B")
        XCTAssertEqual(CallController.voice(at: 12, in: voices), "B")   // B had just stopped
        XCTAssertNil(CallController.voice(at: 30, in: voices))          // nobody near
    }

    func testOnlyTheTurnAtTheClickIsMoved() {
        // A talks at the click and carries on: its latest turn is the clicked one.
        let carriesOn = [voice("A", 0, 5), voice("A", 5.5, 9)]
        XCTAssertTrue(CallController.latestTurnCovers("A", at: 3, in: carriesOn))
        // A, then B, then A again: A's latest turn isn't the clicked one.
        let later = [voice("A", 0, 5), voice("B", 5, 8), voice("A", 8, 12)]
        XCTAssertFalse(CallController.latestTurnCovers("A", at: 3, in: later))
        // A short "yeah" from B doesn't end A's turn; a long pause does.
        XCTAssertTrue(CallController.latestTurnCovers("A", at: 3, in: [voice("A", 0, 5), voice("B", 5, 5.5), voice("A", 5.6, 9)]))
        XCTAssertFalse(CallController.latestTurnCovers("A", at: 3, in: [voice("A", 0, 5), voice("A", 9, 12)]))
    }

    func testSameNameAndSameVoiceIsNotShared() {
        let voices = [voice("B", 0, 10), voice("C", 10, 20), voice("X", 20, 30)]
        let rows = SpeakerCheck.rows(voices: voices, names: ["B": "Jordan", "C": "Jordan"], namedLive: [],
                                     prints: ["B": [1, 0], "C": [0.99, 0.05]]) { _ in "" }
        XCTAssertEqual(rows.map(\.status), [.recognised, .recognised, .unnamed])
    }
}
