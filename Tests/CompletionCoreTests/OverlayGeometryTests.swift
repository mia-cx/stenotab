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

    func testUsesNativeTextLayoutBaselineWhenAvailable() {
        let baseline = OverlayGeometry.baselineOffset(
            containerHeight: 77,
            ascent: 49.28125,
            descent: 14.71875,
            leading: 0,
            nativeLineHeight: 77,
            nativeBaselineOffsetFromTop: 62
        )

        XCTAssertEqual(baseline, 15)
    }

    func testPreparesLinePlacementBeforeSuggestionTextExists() {
        let placement = OverlayGeometry.prepareLinePlacement(
            caretRect: CGRect(x: 100, y: 50, width: 2, height: 20),
            ascent: 12,
            descent: 4,
            leading: 0,
            backingScaleFactor: 2
        )

        XCTAssertEqual(placement.origin, CGPoint(x: 102, y: 50))
        XCTAssertEqual(placement.height, 20)
        XCTAssertEqual(placement.baselineOffset, 6)
    }

    func testRepairsNativeCaretBoundsReportedOneLineAboveEndpoint() {
        let reportedCaret = CGRect(
            x: 908.75,
            y: 278,
            width: 0,
            height: 77
        )
        let previousCharacter = CGRect(
            x: 890.96875,
            y: 355,
            width: 17.78125,
            height: 77
        )

        XCTAssertEqual(
            OverlayGeometry.reconcileCaretRect(
                reportedCaret,
                previousCharacterRect: previousCharacter,
                precedingCharacterIsLineBreak: false
            ),
            CGRect(x: 908.75, y: 355, width: 0, height: 77)
        )
    }

    func testKeepsReportedCaretForRealLineBreaksAndWraps() {
        let reportedCaret = CGRect(x: 100, y: 200, width: 0, height: 20)
        let previousLineCharacter = CGRect(
            x: 500,
            y: 180,
            width: 10,
            height: 20
        )

        XCTAssertEqual(
            OverlayGeometry.reconcileCaretRect(
                reportedCaret,
                previousCharacterRect: previousLineCharacter,
                precedingCharacterIsLineBreak: false
            ),
            reportedCaret
        )
        XCTAssertEqual(
            OverlayGeometry.reconcileCaretRect(
                reportedCaret,
                previousCharacterRect: CGRect(
                    x: 90,
                    y: 220,
                    width: 10,
                    height: 20
                ),
                precedingCharacterIsLineBreak: true
            ),
            reportedCaret
        )
    }
}
