import XCTest
@testable import Warble

/// Taking back a name given by mistake, renaming and joining people Warble
/// knows by voice, without spoiling what it has learned of anyone else.
final class VoiceUndoTests: XCTestCase {
    @MainActor
    private func store() -> (VoiceprintStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        return (VoiceprintStore(fileURL: url), url)
    }

    @MainActor
    func testUndoingANameTakesBackOnlyThatRecording() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        store.remember(name: "Matt", embedding: [1, 0, 0])
        let mistake = store.remember(name: "Matt", embedding: [0, 1, 0])
        XCTAssertEqual(store.voices.first?.prints.count, 2)
        store.unlearn(mistake!)
        XCTAssertEqual(store.voices.first?.prints, [[1, 0, 0]])
        XCTAssertEqual(store.voices.first?.embedding ?? [], [1, 0, 0])
        // Kept for next time.
        XCTAssertEqual(VoiceprintStore(fileURL: url).voices.first?.prints, [[1, 0, 0]])
    }

    @MainActor
    func testUndoingTheFirstNameForgetsThePerson() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        store.remember(name: "Jordan", embedding: [1, 0, 0])
        let first = store.remember(name: "AJ", embedding: [0, 1, 0])
        store.unlearn(first!)
        XCTAssertEqual(store.voices.map(\.name), ["Jordan"])
        store.unlearn(UUID())   // unknown label: nothing happens
        XCTAssertEqual(store.voices.count, 1)
    }

    @MainActor
    func testUndoingAWholeCallRecording() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        store.remember(name: "Jordan", embedding: [1, 0, 0])
        let learned = store.reinforce(name: "Jordan", embedding: [1, 0.2, 0])
        XCTAssertNotNil(learned)
        XCTAssertNil(store.reinforce(name: "Jordan", embedding: [0, 0, 1]), "doesn't sound like him: not learned")
        store.unlearn(learned!)
        XCTAssertEqual(store.voices.first?.prints.count, 1)
    }

    @MainActor
    func testRenameAndJoin() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        store.remember(name: "Mat", embedding: [1, 0, 0])
        store.remember(name: "Matt Jones", embedding: [0.9, 0.1, 0])
        store.remember(name: "Priya", embedding: [0, 0, 1])
        store.rename(from: "priya", to: "Priya Shah")
        XCTAssertEqual(Set(store.voices.map(\.name)), ["Mat", "Matt Jones", "Priya Shah"])
        // Renaming to a name already on file joins the two.
        store.rename(from: "Mat", to: "matt jones")
        XCTAssertEqual(Set(store.voices.map(\.name)), ["Matt Jones", "Priya Shah"])
        XCTAssertEqual(store.voices.first { $0.name == "Matt Jones" }?.prints.count, 2)
        store.merge("Priya Shah", into: "Nobody")   // no such person: nothing happens
        XCTAssertEqual(store.voices.count, 2)
    }

    @MainActor
    func testRecordingsFromBeforeLabelsCanStillBeUndone() throws {
        // A voiceprints.json written by build 40 (no labels) or older (no samples).
        let json = #"[{"id":"7C6B2E4A-1B1C-4F57-9C5E-2D7E2B9C0A11","name":"Shadee","embedding":[1,0,0],"updated":0},"#
            + #"{"id":"8C6B2E4A-1B1C-4F57-9C5E-2D7E2B9C0A11","name":"Jala","embedding":[0,1,0],"updated":0,"samples":[[0,1,0]]}]"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let store = VoiceprintStore(fileURL: url)
        XCTAssertEqual(store.voices.count, 2)
        let added = store.remember(name: "Shadee", embedding: [1, 0.1, 0])
        XCTAssertEqual(store.voices.first?.prints.count, 2, "the old recording is kept")
        store.unlearn(added!)
        XCTAssertEqual(store.voices.first?.prints, [[1, 0, 0]])
        let jala = store.remember(name: "Jala", embedding: [0.1, 1, 0])
        store.unlearn(jala!)
        XCTAssertEqual(store.voices.last?.prints, [[0, 1, 0]])
    }
}

final class AudioGapTests: XCTestCase {
    func testSilenceFillsWhereTheCallAudioSkippedAhead() {
        XCTAssertEqual(AudioGap.silentFrames(previousEnd: nil, start: 5, sampleRate: 48_000), 0, "first buffer")
        XCTAssertEqual(AudioGap.silentFrames(previousEnd: 10, start: 10.01, sampleRate: 48_000), 0, "ordinary unevenness")
        XCTAssertEqual(AudioGap.silentFrames(previousEnd: 10, start: 9.99, sampleRate: 48_000), 0, "overlap")
        XCTAssertEqual(AudioGap.silentFrames(previousEnd: 10, start: 12.5, sampleRate: 48_000), 120_000)
        XCTAssertEqual(AudioGap.silentFrames(previousEnd: 10, start: 5000, sampleRate: 48_000), 0, "clock reset, not silence")
    }
}

