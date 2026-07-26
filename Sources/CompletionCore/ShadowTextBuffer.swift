public struct ShadowTextBuffer: Sendable, Equatable {
    public enum Mutation: Sendable, Equatable {
        case insert(String)
        case deleteBackward
        case deleteForward
        case invalidate
        case focusChange
    }

    public private(set) var prefix: String
    public private(set) var suffix: String
    public private(set) var needsReconciliation: Bool

    public init(prefix: String = "", suffix: String = "") {
        self.prefix = prefix
        self.suffix = suffix
        self.needsReconciliation = false
    }

    @discardableResult
    public mutating func reconcile(
        prefix: String,
        suffix: String
    ) -> Bool {
        let contentChanged = self.prefix != prefix || self.suffix != suffix
        self.prefix = prefix
        self.suffix = suffix
        needsReconciliation = false
        return contentChanged
    }

    public mutating func apply(
        _ mutation: Mutation,
        replacingSelection: Bool = false
    ) {
        switch mutation {
        case let .insert(text):
            prefix.append(text)
        case .deleteBackward:
            guard !replacingSelection else { return }
            guard !prefix.isEmpty else {
                needsReconciliation = true
                return
            }
            prefix.removeLast()
        case .deleteForward:
            guard !replacingSelection else { return }
            guard !suffix.isEmpty else {
                needsReconciliation = true
                return
            }
            suffix.removeFirst()
        case .invalidate, .focusChange:
            needsReconciliation = true
        }
    }

    public func capturedField(
        authoritativeField: CapturedFieldState,
        authoritativePrefix: String,
        authoritativeSuffix: String
    ) -> CapturedFieldState? {
        if needsReconciliation
            || (
                prefix == authoritativePrefix
                    && suffix == authoritativeSuffix
            )
        {
            return authoritativeField.selection.isValid(
                for: authoritativeField.text
            ) ? authoritativeField : nil
        }
        return CapturedFieldState(
            text: prefix + suffix,
            selection: UTF16Selection(
                location: prefix.utf16.count,
                length: 0
            )
        )
    }
}
