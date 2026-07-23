import CompletionCore
import XCTest

final class ShadowTextBufferTests: XCTestCase {
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
}