final class ReviewPrintTests: XCTestCase {
    func testEachRecordingVoiceGetsThePrintsOfTheLiveStretchesInsideIt() {
        let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0]
        // Live: one voice that was really two people.
        let live = [
            VoiceSegment(speakerID: "S1", start: 0, end: 6, embedding: a),
            VoiceSegment(speakerID: "S1", start: 6, end: 12, embedding: a),
            VoiceSegment(speakerID: "S1", start: 12, end: 18, embedding: a),
            VoiceSegment(speakerID: "S1", start: 20, end: 26, embedding: b),
            VoiceSegment(speakerID: "S1", start: 26, end: 32, embedding: b),
            VoiceSegment(speakerID: "S1", start: 32, end: 38, embedding: b),
            VoiceSegment(speakerID: "S1", start: 17, end: 21, embedding: [0, 0, 1]),   // straddles both
        ]
        let review = [VoiceSegment(speakerID: "A", start: 0, end: 19), VoiceSegment(speakerID: "B", start: 19, end: 40)]
        let prints = VoiceReview.prints(review: review, live: live)
        XCTAssertLessThan(VoiceMatcher.distance(prints["A"] ?? [], a), 0.001)
        XCTAssertLessThan(VoiceMatcher.distance(prints["B"] ?? [], b), 0.001)
        XCTAssertTrue(VoiceReview.prints(review: review, live: live, atLeast: 30).isEmpty, "too little speech")
    }
}

/// "Who's this?" suggestions and how sure Warble is of a name.
final class VoiceGuessTests: XCTestCase {
    /// A unit-length fingerprint at a chosen cosine distance from axis 0,
    /// leaning towards `towards`.
    private func voice(_ axis: Int, distance: Float = 0, towards other: Int = 7) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        let cos = 1 - distance
        v[axis] = cos
        v[other] = (1 - cos * cos).squareRoot()
        return v
    }

    private let matt = Voiceprint(name: "Matt", embedding: [1, 0, 0, 0, 0, 0, 0, 0])
    private let aj = Voiceprint(name: "AJ", embedding: [0, 1, 0, 0, 0, 0, 0, 0])

    func testCandidatesAreTheNearestPeopleWithinReach() {
        let near = voice(0, distance: 0.5)   // sounds a bit like Matt, nothing like AJ
        let found = VoiceMatcher.candidates(near, known: [aj, matt])
        XCTAssertEqual(found.map(\.name), ["Matt"], "AJ is too far to be worth offering")
        XCTAssertEqual(found.first?.distance ?? 0, 0.5, accuracy: 0.001)
        XCTAssertTrue(VoiceMatcher.candidates(voice(5), known: [aj, matt]).isEmpty, "nobody like them on file")
        XCTAssertTrue(VoiceMatcher.candidates(near, known: [aj, matt], limit: 0).isEmpty)
        // Each person once, however many recordings they have.
        var twice = matt
        twice.learn(voice(0, distance: 0.1))
        XCTAssertEqual(VoiceMatcher.candidates(voice(0, distance: 0.05), known: [twice]).count, 1)
    }

    func testSureUnsureAndUnknown() {
        XCTAssertEqual(VoiceMatcher.guess(voice(0, distance: 0.2), known: [matt, aj])?.confidence, .recognised)
        let unsure = VoiceMatcher.guess(voice(0, distance: VoiceMatcher.maxDistance + 0.03), known: [matt, aj])
        XCTAssertEqual(unsure?.name, "Matt")
        XCTAssertEqual(unsure?.confidence, .tentative)
        XCTAssertNil(VoiceMatcher.guess(voice(0, distance: VoiceMatcher.tentativeDistance + 0.05), known: [matt, aj]))
        XCTAssertNil(VoiceMatcher.guess(voice(4), known: [matt, aj]))
        XCTAssertNil(VoiceMatcher.guess(voice(0), known: []))
        // A strict match is always at least a tentative one.
        XCTAssertLessThan(VoiceMatcher.maxDistance, VoiceMatcher.tentativeDistance)
        XCTAssertLessThan(VoiceMatcher.tentativeDistance, VoiceMatcher.candidateDistance)
    }

    func testOnACallAnUnsureRejoinIsTentative() {
        let onCall = [Voiceprint(name: "Jordan", embedding: voice(2))]
        let sure = VoiceMatcher.guessInCall(voice(2, distance: 0.1), onCall: onCall, saved: [matt])
        XCTAssertEqual(sure, VoiceGuess(name: "Jordan", distance: sure?.distance ?? 0, confidence: .recognised))
        let drifted = VoiceMatcher.guessInCall(voice(2, distance: VoiceMatcher.sameCallDistance + 0.05),
                                               onCall: onCall, saved: [matt])
        XCTAssertEqual(drifted?.name, "Jordan")
        XCTAssertEqual(drifted?.confidence, .tentative, "close-ish to Jordan: shown as Jordan?, not named outright")
        XCTAssertNil(VoiceMatcher.guessInCall(voice(5), onCall: onCall, saved: [matt]))
    }

    func testOneOddRecordingDoesNotMakeAStrangerSoundLikeThem() {
        // Three calls of Matt, and one recording that was really someone else.
        var mixedUp = matt
        mixedUp.learn(voice(0, distance: 0.05))
        mixedUp.learn(voice(0, distance: 0.05, towards: 6))
        mixedUp.learn(voice(5))
        XCTAssertEqual(mixedUp.prints.count, 4)
        XCTAssertNil(VoiceMatcher.match(voice(5), known: [mixedUp, aj]), "the stranger matches one recording, not Matt")
        XCTAssertNil(VoiceMatcher.guess(voice(5), known: [mixedUp, aj]))
        XCTAssertEqual(VoiceMatcher.match(voice(0), known: [mixedUp, aj]), "Matt")
    }

    func testMoreSpeechDecidesWhoSomeoneFromAnEarlierCallIs() {
        let first = voice(0, distance: VoiceMatcher.maxDistance + 0.1)   // their first few seconds: unsure
        let heard = voice(0, distance: 0.1)                               // everything they've said since
        XCTAssertNil(VoiceMatcher.matchInCall(first, onCall: [], saved: [matt, aj]))
        XCTAssertEqual(VoiceMatcher.matchInCall(first, onCall: [], saved: [matt, aj], heard: heard), "Matt")
        XCTAssertEqual(VoiceMatcher.guessInCall(first, onCall: [], saved: [matt, aj], heard: heard)?.confidence, .recognised)
        // People already on this call are still compared by the first seconds.
        let jordan = Voiceprint(name: "Jordan", embedding: voice(2))
        XCTAssertEqual(VoiceMatcher.matchInCall(voice(2, distance: 0.1), onCall: [jordan], saved: [matt],
                                                heard: voice(2, distance: 0.1)), "Jordan")
    }
}

