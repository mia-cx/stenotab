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
