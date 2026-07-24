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

    func testReportsOptionalScreenRecordingIndependently() {
        let state = PermissionState(
            accessibilityGranted: true,
            screenRecordingGranted: false
        )

        XCTAssertNil(state.nextSettingsPane)
        XCTAssertTrue(state.isGranted(.accessibility))
        XCTAssertFalse(state.isGranted(.screenRecording))
    }
}
