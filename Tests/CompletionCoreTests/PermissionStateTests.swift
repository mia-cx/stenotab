import CompletionCore
import XCTest

final class PermissionStateTests: XCTestCase {
    func testRoutesToFirstMissingPermission() {
        XCTAssertEqual(
            PermissionState(
                accessibilityGranted: false,
                inputMonitoringGranted: false
            ).nextSettingsPane,
            .accessibility
        )
        XCTAssertEqual(
            PermissionState(
                accessibilityGranted: true,
                inputMonitoringGranted: false
            ).nextSettingsPane,
            .inputMonitoring
        )
        XCTAssertNil(
            PermissionState(
                accessibilityGranted: true,
                inputMonitoringGranted: true
            ).nextSettingsPane
        )
    }

    func testMenuTitleReportsBothPermissions() {
        XCTAssertEqual(
            PermissionState(
                accessibilityGranted: true,
                inputMonitoringGranted: false
            ).menuTitle,
            "Accessibility ✓  Input Monitoring ✗"
        )
    }
}
