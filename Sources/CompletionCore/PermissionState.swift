public struct PermissionState: Sendable, Equatable {
    public enum SettingsPane: Sendable, Equatable {
        case accessibility
    }

    public let accessibilityGranted: Bool

    public init(accessibilityGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
    }

    public var nextSettingsPane: SettingsPane? {
        if !accessibilityGranted {
            return .accessibility
        }
        return nil
    }

    public var menuTitle: String {
        "Accessibility \(accessibilityGranted ? "✓" : "✗")"
    }
}
