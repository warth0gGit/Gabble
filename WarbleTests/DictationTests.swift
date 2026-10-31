import XCTest
@testable import Warble

final class TextCleanerTests: XCTestCase {
    func testRemovesFillersAndCapitalises() {
        XCTAssertEqual(TextCleaner.clean("um so we should, uh, ship it"), "So we should, ship it")
    }

    func testRemovesStutters() {
        XCTAssertEqual(TextCleaner.clean("the the plan is ready"), "The plan is ready")
    }

    func testAppliesWordListReplacements() {
        let replacements = [TextCleaner.Replacement(heard: "sass", written: "SaaS"),
                            TextCleaner.Replacement(heard: "what's an x", written: "watsonx")]
        XCTAssertEqual(TextCleaner.clean("our sass revenue on what's an x grew", replacements: replacements),
                       "Our SaaS revenue on watsonx grew")
    }

    func testReplacementsRespectWordBoundaries() {
        let replacements = [TextCleaner.Replacement(heard: "kpi", written: "KPI")]
        XCTAssertEqual(TextCleaner.applyReplacements("kpis and kpi", replacements), "kpis and KPI")
    }

    func testScratchThatDropsPreviousClause() {
        XCTAssertEqual(TextCleaner.clean("Send it Monday. Scratch that. Send it Tuesday."), "Send it Tuesday.")
    }

    func testSpokenNewLine() {
        XCTAssertEqual(TextCleaner.clean("first point new line second point"), "First point\nSecond point")
    }

    func testTidiesPunctuationSpacing() {
        XCTAssertEqual(TextCleaner.tidySpacing("hello ,  world ."), "hello, world.")
    }
}

final class CorrectionDiffTests: XCTestCase {
    func testFindsEditInsideInsertedText() {
        let edited = CorrectionDiff.editedVersion(
            of: "grow our sass revenue",
            before: "Note: grow our sass revenue",
            after: "Note: grow our SaaS revenue")
        XCTAssertEqual(edited, "grow our SaaS revenue")
    }

    func testIgnoresTypingAfterInsertedText() {
        XCTAssertNil(CorrectionDiff.editedVersion(
            of: "hello there", before: "hello there", after: "hello there, how are you"))
    }

    func testIgnoresUnchangedField() {
        XCTAssertNil(CorrectionDiff.editedVersion(of: "hi", before: "hi", after: "hi"))
    }
}

final class SmartCleanupTests: XCTestCase {
    func testRejectsAnswersInsteadOfCleanups() {
        let question = "can you tell me what the capital of France is and why it matters"
        let answer = String(repeating: "The capital of France is Paris, which matters because... ", count: 4)
        XCTAssertNil(SmartCleanup.validated(answer, original: question))
    }

    func testStripsPreambleAndQuotes() {
        XCTAssertEqual(SmartCleanup.validated("Cleaned text: \"Let's meet Wednesday.\"",
                                              original: "um let's meet tuesday no wednesday"),
                       "Let's meet Wednesday.")
    }

    func testWritingStyleForApps() {
        XCTAssertEqual(WritingStyle.forApp(bundleID: "com.microsoft.Word"), .formal)
        XCTAssertEqual(WritingStyle.forApp(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(WritingStyle.forApp(bundleID: "com.anthropic.claudefordesktop"), .prompt)
        XCTAssertEqual(WritingStyle.forApp(bundleID: nil), .neutral)
    }
}

final class JargonTests: XCTestCase {
    func testJargonDetection() {
        let known: (String) -> Bool = { ["went", "shop"].contains($0) }
        XCTAssertTrue(LexiconLearner.looksLikeJargon("SaaS", isKnownWord: known))
        XCTAssertTrue(LexiconLearner.looksLikeJargon("KPI", isKnownWord: known))
        XCTAssertTrue(LexiconLearner.looksLikeJargon("watsonx", isKnownWord: known))
        XCTAssertFalse(LexiconLearner.looksLikeJargon("went", isKnownWord: known))
    }
}

final class LiveJoinerTests: XCTestCase {
    func testFirstPhraseIsCapitalisedWithNoLeadingSpace() {
        XCTAssertEqual(LiveJoiner.piece(for: "um hello there", after: ""), "Hello there")
    }

    func testContinuingPhraseGetsSpaceAndLowerCase() {
        XCTAssertEqual(LiveJoiner.piece(for: "and then we left", after: "We arrived"), " and then we left")
    }

    func testNewSentenceKeepsCapital() {
        XCTAssertEqual(LiveJoiner.piece(for: "next point", after: "That's done."), " Next point")
    }

    func testKeepsAcronymsAndI() {
        XCTAssertEqual(LiveJoiner.piece(for: "KPI review", after: "We need the"), " KPI review")
        XCTAssertEqual(LiveJoiner.piece(for: "I think so", after: "Well"), " I think so")
    }
}

final class TextInserterTests: XCTestCase {
    @MainActor
    func testNormalisesQuotesAndLineEndings() {
        XCTAssertEqual(TextInserter.normalised("It\u{2019}s\r\nfine"), "It's\nfine")
    }
}

final class LivePhraseTyperTests: XCTestCase {
    func testTypesStableWordsBeforePhraseEnds() {
        var t = LivePhraseTyper()
        XCTAssertEqual(t.volatile("hello"), "")
        XCTAssertEqual(t.volatile("hello there"), "Hello")
        XCTAssertEqual(t.volatile("hello there how"), " there")
        XCTAssertEqual(t.final("hello there how are you"), .type(" how are you"))
        XCTAssertEqual(t.typedSoFar, "Hello there how are you")
    }

    func testCorrectsWhenEngineChangesItsMind() {
        var t = LivePhraseTyper()
        _ = t.volatile("their going")
        XCTAssertEqual(t.volatile("their going home"), "Their going")
        XCTAssertEqual(t.final("they're going home"), .replace(old: "Their going", new: "They're going home"))
    }

    func testCarriesWordsIntoNextPhrase() {
        var t = LivePhraseTyper()
        _ = t.volatile("hello there how")
        _ = t.volatile("hello there how are")
        XCTAssertEqual(t.typedSoFar, "Hello there how")
        XCTAssertNil(t.final("hello there"))
        XCTAssertEqual(t.volatile("how are you"), "")
        XCTAssertEqual(t.final("how are you"), .type(" are you"))
        XCTAssertEqual(t.typedSoFar, "Hello there how are you")
    }

    func testFinalWithNothingTypedYet() {
        var t = LivePhraseTyper()
        XCTAssertEqual(t.final("hi"), .type("Hi"))
        XCTAssertEqual(t.final("and bye"), .type(" and bye"))
    }
}
