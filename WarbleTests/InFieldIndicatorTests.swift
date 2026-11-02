import XCTest
@testable import Warble

final class InFieldIndicatorTests: XCTestCase {
    func testAOneLineBoxIsCoveredWhole() {
        let box = CGRect(x: 100, y: 700, width: 600, height: 36)
        XCTAssertEqual(InFieldIndicator.area(field: box, caret: CGRect(x: 300, y: 710, width: 1, height: 16)), box)
    }

    func testATallBoxGetsAStripOnTheCursorLine() {
        let box = CGRect(x: 0, y: 50, width: 800, height: 400)
        let strip = InFieldIndicator.area(field: box, caret: CGRect(x: 400, y: 300, width: 1, height: 16))
        XCTAssertEqual(strip?.height, InFieldIndicator.stripHeight)
        XCTAssertEqual(strip?.midY, 308)
        XCTAssertEqual(strip?.width, 800)
        // Cursor at the very top: the strip stays inside the box.
        XCTAssertEqual(InFieldIndicator.area(field: box, caret: CGRect(x: 0, y: 50, width: 1, height: 4))?.minY, 50)
        // No cursor: the middle of the box.
        XCTAssertEqual(InFieldIndicator.area(field: box, caret: nil)?.midY, box.midY)
    }

    func testNothingKnownMeansTheCapsule() {
        XCTAssertNil(InFieldIndicator.area(field: nil, caret: nil))
        XCTAssertNil(InFieldIndicator.area(field: CGRect(x: 0, y: 0, width: 5, height: 5), caret: nil))
    }

    func testAccessibilityToWindowCoordinates() {
        let rect = InFieldIndicator.cocoaRect(fromAccessibility: CGRect(x: 10, y: 100, width: 200, height: 50),
                                              primaryScreenHeight: 1000)
        XCTAssertEqual(rect, CGRect(x: 10, y: 850, width: 200, height: 50))
    }
}
