import CompletionCore
import XCTest

final class EditorTypographyTests: XCTestCase {
    func testReportedFontAndSizeWinOverCaretFallback() {
        let typography = EditorTypography(
            reportedFontName: "SFMono-Regular",
            reportedPointSize: 13,
            caretHeight: 40
        )

        XCTAssertEqual(typography.fontName, "SFMono-Regular")
        XCTAssertEqual(typography.pointSize, 13)
    }

    func testMissingSizeIsInferredFromCaretHeightAndClamped() {
        XCTAssertEqual(
            EditorTypography(
                reportedFontName: nil,
                reportedPointSize: nil,
                caretHeight: 20
            ).pointSize,
            16
        )
        XCTAssertEqual(
            EditorTypography(
                reportedFontName: nil,
                reportedPointSize: nil,
                caretHeight: 200
            ).pointSize,
            72
        )
    }

    func testWebEditorReconcilesUnscaledReportedSizeWithZoomedCaret() {
        let typography = EditorTypography(
            reportedFontName: nil,
            reportedPointSize: 16,
            caretHeight: 39,
            reconcileReportedSizeWithCaret: true
        )

        XCTAssertEqual(typography.pointSize, 25.35, accuracy: 0.001)
    }

    func testWebEditorKeepsReportedSizeAtNormalCaretRatio() {
        let typography = EditorTypography(
            reportedFontName: nil,
            reportedPointSize: 16,
            caretHeight: 27,
            reconcileReportedSizeWithCaret: true
        )

        XCTAssertEqual(typography.pointSize, 16)
    }

    func testWebEditorUsesConservativeCaretFallbackWhenSizeIsMissing() {
        let typography = EditorTypography(
            reportedFontName: nil,
            reportedPointSize: nil,
            caretHeight: 39,
            reconcileReportedSizeWithCaret: true
        )

        XCTAssertEqual(typography.pointSize, 25.35, accuracy: 0.001)
    }

    func testUnavailableCaretGeometryUsesSystemTextSize() {
        XCTAssertEqual(
            EditorTypography(
                reportedFontName: nil,
                reportedPointSize: nil,
                caretHeight: 0
            ).pointSize,
            13
        )
    }
}
