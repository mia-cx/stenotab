import CoreGraphics
import XCTest
@testable import CompletionCore

final class CaretReanchorPolicyTests: XCTestCase {
    func testRejectsUpdatedTextWithStaleCaretGeometry() {
        let previousCaret = CGRect(x: 180, y: 100, width: 0, height: 22)

        XCTAssertFalse(
            CaretReanchorPolicy.isReady(
                previousPrefix: "aligned to the left,",
                expectedPrefix: "aligned to the left,and",
                observedPrefix: "aligned to the left,and",
                previousCaretRect: previousCaret,
                observedCaretRect: previousCaret
            )
        )
    }

    func testAcceptsAuthoritativeCaretAfterTextWraps() {
        XCTAssertTrue(
            CaretReanchorPolicy.isReady(
                previousPrefix: "aligned to the left,",
                expectedPrefix: "aligned to the left,and",
                observedPrefix: "aligned to the left,and",
                previousCaretRect: CGRect(
                    x: 180,
                    y: 100,
                    width: 0,
                    height: 22
                ),
                observedCaretRect: CGRect(
                    x: 42,
                    y: 78,
                    width: 0,
                    height: 22
                )
            )
        )
    }

    func testAcceptsAuthoritativeCaretMovementOnTheSameLine() {
        XCTAssertTrue(
            CaretReanchorPolicy.isReady(
                previousPrefix: "thank",
                expectedPrefix: "thank you",
                observedPrefix: "thank you",
                previousCaretRect: CGRect(
                    x: 100,
                    y: 100,
                    width: 0,
                    height: 22
                ),
                observedCaretRect: CGRect(
                    x: 138,
                    y: 100,
                    width: 0,
                    height: 22
                )
            )
        )
    }
}
