import CompletionCore
import XCTest

final class ShadowTextBufferTests: XCTestCase {
    func testCapturedFieldPreservesAnUnchangedSelection() {
        let field = CapturedFieldState(
            text: "hello selected world",
            selection: UTF16Selection(location: 6, length: 8)
        )
        let buffer = ShadowTextBuffer(prefix: "hello ", suffix: " world")

        XCTAssertEqual(
            buffer.capturedField(
                authoritativeField: field,
                authoritativePrefix: "hello ",
                authoritativeSuffix: " world"
            ),
            field
        )
    }

    func testCapturedFieldUsesMutatedShadowAfterSelectionReplacement() {
        let field = CapturedFieldState(
            text: "hello selected world",
            selection: UTF16Selection(location: 6, length: 8)
        )
        var buffer = ShadowTextBuffer(prefix: "hello ", suffix: " world")
        buffer.apply(.insert("replacement"))

        XCTAssertEqual(
            buffer.capturedField(
                authoritativeField: field,
                authoritativePrefix: "hello ",
                authoritativeSuffix: " world"
            ),
            CapturedFieldState(
                text: "hello replacement world",
                selection: UTF16Selection(location: 17, length: 0)
            )
        )
    }

    func testAppliesTypedTextImmediately() {
        var buffer = ShadowTextBuffer(prefix: "Hello wor", suffix: "")

        buffer.apply(.insert("l"))
        buffer.apply(.insert("d"))

        XCTAssertEqual(buffer.prefix, "Hello world")
        XCTAssertTrue(buffer.suffix.isEmpty)
    }

    func testHandlesDeletionAndInvalidation() {
        var buffer = ShadowTextBuffer(prefix: "Hello!", suffix: " Next")

        buffer.apply(.deleteBackward)
        XCTAssertEqual(buffer.prefix, "Hello")
        XCTAssertEqual(buffer.suffix, " Next")

        buffer.apply(.invalidate)
        XCTAssertTrue(buffer.needsReconciliation)
    }

    func testDeletingASelectionDoesNotAlsoDeleteAdjacentText() {
        var buffer = ShadowTextBuffer(
            prefix: "before ",
            suffix: " after"
        )

        buffer.apply(.deleteBackward, replacingSelection: true)
        XCTAssertEqual(buffer.prefix, "before ")
        XCTAssertEqual(buffer.suffix, " after")

        buffer.apply(.deleteForward, replacingSelection: true)
        XCTAssertEqual(buffer.prefix, "before ")
        XCTAssertEqual(buffer.suffix, " after")
    }
}
