public struct ShadowTextBuffer: Sendable, Equatable {
    public enum Mutation: Sendable, Equatable {
        case insert(String)
        case deleteBackward
        case deleteForward
        case invalidate
    }

    public private(set) var prefix: String
    public private(set) var suffix: String
    public private(set) var needsReconciliation: Bool

    public init(prefix: String = "", suffix: String = "") {
        self.prefix = prefix
        self.suffix = suffix
        self.needsReconciliation = false
    }

    public mutating func reconcile(prefix: String, suffix: String) {
        self.prefix = prefix
        self.suffix = suffix
        needsReconciliation = false
    }

    public mutating func apply(_ mutation: Mutation) {
        switch mutation {
        case let .insert(text):
            prefix.append(text)
        case .deleteBackward:
            guard !prefix.isEmpty else {
                needsReconciliation = true
                return
            }
            prefix.removeLast()
        case .deleteForward:
            guard !suffix.isEmpty else {
                needsReconciliation = true
                return
            }
            suffix.removeFirst()
        case .invalidate:
            needsReconciliation = true
        }
    }
}
