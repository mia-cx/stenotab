public struct PermissionState: Sendable, Equatable {
    public enum SettingsPane: Sendable, Equatable {
        case accessibility
        case inputMonitoring
    }

    public let accessibilityGranted: Bool
    public let inputMonitoringGranted: Bool

    public init(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
    }

    public var nextSettingsPane: SettingsPane? {
        if !accessibilityGranted {
            return .accessibility
        }
        if !inputMonitoringGranted {
            return .inputMonitoring
        }
        return nil
    }

    public var menuTitle: String {
        "Accessibility \(accessibilityGranted ? "✓" : "✗")  " +
            "Input Monitoring \(inputMonitoringGranted ? "✓" : "✗")"
    }
}
