import XCTest
@testable import Warble

final class MatrixOverlayTests: XCTestCase {
    func testASmallTextBoxIsCoveredWhole() {
        let box = CGRect(x: 100, y: 700, width: 600, height: 80)
        XCTAssertEqual(MatrixOverlay.area(field: box, caret: CGRect(x: 300, y: 720, width: 1, height: 16)), box)
        XCTAssertEqual(MatrixOverlay.area(field: box, caret: nil), box)
    }

    func testABigDocumentGetsABandAroundTheCursor() {
        let page = CGRect(x: 0, y: 50, width: 1200, height: 900)
        let caret = CGRect(x: 400, y: 500, width: 1, height: 16)
        let band = MatrixOverlay.area(field: page, caret: caret)
        XCTAssertEqual(band?.height, MatrixOverlay.caretBand)
        XCTAssertEqual(band?.midY, caret.midY)
        XCTAssertEqual(band?.width, 720)
        // No cursor position: the top of the text area.
        XCTAssertEqual(MatrixOverlay.area(field: page, caret: nil)?.height, MatrixOverlay.maxHeight)
    }

    func testNothingKnownMeansNoEffect() {
        XCTAssertNil(MatrixOverlay.area(field: nil, caret: nil))
        XCTAssertNil(MatrixOverlay.area(field: CGRect(x: 0, y: 0, width: 5, height: 5), caret: nil))
    }

    func testAccessibilityToWindowCoordinates() {
        let rect = MatrixOverlay.cocoaRect(fromAccessibility: CGRect(x: 10, y: 100, width: 200, height: 50),
                                           primaryScreenHeight: 1000)
        XCTAssertEqual(rect, CGRect(x: 10, y: 850, width: 200, height: 50))
    }
}
