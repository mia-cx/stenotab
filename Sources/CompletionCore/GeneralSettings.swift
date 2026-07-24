public struct GeneralSettings: Codable, Equatable, Sendable {
    public var showMenuBarIcon: Bool
    public var includeTrailingSpaceWhenAcceptingWord: Bool
    public var includeTrailingPunctuationWhenAcceptingWord: Bool

    public init(
        showMenuBarIcon: Bool = true,
        includeTrailingSpaceWhenAcceptingWord: Bool = false,
        includeTrailingPunctuationWhenAcceptingWord: Bool = true
    ) {
        self.showMenuBarIcon = showMenuBarIcon
        self.includeTrailingSpaceWhenAcceptingWord =
            includeTrailingSpaceWhenAcceptingWord
        self.includeTrailingPunctuationWhenAcceptingWord =
            includeTrailingPunctuationWhenAcceptingWord
    }

    public var suggestionAcceptanceOptions:
        SuggestionAcceptance.Options
    {
        SuggestionAcceptance.Options(
            includeTrailingSpace: includeTrailingSpaceWhenAcceptingWord,
            includeTrailingPunctuation:
                includeTrailingPunctuationWhenAcceptingWord
        )
    }
}
