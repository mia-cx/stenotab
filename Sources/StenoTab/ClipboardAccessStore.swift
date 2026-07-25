import AppKit
import Combine
import CompletionCore

@MainActor
final class ClipboardAccessStore: ObservableObject {
    @Published private(set) var state: ClipboardAccessState

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        state = Self.state(for: pasteboard.accessBehavior)
    }

    @discardableResult
    func requestAccess() -> ClipboardAccessState {
        _ = pasteboard.string(forType: .string)
        refresh()
        return state
    }

    func refresh() {
        state = Self.state(for: pasteboard.accessBehavior)
    }

    private static func state(
        for behavior: NSPasteboard.AccessBehavior
    ) -> ClipboardAccessState {
        switch behavior {
        case .default:
            .notRequested
        case .ask:
            .askEveryTime
        case .alwaysAllow:
            .allowed
        case .alwaysDeny:
            .denied
        @unknown default:
            .notRequested
        }
    }
}
