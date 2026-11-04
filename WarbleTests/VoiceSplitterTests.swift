import XCTest
@testable import Warble

/// Telling apart people the voice engine lumped together (Jonny's call on
/// 4 November: AJ and then Matt were both taken for Jordan).
final class VoiceSplitterTests: XCTestCase {
    private let jordan: [Float] = [1, 0, 0, 0]
    private let aj: [Float] = [0, 1, 0, 0]
    /// Close enough to Jordan that a loose check takes him for Jordan.
    private let matt: [Float] = [1, 0.9, 0, 0]

    private func say(_ voice: [Float], _ start: TimeInterval, _ end: TimeInterval, engine: String = "S1") -> VoiceSegment {
        VoiceSegment(speakerID: engine, start: start, end: end, embedding: voice)
    }

    private func ids(_ splitter: VoiceSplitter) -> [String] { splitter.segments.map(\.speakerID) }

    func testSomeoneElseLumpedInBecomesTheirOwnVoice() {
        var splitter = VoiceSplitter()
        splitter.add([say(jordan, 0, 3), say(jordan, 3, 6), say(jordan, 6, 9)])
        splitter.add([say(aj, 10, 13), say(aj, 13, 16)])
        XCTAssertEqual(ids(splitter), ["S1", "S1", "S1", "S1#2", "S1#2"])
        // From then on each is told apart, though the engine still calls both S1.
        splitter.add([say(jordan, 17, 20), say(aj, 20, 23)])
        XCTAssertEqual(ids(splitter).suffix(2), ["S1", "S1#2"])
        XCTAssertNotNil(splitter.fingerprint(for: "S1#2"))
    }

    func testABriefOddStretchIsNotANewPerson() {
        var splitter = VoiceSplitter()
        splitter.add([say(jordan, 0, 3), say(jordan, 3, 6), say(jordan, 6, 9)])
        splitter.add([say(aj, 10, 12), say(jordan, 12, 15)])
        XCTAssertEqual(Set(ids(splitter)), ["S1"])
    }

    func testShortStretchesFollowWhoeverWasTalking() {
        var splitter = VoiceSplitter()
        splitter.add([say(jordan, 0, 3), say(jordan, 3, 6), say(jordan, 6, 9)])
        splitter.add([say(aj, 10, 13), say(aj, 13, 16), say(jordan, 16, 16.5)])
        XCTAssertEqual(ids(splitter).last, "S1#2")
        splitter.add([VoiceSegment(speakerID: "S1", start: 17, end: 19)])   // no fingerprint
        XCTAssertEqual(ids(splitter).last, "S1#2")
    }

    func testTheEnginesOwnNewVoicesAreLeftAlone() {
        var splitter = VoiceSplitter()
        splitter.add([say(jordan, 0, 3), say(aj, 3, 6, engine: "S2")])
        XCTAssertEqual(ids(splitter), ["S1", "S2"])
    }

    func testClickingAWrongChipSplitsOffOnlyTheirTurn() {
        var splitter = VoiceSplitter()
        splitter.add([say(jordan, 0, 3), say(jordan, 3, 6), say(jordan, 6, 9)])
        splitter.add([say(matt, 9.5, 12.5), say(matt, 12.5, 15.5)])
        XCTAssertEqual(Set(ids(splitter)), ["S1"], "Matt sounds close enough to be taken for Jordan")

        let split = splitter.splitRecent(of: "S1")
        XCTAssertEqual(split, "S1#2")
        XCTAssertEqual(ids(splitter), ["S1", "S1", "S1", "S1#2", "S1#2"], "Jordan's lines keep his name")
        // And Matt stays Matt for the rest of the call.
        splitter.add([say(jordan, 16, 19), say(matt, 19, 22)])
        XCTAssertEqual(ids(splitter).suffix(2), ["S1", "S1#2"])
        // His own fingerprint is what Warble remembers for next time.
        let print = splitter.fingerprint(for: "S1#2") ?? []
        XCTAssertLessThan(VoiceMatcher.distance(print, matt), 0.01)
    }

    func testNothingToSplitWithoutFingerprints() {
        var splitter = VoiceSplitter()
        splitter.add([VoiceSegment(speakerID: "S1", start: 0, end: 3)])
        XCTAssertNil(splitter.splitRecent(of: "S1"))
        XCTAssertNil(splitter.splitRecent(of: "nobody"))
    }
}

