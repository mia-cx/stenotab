import CoreGraphics
import XCTest
@testable import CompletionCore

final class OverlayGeometryTests: XCTestCase {
    func testAlignsOverlayOriginToPhysicalPixels() {
        XCTAssertEqual(
            OverlayGeometry.pixelAlignedOrigin(
                CGPoint(x: 100.24, y: 50.26),
                backingScaleFactor: 2
            ),
            CGPoint(x: 100, y: 50.5)
        )
        XCTAssertEqual(
            OverlayGeometry.pixelAlignedOrigin(
                CGPoint(x: 100.49, y: 50.51),
                backingScaleFactor: 1
            ),
            CGPoint(x: 100, y: 51)
        )
    }

    func testRejectsChromiumZeroHeightSentinelBounds() {
        let sentinel = CGRect(x: 0, y: 1_440, width: 0, height: 0)

        XCTAssertFalse(OverlayGeometry.isUsableCaretRect(sentinel))
    }

    func testAcceptsZeroWidthCaretWithLineHeight() {
        let caret = CGRect(x: 667, y: 1_356, width: 0, height: 39)

        XCTAssertTrue(OverlayGeometry.isUsableCaretRect(caret))
    }

    func testCentersCoreTextLineBoxAndReturnsItsBaseline() {
        let baseline = OverlayGeometry.baselineOffset(
            containerHeight: 20,
            ascent: 12,
            descent: 4,
            leading: 0
        )

        XCTAssertEqual(baseline, 6)
    }
}
