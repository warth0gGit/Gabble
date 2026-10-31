import XCTest
@testable import Gabble

final class LexiconLearnerTests: XCTestCase {
    func testFindsAcronymsAndMixedCaseTerms() {
        let text = "Our KPI for Q3 is tied to SharePoint adoption. The KPI review uses SharePoint and O365. OK, thanks."
        let terms = LexiconLearner.candidateTerms(in: text)
        XCTAssertEqual(terms["KPI"], 2)
        XCTAssertEqual(terms["SharePoint"], 2)
        XCTAssertEqual(terms["Q3"], 1)
        XCTAssertEqual(terms["O365"], 1)
        XCTAssertNil(terms["OK"], "Common words should be ignored")
        XCTAssertNil(terms["Our"], "Ordinary capitalised words are not jargon")
    }

    func testLearnsCorrectionPairs() {
        let pairs = LexiconLearner.corrections(
            original: "we need to grow our sass revenue this quarter",
            edited: "we need to grow our SaaS revenue this quarter"
        )
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.heard, "sass")
        XCTAssertEqual(pairs.first?.corrected, "SaaS")
    }

    func testNoCorrectionsWhenUnchanged() {
        XCTAssertTrue(LexiconLearner.corrections(original: "hello there", edited: "hello there").isEmpty)
    }
}

@MainActor
final class LexiconStoreTests: XCTestCase {
    private func makeStore() -> LexiconStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        return LexiconStore(fileURL: url)
    }

    func testHarvestSuggestsRepeatedTermsOnly() {
        let store = makeStore()
        store.harvest(from: "The ARR grew. ARR matters. EBITDA once.")
        XCTAssertEqual(store.suggested.map(\.term), ["ARR"])
        XCTAssertTrue(store.confirmed.isEmpty)
    }

    func testImportListParsesMeanings() {
        let store = makeStore()
        store.importList("KPI - key performance indicator\nwatsonx\n\n")
        XCTAssertEqual(store.confirmed.count, 2)
        XCTAssertEqual(store.confirmed.first?.meaning, "key performance indicator")
    }

    func testCorrectionAddsConfirmedTermWithSoundsLike() {
        let store = makeStore()
        store.learnFromCorrection(original: "open what's an x", edited: "open watsonx")
        XCTAssertEqual(store.confirmed.first?.term, "watsonx")
        XCTAssertEqual(store.confirmed.first?.soundsLike, ["what's an x"])
    }

    func testPersistsBetweenLaunches() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        LexiconStore(fileURL: url).add(term: "OKR", meaning: "objectives and key results")
        let reloaded = LexiconStore(fileURL: url)
        XCTAssertEqual(reloaded.confirmed.map(\.term), ["OKR"])
    }
}
