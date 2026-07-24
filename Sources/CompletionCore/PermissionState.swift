public struct PermissionState: Sendable, Equatable {
    public enum SettingsPane: Sendable, Equatable {
        case accessibility
        case screenRecording
    }

    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool

    public init(
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool = false
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
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

    public func isGranted(_ pane: SettingsPane) -> Bool {
        switch pane {
        case .accessibility:
            accessibilityGranted
        case .screenRecording:
            screenRecordingGranted
        }
    }
}
