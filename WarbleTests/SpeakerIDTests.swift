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

    func testOnACallAnUnsureRejoinIsAskedAboutNotGuessed() {
        // Only one person on the call: "nearer Jordan than anyone else" means
        // nothing, and the voice engine already judged this voice not to be
        // Jordan, so it is asked about rather than shown as "Jordan?".
        let onCall = [Voiceprint(name: "Jordan", embedding: voice(2))]
        let sure = VoiceMatcher.guessInCall(voice(2, distance: 0.1), onCall: onCall, saved: [matt])
        XCTAssertEqual(sure, VoiceGuess(name: "Jordan", distance: sure?.distance ?? 0, confidence: .recognised))
        let drifted = voice(2, distance: VoiceMatcher.sameCallDistance + 0.05)
        XCTAssertNil(VoiceMatcher.guessInCall(drifted, onCall: onCall, saved: [matt]))
        XCTAssertNil(VoiceMatcher.guessInCall(voice(5), onCall: onCall, saved: [matt]))
        // Even with two people on the call to compare, an unsure rejoin is
        // asked about: measured, it was nearly always someone else.
        let two = onCall + [Voiceprint(name: "Sam", embedding: voice(4))]
        XCTAssertNil(VoiceMatcher.guessInCall(drifted, onCall: two, saved: [matt]))
        // Someone on file who isn't on the call can still be a tentative guess.
        let unsure = voice(0, distance: VoiceMatcher.maxDistance + 0.03)
        XCTAssertEqual(VoiceMatcher.guessInCall(unsure, onCall: two, saved: [matt, aj])?.confidence, .tentative)
        XCTAssertNil(VoiceMatcher.guessInCall(unsure, onCall: [Voiceprint(name: "Matt", embedding: voice(0))] + two,
                                              saved: [matt, aj]), "Matt is already on the call: not guessed again")
    }

    func testATentativeGuessNeedsSomeoneToBeNearerThan() {
        let unsure = voice(0, distance: VoiceMatcher.maxDistance + 0.03)
        XCTAssertNil(VoiceMatcher.guess(unsure, known: [matt]), "nobody else to compare with")
        XCTAssertEqual(VoiceMatcher.guess(unsure, known: [matt, aj])?.confidence, .tentative)
        XCTAssertEqual(VoiceMatcher.guess(voice(0, distance: 0.2), known: [matt])?.confidence, .recognised,
                       "a clear match is still a match")
    }

    func testPeopleOnFileAreComparedLikeForLikeWithPeopleOnTheCall() {
        // First seconds: 0.35 from Jordan (on the call), 0.42 from Matt (on file).
        // Everything said since: much nearer Matt, as longer prints sit nearer everyone.
        let jordan = Voiceprint(name: "Jordan", embedding: voice(2))
        let first = Self.unit([0.58, 0, 0.65, 0, 0, 0, 0, 0.49])
        let heard = Self.unit([0.85, 0, 0.3, 0, 0, 0, 0, 0.43])
        XCTAssertEqual(VoiceMatcher.distance(first, jordan.embedding), 0.35, accuracy: 0.02)
        XCTAssertEqual(VoiceMatcher.distance(first, matt.embedding), 0.42, accuracy: 0.02)
        XCTAssertLessThan(VoiceMatcher.distance(heard, matt.embedding), 0.2)
        XCTAssertEqual(VoiceMatcher.matchInCall(first, onCall: [jordan], saved: [matt, aj], heard: heard), "Jordan",
                       "Matt from the first seconds isn't clearly nearer than Jordan")
    }

    private static func unit(_ v: [Float]) -> [Float] { VoiceSplitter.unit(v) }

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
        XCTAssertEqual(decoded.settings["chunkSeconds"] ?? 0, LiveChunks.seconds, accuracy: 0.0001)
    }

    func testTheLogKeepsWhatWasLearnedSoItCanBeUndone() throws {
        let label = UUID()
        let log = VoiceLog(live: [], liveNames: [:], review: nil, names: [:], settings: [:], learned: ["S1": label],
                           decisions: [.init(at: 12, voice: "S2", event: "ask", name: nil, distance: 0.52, confidence: nil)])
        let decoded = try JSONDecoder().decode(VoiceLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(decoded.learned?["S1"], label)
        XCTAssertEqual(decoded.decisions?.first?.event, "ask")
        // A log from build 43's first version (no learned labels or decisions) still reads.
        let old = #"{"version":1,"settings":{},"live":[],"liveNames":{},"names":{}}"#
        XCTAssertNil(try JSONDecoder().decode(VoiceLog.self, from: Data(old.utf8)).learned)
    }
}

