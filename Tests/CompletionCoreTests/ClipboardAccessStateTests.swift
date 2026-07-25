import CompletionCore
import XCTest

final class ClipboardAccessStateTests: XCTestCase {
    func testEnablingClipboardContextUsesTheRequiredAccessFlow() {
        XCTAssertEqual(
            ClipboardAccessState.notRequested.enableAction,
            .requestAccess
        )
        XCTAssertEqual(
            ClipboardAccessState.askEveryTime.enableAction,
            .requestAccess
        )
        XCTAssertEqual(
            ClipboardAccessState.allowed.enableAction,
            .enable
        )
        XCTAssertEqual(
            ClipboardAccessState.denied.enableAction,
            .openSettings
        )
    }
}
