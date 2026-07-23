import CompletionCore
import XCTest

final class PermissionStateTests: XCTestCase {
    func testRoutesToAccessibilityWhenMissing() {
        XCTAssertEqual(
            PermissionState(accessibilityGranted: false).nextSettingsPane,
            .accessibility
        )
        XCTAssertNil(
            PermissionState(accessibilityGranted: true).nextSettingsPane
        )
    }

    func testMenuTitleReportsAccessibility() {
        XCTAssertEqual(
            PermissionState(accessibilityGranted: true).menuTitle,
            "Accessibility ✓"
        )
    }
}
