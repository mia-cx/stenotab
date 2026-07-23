import CompletionCore
import XCTest

final class TypographyScaleEstimatorTests: XCTestCase {
    func testEstimatesResidualScaleFromSameLineCaretAdvance() {
        let scale = TypographyScaleEstimator.estimate(
            previousPrefix: "",
            currentPrefix: "thank",
            previousCaretX: 100,
            currentCaretX: 166,
            previousCaretY: 50,
            currentCaretY: 50,
            lineHeight: 39,
            expectedAdvance: 60
        )

        XCTAssertEqual(scale, 1.1, accuracy: 0.001)
    }

    func testRejectsLineWrapAndNonAppendMutations() {
        XCTAssertNil(
            TypographyScaleEstimator.estimate(
                previousPrefix: "thank",
                currentPrefix: "thank you",
                previousCaretX: 166,
                currentCaretX: 110,
                previousCaretY: 50,
                currentCaretY: 10,
                lineHeight: 39,
                expectedAdvance: 40
            )
        )
        XCTAssertNil(
            TypographyScaleEstimator.estimate(
                previousPrefix: "thank",
                currentPrefix: "hello",
                previousCaretX: 166,
                currentCaretX: 150,
                previousCaretY: 50,
                currentCaretY: 50,
                lineHeight: 39,
                expectedAdvance: 40
            )
        )
    }

    func testRejectsImplausibleScale() {
        XCTAssertNil(
            TypographyScaleEstimator.estimate(
                previousPrefix: "",
                currentPrefix: "thank",
                previousCaretX: 100,
                currentCaretX: 200,
                previousCaretY: 50,
                currentCaretY: 50,
                lineHeight: 39,
                expectedAdvance: 50
            )
        )
    }
}
