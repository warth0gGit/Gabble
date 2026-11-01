import XCTest
@testable import Warble

final class PhraseSplitterTests: XCTestCase {
    private func t(_ text: String, _ start: Double, _ end: Double) -> TimedToken {
        TimedToken(text: text, start: start, end: end)
    }

    func testJoinsWordPiecesIntoText() {
        let tokens = [t(" Hel", 0, 0.2), t("lo", 0.2, 0.4), t(" there", 0.45, 0.8)]
        let phrases = PhraseSplitter.phrases(from: tokens)
        XCTAssertEqual(phrases.count, 1)
        XCTAssertEqual(phrases[0].text, "Hello there")
        XCTAssertEqual(phrases[0].start, 0)
        XCTAssertEqual(phrases[0].end, 0.8)
        XCTAssertEqual(phrases[0].tokens, 0..<3)
    }

    func testSplitsAtLongPause() {
        let tokens = [t(" Morning", 0, 0.5), t(" all", 0.5, 0.8), t(" Shall", 2.0, 2.3), t(" we", 2.3, 2.5)]
        let phrases = PhraseSplitter.phrases(from: tokens)
        XCTAssertEqual(phrases.map(\.text), ["Morning all", "Shall we"])
        XCTAssertEqual(phrases[1].start, 2.0)
        XCTAssertEqual(phrases[1].tokens, 2..<4)
    }

    func testNeverSplitsInsideAWord() {
        let tokens = [t(" Warb", 0, 0.3), t("le", 1.5, 1.7)]
        XCTAssertEqual(PhraseSplitter.phrases(from: tokens).map(\.text), ["Warble"])
    }

    func testSplitsAtSentenceEndAfterAFewSeconds() {
        var tokens: [TimedToken] = []
        for i in 0..<10 { tokens.append(t(" word", Double(i) * 0.5, Double(i) * 0.5 + 0.4)) }
        tokens.append(t(".", 4.9, 4.9))
        tokens.append(t(" Next", 5.3, 5.6))
        let phrases = PhraseSplitter.phrases(from: tokens)
        XCTAssertEqual(phrases.count, 2)
        XCTAssertEqual(phrases[1].text, "Next")
    }

    func testSentencePieceMarkers() {
        let tokens = [t("▁Good", 0, 0.3), t("▁news", 0.3, 0.6)]
        XCTAssertEqual(PhraseSplitter.phrases(from: tokens).first?.text, "Good news")
    }

    func testEmptyInput() {
        XCTAssertTrue(PhraseSplitter.phrases(from: []).isEmpty)
    }
}

final class SpokenRangeTests: XCTestCase {
    func testUsesExactTimingWhenKnown() {
        let segment = CallTranscript.Segment(offset: 10, speaker: "Others", text: "Hello there", spoken: 10...11.5)
        XCTAssertEqual(CallTranscript.spokenRange(of: segment), 10...11.5)
    }

    func testEstimatesTimingOtherwise() {
        let segment = CallTranscript.Segment(offset: 10, speaker: "Others", text: "Hello there")
        let range = CallTranscript.spokenRange(of: segment)
        XCTAssertLessThan(range.upperBound, 10)
    }
}

final class PhraseAudioTests: XCTestCase {
    func testTracksSpeechAndPause() {
        let audio = PhraseAudio(sampleRate: 16_000)
        audio.append([Float](repeating: 0.2, count: 8_000))   // half a second of talking
        audio.append([Float](repeating: 0, count: 16_000))    // then a second of quiet
        let snap = audio.snapshot()
        XCTAssertTrue(snap.hasSpeech)
        XCTAssertEqual(snap.trailingSilence, 1, accuracy: 0.01)
        audio.consume(snap.samples.count)
        XCTAssertFalse(audio.snapshot().hasSpeech)
    }

    func testDropsLongSilenceBeforeSpeech() {
        let audio = PhraseAudio(sampleRate: 16_000)
        for _ in 0..<10 { audio.append([Float](repeating: 0, count: 16_000)) }
        let snap = audio.snapshot()
        XCTAssertFalse(snap.hasSpeech)
        XCTAssertLessThan(snap.duration, 2)
    }
}

final class RecognitionModelTests: XCTestCase {
    @MainActor
    func testOldWhisperChoiceFallsBackToApple() {
        let defaults = UserDefaults(suiteName: "warble-tests-\(UUID().uuidString)")!
        defaults.set("whisperLargeV3Turbo", forKey: "recognitionModel")
        XCTAssertEqual(AppState(defaults: defaults).recognitionModel, .appleOnDevice)
    }
}
