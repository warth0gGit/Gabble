import XCTest
@testable import Warble

final class InFieldIndicatorTests: XCTestCase {
    private let reach = InFieldIndicator.reach
    private let gap = InFieldIndicator.gap

    func testBallSitsJustAfterTheCursorOnItsLine() {
        let box = CGRect(x: 100, y: 700, width: 600, height: 80)
        let caret = CGRect(x: 300, y: 710, width: 0, height: 16)
        let center = InFieldIndicator.ballCenter(field: box, caret: caret, textAfter: false)
        XCTAssertEqual(center, CGPoint(x: 300 + gap + reach, y: 718))
        // Even at its biggest, the ball keeps the gap from the cursor.
        XCTAssertEqual(center!.x - reach - caret.maxX, gap)
    }

    func testBallGoesUnderTheCursorMidSentenceOrAtTheRightEdge() {
        let box = CGRect(x: 100, y: 700, width: 600, height: 80)
        let mid = CGRect(x: 300, y: 710, width: 0, height: 16)
        XCTAssertEqual(InFieldIndicator.ballCenter(field: box, caret: mid, textAfter: true),
                       CGPoint(x: 300, y: 726 + 2 + reach))
        let edge = CGRect(x: 690, y: 710, width: 0, height: 16)
        XCTAssertEqual(InFieldIndicator.ballCenter(field: box, caret: edge, textAfter: false),
                       CGPoint(x: 690, y: 726 + 2 + reach))
    }

    func testNoCursorUsesTheStartOfTheBoxNotTheFarEnd() {
        // Where an empty box's cursor is: the left of its first line.
        let tall = CGRect(x: 0, y: 50, width: 800, height: 120)
        XCTAssertEqual(InFieldIndicator.ballCenter(field: tall, caret: nil, textAfter: false),
                       CGPoint(x: 12 + reach, y: 50 + 12 + reach))
        let thin = CGRect(x: 0, y: 50, width: 400, height: 24)
        XCTAssertEqual(InFieldIndicator.ballCenter(field: thin, caret: nil, textAfter: false),
                       CGPoint(x: 12 + reach, y: 62))
    }

    func testACursorAsWideAsTheBoxIsIgnored() {
        // Some web apps answer "where's the cursor" with the whole box.
        let box = CGRect(x: 100, y: 700, width: 600, height: 40)
        XCTAssertEqual(InFieldIndicator.ballCenter(field: box, caret: box, textAfter: false),
                       CGPoint(x: 100 + 12 + reach, y: 700 + 12 + reach))
        XCTAssertFalse(CursorLocator.isCaret(box))
        XCTAssertFalse(CursorLocator.isCaret(.zero))
        XCTAssertTrue(CursorLocator.isCaret(CGRect(x: 300, y: 710, width: 0, height: 16)))
    }

    func testACursorOutsideTheBoxIsIgnored() {
        // Some web apps report the cursor at the top-left of the screen.
        let box = CGRect(x: 400, y: 600, width: 500, height: 120)
        let bogus = CGRect(x: 0, y: 0, width: 0, height: 16)
        XCTAssertEqual(InFieldIndicator.ballCenter(field: box, caret: bogus, textAfter: false),
                       CGPoint(x: 400 + 12 + reach, y: 600 + 12 + reach))
    }

    func testNothingKnownMeansTheBottomOfTheScreen() {
        XCTAssertNil(InFieldIndicator.ballCenter(field: nil, caret: nil, textAfter: false))
        XCTAssertNil(InFieldIndicator.ballCenter(field: CGRect(x: 0, y: 0, width: 5, height: 5), caret: nil, textAfter: false))
    }

    func testAccessibilityToWindowCoordinates() {
        XCTAssertEqual(InFieldIndicator.cocoaPoint(fromAccessibility: CGPoint(x: 10, y: 100), primaryScreenHeight: 1000),
                       CGPoint(x: 10, y: 900))
    }

    func testQuietSpeechStillMovesTheBall() {
        XCTAssertEqual(ListeningBall.boosted(0), 0)
        XCTAssertGreaterThan(ListeningBall.boosted(0.04), 0.25)
        XCTAssertEqual(ListeningBall.boosted(5), 1)
    }
}