final class LearningPrintTests: XCTestCase {
    func testTheVoiceThatStayedOnePersonIsLearned() {
        var splitter = VoiceSplitter()
        let jordan: [Float] = [1, 0, 0]
        // Jordan on a worse line: too different for Warble to tell it's him.
        let jordanFaint: [Float] = [0.5, 0, 0.866]
        // Someone else, just close enough to that to be lumped in with him.
        let lumpedIn: [Float] = [0, 0.8, 0.6]
        // S1: Jordan all call. S2: Jordan for 9 s, then mostly the other person.
        splitter.add((0..<4).map { VoiceSegment(speakerID: "S1", start: Double($0) * 6, end: Double($0) * 6 + 6, embedding: jordan) })
        splitter.add((0..<3).map { VoiceSegment(speakerID: "S2", start: 30 + Double($0) * 3, end: 33 + Double($0) * 3,
                                                embedding: jordanFaint) })
        splitter.add((0..<20).map { VoiceSegment(speakerID: "S2", start: 40 + Double($0) * 6, end: 46 + Double($0) * 6,
                                                 embedding: lumpedIn) })
        XCTAssertEqual(Set(splitter.segments.map(\.speakerID)), ["S1", "S2"], "never split off")
        let print = splitter.callPrint(of: "jordan", names: ["S1": "Jordan", "S2": "Jordan"])
        XCTAssertLessThan(VoiceMatcher.distance(print ?? [], jordan), 0.01, "S2 said more, but drifted: S1 is learned")
        XCTAssertNil(splitter.callPrint(of: "Jordan", names: ["S2": "Jordan"]))
        XCTAssertNil(splitter.callPrint(of: "Priya", names: ["S1": "Jordan"]))
    }
}

/// What Warble learns of someone's voice after a call.
final class LearningCheckTests: XCTestCase {
    private func at(_ angle: Float) -> [Float] { [cos(angle), sin(angle), 0] }

    @MainActor
    func testAVoiceLumpedIntoSomeoneElseIsNotLearnedAsThem() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceprintStore(fileURL: url)
        let matt: [Float] = [1, 0, 0]
        let aj = at(1.2)                      // about 0.64 from Matt
        store.remember(name: "Matt", embedding: matt)
        store.remember(name: "AJ", embedding: aj)
        // AJ's voice, lumped in with Matt's: 0.48 from Matt, 0.15 from AJ.
        let lumped = at(1.2 - acos(0.85))
        XCTAssertEqual(VoiceMatcher.distance(lumped, aj), 0.15, accuracy: 0.01)
        XCTAssertLessThan(VoiceMatcher.distance(lumped, matt), VoiceMatcher.learnDistance)
        XCTAssertNil(store.reinforce(name: "Matt", embedding: lumped, confidence: .confirmed), "it sounds like AJ")
        XCTAssertEqual(store.voices.first { $0.name == "Matt" }?.prints.count, 1)
        XCTAssertNotNil(store.reinforce(name: "Matt", embedding: at(0.2), confidence: .confirmed))
    }

    func testNamesWarbleGaveItselfMustPassTheStrictTest() {
        let matt = Voiceprint(name: "Matt", embedding: [1, 0, 0])
        let aj = Voiceprint(name: "AJ", embedding: [0, 1, 0])
        // Leaning away from both of them, towards nobody on file.
        let near: [Float] = [0.8, 0, 0.6], loose: [Float] = [0.52, 0, 0.854]
        XCTAssertTrue(VoiceMatcher.shouldLearn(near, as: "matt", known: [matt, aj], confidence: .recognised))
        XCTAssertFalse(VoiceMatcher.shouldLearn(loose, as: "Matt", known: [matt, aj], confidence: .recognised))
        XCTAssertTrue(VoiceMatcher.shouldLearn(loose, as: "Matt", known: [matt, aj], confidence: .confirmed),
                      "you named him: a looser fit is fine")
        XCTAssertFalse(VoiceMatcher.shouldLearn(near, as: "Matt", known: [matt, aj], confidence: .tentative))
        XCTAssertFalse(VoiceMatcher.shouldLearn(near, as: "Priya", known: [matt, aj], confidence: .confirmed))
    }

    func testLabelsStayWithTheirRecordingsWhenTheOldestAreDropped() {
        var a = Voiceprint(name: "A", embedding: [1, 0, 0])
        var labels: [UUID?] = []
        for i in 0..<Voiceprint.maxSamples { labels.append(a.learn([1, Float(i + 1) * 0.01, 0])) }
        XCTAssertEqual(a.prints.count, Voiceprint.maxSamples, "the very first recording has been dropped")
        var b = Voiceprint(name: "B", embedding: [0, 1, 0])
        let bLabel = b.learn([0, 1, 0.1])
        a.absorb(b)
        XCTAssertEqual(a.prints.count, Voiceprint.maxSamples)
        XCTAssertEqual(a.sampleIDs?.count, a.prints.count)
        XCTAssertTrue(a.has(bLabel!))
        XCTAssertFalse(a.has(labels[0]!), "dropped with its recording")
        // Each remaining label still takes out its own recording.
        let before = a.prints
        let target = labels[5]!
        let position = a.sampleIDs!.firstIndex(of: target)!
        XCTAssertTrue(a.unlearn(target))
        var expected = before
        expected.remove(at: position)
        XCTAssertEqual(a.prints, expected)
    }
}