final class VoiceReviewTests: XCTestCase {
    private func seg(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> VoiceSegment {
        VoiceSegment(speakerID: id, start: start, end: end)
    }

    func testRecordingSeparatesPeopleTheLiveCheckLumpedTogether() {
        // Live: Jordan named first, then AJ and Matt all went under Jordan's voice.
        let live = [seg("S1", 0, 30), seg("S1", 30, 60), seg("S1", 60, 90), seg("S2", 90, 120)]
        let names = ["S1": "Jordan", "S2": "Priya"]
        // The recording, gone over in one go, finds four people.
        let review = [seg("A", 0, 30), seg("B", 30, 60), seg("C", 60, 90), seg("D", 90, 120)]
        let prints: [String: [Float]] = ["A": [1, 0, 0], "B": [0, 1, 0], "C": [0, 0, 1], "D": [1, 1, 1]]
        let result = VoiceReview.relabel(review: review, live: live, names: names, fingerprints: prints)
        XCTAssertEqual(result?.names["review-A"], "Jordan", "the stretch where he was named")
        XCTAssertEqual(result?.names["review-D"], "Priya")
        XCTAssertNil(result?.names["review-B"], "not given Jordan's name; left as a Speaker")
        XCTAssertNil(result?.names["review-C"])
        XCTAssertEqual(result?.segments.first?.speakerID, "review-A")
    }

    func testOnePersonTheRecordingSplitInTwoKeepsTheirName() {
        let live = [seg("S1", 0, 30), seg("S1", 30, 60)]
        let review = [seg("A", 0, 30), seg("A2", 30, 60)]
        let prints: [String: [Float]] = ["A": [1, 0, 0], "A2": [1, 0.2, 0]]
        let result = VoiceReview.relabel(review: review, live: live, names: ["S1": "Jordan"], fingerprints: prints)
        XCTAssertEqual(result?.names["review-A"], "Jordan")
        XCTAssertEqual(result?.names["review-A2"], "Jordan", "sounds like him, so it is him")
    }

    func testRecordingThatMergesPeopleIsIgnored() {
        let live = [seg("S1", 0, 30), seg("S2", 30, 60)]
        let names = ["S1": "Jordan", "S2": "Matt"]
        let review = [seg("A", 0, 60)]
        XCTAssertNil(VoiceReview.relabel(review: review, live: live, names: names))
    }

    func testNoNamesStillGivesTheRecordingsVoices() {
        let review = [seg("A", 0, 30), seg("B", 30, 60)]
        let result = VoiceReview.relabel(review: review, live: [seg("S1", 0, 60)], names: [:])
        XCTAssertEqual(result?.segments.count, 2)
        XCTAssertTrue(result?.names.isEmpty ?? false)
    }
}

final class NameHintTests: XCTestCase {
    func testNamesSaidAroundANewVoice() {
        XCTAssertEqual(NameHints.guess(own: ["Hi all, it's Matt from finance."], before: [], taken: []), "Matt")
        XCTAssertEqual(NameHints.guess(own: [], before: ["Thanks, Jordan. AJ, what do you think?"], taken: ["Jordan"]), "AJ")
        XCTAssertEqual(NameHints.guess(own: [], before: ["Over to you, Matt."], taken: []), "Matt")
        XCTAssertNil(NameHints.guess(own: ["Okay so I think that's right."], before: ["Thanks everyone."], taken: []))
        XCTAssertNil(NameHints.guess(own: [], before: ["Thanks, Jordan."], taken: ["Jordan"]), "already on the call")
    }
}

/// Knowing someone again on a later call (Jonny, 4 November: people he'd
/// named before were asked about again).
final class VoiceLearningTests: XCTestCase {
    func testEachCallAddsToWhatWarbleKnowsOfSomeone() {
        var matt = Voiceprint(name: "Matt", embedding: [1, 0, 0])
        matt.learn([0.8, 0.6, 0])
        XCTAssertEqual(matt.prints.count, 2, "the old recording is kept, not replaced")
        // Sounding like either call is enough.
        XCTAssertEqual(VoiceMatcher.match([1, 0.05, 0], known: [matt]), "Matt")
        XCTAssertEqual(VoiceMatcher.match([0.8, 0.62, 0], known: [matt]), "Matt")
        XCTAssertNil(VoiceMatcher.match([0, 0, 1], known: [matt]))
        for _ in 0..<20 { matt.learn([1, 0.1, 0]) }
        XCTAssertEqual(matt.prints.count, Voiceprint.maxSamples)
    }

    @MainActor
    func testAMixUpDoesNotSpoilSomeonesVoice() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceprintStore(fileURL: url)
        store.remember(name: "Jordan", embedding: [1, 0, 0])
        store.reinforce(name: "Jordan", embedding: [0, 1, 0])   // someone else entirely
        XCTAssertEqual(store.voices.first?.prints.count, 1)
        store.reinforce(name: "Jordan", embedding: [1, 0.3, 0])
        XCTAssertEqual(store.voices.first?.prints.count, 2)
        // And it's kept for next time.
        XCTAssertEqual(VoiceprintStore(fileURL: url).voices.first?.prints.count, 2)
    }

    func testAWholeCallPrintNeedsEnoughSpeech() {
        var splitter = VoiceSplitter()
        splitter.add([VoiceSegment(speakerID: "S1", start: 0, end: 6, embedding: [1, 0, 0])])
        XCTAssertNil(splitter.callPrint(for: "S1"))
        splitter.add([VoiceSegment(speakerID: "S1", start: 6, end: 12, embedding: [1, 0.1, 0]),
                      VoiceSegment(speakerID: "S1", start: 12, end: 18, embedding: [1, 0, 0.1])])
        XCTAssertNotNil(splitter.callPrint(for: "S1"))
    }
}
