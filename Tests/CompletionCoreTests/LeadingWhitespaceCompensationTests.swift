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
}