/// When to ask "Who's this?".
final class AskWaitTests: XCTestCase {
    func testWaitsForTheNextCheckOnlyWhenTheVoiceSoundsLikeSomeone() {
        let like = [(name: "Matt", distance: Float(0.55))]
        let rechecks: [TimeInterval] = [8, 12, 20, 30, 45, 60, 90]
        XCTAssertTrue(VoiceMatcher.shouldWaitBeforeAsking(candidates: like, talk: 5, lastChecked: 5, rechecks: rechecks))
        XCTAssertTrue(VoiceMatcher.shouldWaitBeforeAsking(candidates: like, talk: 13, lastChecked: 12, rechecks: rechecks))
        XCTAssertFalse(VoiceMatcher.shouldWaitBeforeAsking(candidates: like, talk: 21, lastChecked: 20, rechecks: rechecks),
                       "waited long enough")
        XCTAssertFalse(VoiceMatcher.shouldWaitBeforeAsking(candidates: [], talk: 5, lastChecked: 5, rechecks: rechecks),
                       "sounds like nobody: ask now")
        XCTAssertFalse(VoiceMatcher.shouldWaitBeforeAsking(candidates: like, talk: 5, lastChecked: 5, rechecks: []))
        XCTAssertTrue(VoiceMatcher.shouldWaitBeforeAsking(candidates: like, talk: 6, lastChecked: nil, rechecks: rechecks))
        XCTAssertTrue(VoiceMatcher.shouldWaitBeforeAsking(candidates: like, talk: 25, lastChecked: 20, rechecks: [30], atMost: 30))
    }
}

/// Audio plumbing for the voice check.
final class ChunkAndGapTests: XCTestCase {
    func testOnlyWholeChunksGoDuringTheCall() {
        let chunk = 160_000
        XCTAssertEqual(LiveChunks.samplesToSend(pending: 159_999, chunk: chunk, wholeChunksOnly: true), 0)
        XCTAssertEqual(LiveChunks.samplesToSend(pending: 160_000, chunk: chunk, wholeChunksOnly: true), 160_000)
        XCTAssertEqual(LiveChunks.samplesToSend(pending: 330_000, chunk: chunk, wholeChunksOnly: true), 320_000)
        XCTAssertEqual(LiveChunks.samplesToSend(pending: 330_000, chunk: chunk, wholeChunksOnly: false), 330_000, "end of call")
        XCTAssertEqual(LiveChunks.samplesToSend(pending: 0, chunk: chunk, wholeChunksOnly: false), 0)
    }

