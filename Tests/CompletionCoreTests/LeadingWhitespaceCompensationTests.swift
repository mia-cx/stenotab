import CompletionCore
import XCTest

final class LeadingWhitespaceCompensationTests: XCTestCase {
    func testCompensatesForWiderWebEditorSpaceAdvance() {
        XCTAssertEqual(
            LeadingWhitespaceCompensation.points(
                for: " you",
                caretHeight: 32,
                isWebBacked: true
            ),
            4,
            accuracy: 0.001
        )
    }

    func testScalesWithZoomAndNumberOfLeadingSpaces() {
        XCTAssertEqual(
            LeadingWhitespaceCompensation.points(
                for: "  indented",
                caretHeight: 40,
                isWebBacked: true
            ),
            10,
            accuracy: 0.001
        )
    }

    func testLeavesNativeAndNonWhitespaceSuggestionsUnchanged() {
        XCTAssertEqual(
            LeadingWhitespaceCompensation.points(
                for: " you",
                caretHeight: 32,
                isWebBacked: false
            ),
            0
        )
        XCTAssertEqual(
            LeadingWhitespaceCompensation.points(
                for: "you",
                caretHeight: 32,
                isWebBacked: true
            ),
            0
        )
    }

    func testLearnsDifferentFontDependentSpaceAdvances() {
        var compactFont = LeadingWhitespaceCalibration()
        var wideFont = LeadingWhitespaceCalibration()

        XCTAssertTrue(
            compactFont.consider(
                observedAdvance: 42,
                renderedAdvance: 40,
                caretHeight: 32,
                leadingSpaceCount: 1
            )
        )
        XCTAssertTrue(
            wideFont.consider(
                observedAdvance: 45,
                renderedAdvance: 40,
                caretHeight: 32,
                leadingSpaceCount: 1
            )
        )

        XCTAssertEqual(
            compactFont.points(
                for: " you",
                caretHeight: 32,
                isWebBacked: true
            ),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            wideFont.points(
                for: " you",
                caretHeight: 32,
                isWebBacked: true
            ),
            5,
            accuracy: 0.001
        )
    }

    func testLearnedCorrectionScalesWithZoom() {
        var calibration = LeadingWhitespaceCalibration()
        calibration.consider(
            observedAdvance: 44,
            renderedAdvance: 40,
            caretHeight: 32,
            leadingSpaceCount: 1
        )

        XCTAssertEqual(
            calibration.points(
                for: " you",
                caretHeight: 40,
                isWebBacked: true
            ),
            5,
            accuracy: 0.001
        )
    }
}