final class VoiceLogTests: XCTestCase {
    func testTheVoiceLogReadsBackAsWritten() throws {
        let live = [VoiceSegment(speakerID: "S1", start: 0, end: 6, embedding: [1, 0]),
                    VoiceSegment(speakerID: "S2", start: 6, end: 9, embedding: [0, 1])]
        let log = VoiceLog(live: live, liveNames: ["S1": "Jordan"], review: nil, names: ["S1": "Jordan"],
                           settings: VoiceLog.currentSettings)
        let decoded = try JSONDecoder().decode(VoiceLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(decoded, log)
        XCTAssertEqual(decoded.live.map(\.voice), ["S1", "S2"])
        XCTAssertEqual(decoded.settings["maxDistance"] ?? 0, Double(VoiceMatcher.maxDistance), accuracy: 0.0001)
    }
}

final class LearningPrintTests: XCTestCase {
    func testTheVoiceThatStayedOnePersonIsLearned() {
        var splitter = VoiceSplitter()
        let jordan: [Float] = [1, 0, 0]
        // Someone else, just close enough to Jordan's first seconds to be lumped in with him.
        let lumpedIn: [Float] = [0.505, 0.863, 0]
        // S1: Jordan all call. S2: Jordan for 9 s, then mostly the other person.
        splitter.add((0..<4).map { VoiceSegment(speakerID: "S1", start: Double($0) * 6, end: Double($0) * 6 + 6, embedding: jordan) })
        splitter.add((0..<3).map { VoiceSegment(speakerID: "S2", start: 30 + Double($0) * 3, end: 33 + Double($0) * 3, embedding: jordan) })
        splitter.add((0..<20).map { VoiceSegment(speakerID: "S2", start: 40 + Double($0) * 6, end: 46 + Double($0) * 6,
                                                 embedding: lumpedIn) })
        XCTAssertEqual(Set(splitter.segments.map(\.speakerID)), ["S1", "S2"], "never split off")
        let print = splitter.callPrint(of: "jordan", names: ["S1": "Jordan", "S2": "Jordan"])
        XCTAssertLessThan(VoiceMatcher.distance(print ?? [], jordan), 0.01, "S2 said more, but drifted: S1 is learned")
        XCTAssertNil(splitter.callPrint(of: "Jordan", names: ["S2": "Jordan"]))
        XCTAssertNil(splitter.callPrint(of: "Priya", names: ["S1": "Jordan"]))
    }
}