    func testTheLastBitOfACallIsRepeatedNotPaddedWithSilence() {
        let chunk = 10
        let (out, real) = LiveChunks.endOfCall(Array(1...23).map(Float.init), chunk: chunk, minimumTail: 2)
        XCTAssertEqual(real, 23)
        XCTAssertEqual(out.count, 30)
        XCTAssertEqual(Array(out.prefix(20)), Array(1...20).map(Float.init), "whole chunks untouched")
        XCTAssertEqual(Array(out.suffix(10)), [21, 22, 23, 21, 22, 23, 21, 22, 23, 21], "no silence")
        let short = LiveChunks.endOfCall(Array(1...21).map(Float.init), chunk: chunk, minimumTail: 2)
        XCTAssertEqual(short.real, 20, "a scrap too short to judge is left out")
        XCTAssertEqual(short.audio.count, 20)
        XCTAssertEqual(LiveChunks.endOfCall(Array(1...20).map(Float.init), chunk: chunk, minimumTail: 2).audio.count, 20)
        XCTAssertEqual(LiveChunks.endOfCall([], chunk: chunk, minimumTail: 2).real, 0)
        XCTAssertEqual(LiveChunks.endOfCall([1, 2, 3], chunk: chunk, minimumTail: 2).audio, [1, 2, 3, 1, 2, 3, 1, 2, 3, 1])
    }

    func testVoicesAfterAGapAreMovedOnByItsLength() {
        var gaps: [EngineClock.Gap] = []
        gaps = EngineClock.adding(3, at: 20, to: gaps)
        gaps = EngineClock.adding(1, at: 20, to: gaps)     // the same gap, in two pieces
        gaps = EngineClock.adding(5, at: 50, to: gaps)
        gaps = EngineClock.adding(0, at: 60, to: gaps)     // nothing
        XCTAssertEqual(gaps, [.init(at: 20, extra: 4), .init(at: 50, extra: 5)])
        XCTAssertEqual(EngineClock.callTime(10, gaps: gaps), 10, "before any gap")
        XCTAssertEqual(EngineClock.callTime(20, gaps: gaps), 24, "starting right after the gap")
        XCTAssertEqual(EngineClock.callTime(20, gaps: gaps, isEnd: true), 20, "ending right where it began")
        XCTAssertEqual(EngineClock.callTime(30, gaps: gaps), 34)
        XCTAssertEqual(EngineClock.callTime(55, gaps: gaps), 64)
        XCTAssertEqual(EngineClock.callTime(5, gaps: []), 5)
    }

    func testSpeechAcrossAGapIsCutInTwo() {
        let gaps = [EngineClock.Gap(at: 20, extra: 4), EngineClock.Gap(at: 50, extra: 5)]
        func flat(_ p: [(start: TimeInterval, end: TimeInterval)]) -> [TimeInterval] { p.flatMap { [$0.start, $0.end] } }
        XCTAssertEqual(flat(EngineClock.pieces(start: 15, end: 25, gaps: gaps)), [15, 20, 24, 29],
                       "one person talking across the gap: two pieces, not one covering the silence")
        XCTAssertEqual(flat(EngineClock.pieces(start: 15, end: 55, gaps: gaps)), [15, 20, 24, 54, 59, 64])
        XCTAssertEqual(flat(EngineClock.pieces(start: 20, end: 30, gaps: gaps)), [24, 34], "starting at the gap")
        XCTAssertEqual(flat(EngineClock.pieces(start: 10, end: 20, gaps: gaps)), [10, 20], "ending at the gap")
        XCTAssertEqual(flat(EngineClock.pieces(start: 1, end: 5, gaps: [])), [1, 5])
        XCTAssertTrue(EngineClock.pieces(start: 5, end: 5, gaps: gaps).isEmpty)
        let talk = EngineClock.pieces(start: 15, end: 25, gaps: gaps).reduce(0) { $0 + $1.end - $1.start }
        XCTAssertEqual(talk, 10, accuracy: 1e-9, "the gap doesn't count as talk")
    }

    func testSilenceGoesInOneSecondPiecesAndLongGapsAreCapped() {
        XCTAssertEqual(AudioGap.pieces(120_000, sampleRate: 48_000), [48_000, 48_000, 24_000])
        XCTAssertEqual(AudioGap.pieces(48_000, sampleRate: 48_000), [48_000])
        XCTAssertEqual(AudioGap.pieces(0, sampleRate: 48_000), [])
        XCTAssertEqual(AudioGap.pieces(5, sampleRate: 48_000).reduce(0, +), 5)
        let long = AudioGap.silentFrames(previousEnd: 10, start: 310, sampleRate: 48_000)
        XCTAssertEqual(long, Int(AudioGap.mostFilled * 48_000), "five minutes quiet: at most a minute filled")
    }
}
