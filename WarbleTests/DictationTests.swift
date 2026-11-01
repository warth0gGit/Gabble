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

    func testScratchThatCutsBackToTheRestatedWords() {
        // Jonny's real dictation (build 16), as Parakeet heard it.
        let heard = "Also, I just need to see how well the like the like the tidy up works also I'm gonna say that "
            + "Shorty's birthday is in December. Stratch that Shorty's birthday is in November."
        XCTAssertEqual(TextCleaner.clean(heard),
                       "Also, I just need to see how well the tidy up works also I'm gonna say that "
                       + "Shorty's birthday is in November.")
    }

    func testScratchedThatAfterNoWait() {
        // Jonny's real dictation into the Claude app, 1 Nov 2026.
        XCTAssertEqual(TextCleaner.clean("Do I need to wait for eighteen or no wait, sorry scratched that do I test seventeen or should I wait for eighteen?"),
                       "Do I test seventeen or should I wait for eighteen?")
    }

    func testScratchThatWithoutRestatingDropsTheSentence() {
        XCTAssertEqual(TextCleaner.clean("Call me at six. Scratch that. Text me instead."), "Text me instead.")
    }

    func testRestartPointNeedsTheSameTwoWords() {
        XCTAssertNil(TextCleaner.restartPoint(in: "Send it to the team.", for: "the board"))
        XCTAssertNotNil(TextCleaner.restartPoint(in: "We meet on Monday.", for: "we meet on Tuesday"))
    }

    func testRemovesRepeatedPhrasesAndCutOffStarts() {
        // From Jonny's dictations into Claude, 1 Nov 2026.
        XCTAssertEqual(TextCleaner.clean("I don't know if it if it works"), "I don't know if it works")
        XCTAssertEqual(TextCleaner.clean("we're gonna t test this"), "We're gonna test this")
        XCTAssertEqual(TextCleaner.clean("a apple and I in"), "A apple and I in")
        XCTAssertEqual(TextCleaner.clean("don't take it"), "Don't take it")
    }

    func testRemovesLikeBetweenRepeatedWords() {
        XCTAssertEqual(TextCleaner.clean("the like the like the tidy up works"), "The tidy up works")
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

    func testStripsChattyOpener() {
        let spoken = "I'm gonna test this real quick to see if it works"
        XCTAssertEqual(SmartCleanup.validated("Sure, here's the edited text:\n\nI'm gonna test this real quick to see if it works.",
                                              original: spoken),
                       "I'm gonna test this real quick to see if it works.")
        XCTAssertEqual(SmartCleanup.strippingChatter("Certainly! Here is the cleaned version: Hello there.", original: "hello there"),
                       "Hello there.")
        XCTAssertEqual(SmartCleanup.strippingChatter("Edited: Hi.", original: "hi"), "Hi.")
    }

    func testKeepsColonsTheSpeakerMeant() {
        XCTAssertEqual(SmartCleanup.strippingChatter("Here's the plan: we ship on Friday.",
                                                     original: "here's the plan we ship on friday"),
                       "Here's the plan: we ship on Friday.")
        XCTAssertEqual(SmartCleanup.strippingChatter("Okay team: let's start.", original: "um okay team let's start"),
                       "Okay team: let's start.")
        XCTAssertEqual(SmartCleanup.strippingChatter("Note: the office is closed.", original: "note the office is closed"),
                       "Note: the office is closed.")
    }

    func testExamplesUseAmericanSpelling() {
        XCTAssertFalse(SmartCleanup.instructions.contains("summarise"))
        XCTAssertTrue(SmartCleanup.instructions.contains("American English spelling"))
    }

    func testShortCleanDictationsSkipTheModel() {
        XCTAssertTrue(SmartCleanup.isAlreadyTidy(raw: "sounds good see you then", basic: "Sounds good see you then"))
        XCTAssertTrue(SmartCleanup.isAlreadyTidy(raw: "um thanks Shadee", basic: "Thanks Shadee"))
        // Corrections, numbers and verbal tics still go to Apple Intelligence.
        XCTAssertFalse(SmartCleanup.isAlreadyTidy(raw: "meet tuesday no wednesday", basic: "Meet tuesday no wednesday"))
        XCTAssertFalse(SmartCleanup.isAlreadyTidy(raw: "build twenty is ready", basic: "Build twenty is ready"))
        XCTAssertFalse(SmartCleanup.isAlreadyTidy(raw: "it's like really good", basic: "It's like really good"))
        // Long dictations always do.
        let long = Array(repeating: "word", count: 11).joined(separator: " ")
        XCTAssertFalse(SmartCleanup.isAlreadyTidy(raw: long, basic: long))
    }

    func testPromptStartsWithThePrewarmedPrefix() {
        let prefix = SmartCleanup.promptPrefix(terms: ["Claude"], style: .chat)
        XCTAssertTrue(SmartCleanup.prompt(for: "hi there", terms: ["Claude"], style: .chat).hasPrefix(prefix))
        XCTAssertTrue(prefix.hasSuffix("Transcript: "))
    }

    func testTimingSummary() {
        XCTAssertEqual(DictationTiming(speech: 0.2, tidy: 1.3).summary,
                       "Text was ready 1.5 s after you stopped (speech 0.2 s, tidy-up 1.3 s).")
    }

    func testDeadlineGrowsWithLengthButIsCapped() {
        XCTAssertEqual(SmartCleanup.deadline(forWords: 0), 6)
        XCTAssertGreaterThan(SmartCleanup.deadline(forWords: 80), 6 + 5)
        XCTAssertEqual(SmartCleanup.deadline(forWords: 5_000), 20)
    }

    func testPromptCarriesWordListAndTranscript() {
        let prompt = SmartCleanup.prompt(for: "ask clawed", terms: ["Claude", "SaaS"], style: .prompt)
        XCTAssertTrue(prompt.contains("Word list: Claude, SaaS"))
        XCTAssertTrue(prompt.hasSuffix("Transcript: ask clawed\nEdited:"))
        XCTAssertFalse(SmartCleanup.prompt(for: "hi", terms: [], style: .chat).contains("Word list"))
    }

    func testInstructionsCoverSoundAlikeTerms() {
        XCTAssertTrue(SmartCleanup.instructions.contains("\"clawed\""))
    }

    func testCleanupOutcomeSummaries() {
        XCTAssertEqual(CleanupOutcome.smart(seconds: 1.24).summary,
                       "Last dictation was tidied by Apple Intelligence in 1.2 s.")
        XCTAssertTrue(CleanupOutcome.skipped(reason: "it was slow.").summary.hasSuffix("it was slow."))
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

final class WordErrorRateTests: XCTestCase {
    func testPerfectMatchIgnoresCaseAndPunctuation() {
        let w = WordErrorRate.compute(reference: "Send the Q3 deck, please.", hypothesis: "send the q3 deck please")
        XCTAssertEqual(w.errors, 0)
        XCTAssertEqual(w.accuracy, 1)
    }

    func testCountsEachKindOfError() {
        let w = WordErrorRate.compute(reference: "the quick brown fox jumps", hypothesis: "the quick red fox jumps high")
        XCTAssertEqual(w.substitutions, 1)
        XCTAssertEqual(w.insertions, 1)
        XCTAssertEqual(w.deletions, 0)
        XCTAssertEqual(w.rate, 0.4, accuracy: 0.001)
        let missing = WordErrorRate.compute(reference: "one two three", hypothesis: "one three")
        XCTAssertEqual(missing.deletions, 1)
        XCTAssertEqual(WordErrorRate.compute(reference: "one two", hypothesis: "").deletions, 2)
    }

    func testMissedTerms() {
        let missed = WordErrorRate.missedTerms(["SOW", "Orchestrate"], reference: "Check the SOW for Orchestrate",
                                               hypothesis: "check the so for orchestrate")
        XCTAssertEqual(missed, ["SOW"])
    }
}

final class FillerAndScratchTests: XCTestCase {
    func testLikeBetweenRepeatedWords() {
        XCTAssertEqual(TextCleaner.clean("see how well the like the like the tidy up works"),
                       "See how well the tidy up works")
    }

    func testMisheardScratchThat() {
        let out = TextCleaner.clean("Shorty's birthday is in December. Stratch that Shorty's birthday is in November.")
        XCTAssertFalse(out.contains("December"))
        XCTAssertTrue(out.contains("November"))
    }
}

@MainActor
final class TextInserterTests: XCTestCase {
    func testElectronAppsCountAsWebBased() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Fake-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        XCTAssertFalse(TextInserter.isWebBased(bundleAt: app))
        try FileManager.default.createDirectory(at: frameworks.appendingPathComponent("Electron Framework.framework"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(TextInserter.isWebBased(bundleAt: app))
    }

    func testBrowsersAreWebBased() {
        XCTAssertTrue(TextInserter.webBrowserBundleIDs.contains("com.google.Chrome"))
        XCTAssertTrue(TextInserter.webBrowserBundleIDs.contains("com.apple.Safari"))
    }
}
