public enum ClipboardAccessEnableAction: Sendable, Equatable {
    case enable
    case requestAccess
    case openSettings
}

public enum ClipboardAccessState: Sendable, Equatable {
    case notRequested
    case askEveryTime
    case allowed
    case denied

    public var enableAction: ClipboardAccessEnableAction {
        switch self {
        case .notRequested, .askEveryTime:
            .requestAccess
        case .allowed:
            .enable
        case .denied:
            .openSettings
        }
    }
}
