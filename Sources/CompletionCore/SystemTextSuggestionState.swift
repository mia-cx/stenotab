public struct SystemTextSuggestionState: Sendable, Equatable {
    public let inlinePredictiveTextEnabled: Bool
    public let suggestedRepliesEnabled: Bool

    public init(
        inlinePredictiveTextEnabled: Bool,
        suggestedRepliesEnabled: Bool
    ) {
        self.inlinePredictiveTextEnabled = inlinePredictiveTextEnabled
        self.suggestedRepliesEnabled = suggestedRepliesEnabled
    }

    public var isConfiguredForStenoTab: Bool {
        !inlinePredictiveTextEnabled && !suggestedRepliesEnabled
    }

    public var enabledSettingNames: [String] {
        var names: [String] = []
        if inlinePredictiveTextEnabled {
            names.append("inline predictive text")
        }
        if suggestedRepliesEnabled {
            names.append("suggested replies")
        }
        return names
    }
}
