public enum SuggestionAcceptance {
    public enum Scope: Sendable, Equatable {
        case nextWord
        case entireSuggestion
    }

    public struct Slice: Sendable, Equatable {
        public let accepted: String
        public let remaining: String

        public init(accepted: String, remaining: String) {
            self.accepted = accepted
            self.remaining = remaining
        }
    }

    public static func nextWord(in suggestion: String) -> Slice {
        guard !suggestion.isEmpty else {
            return Slice(accepted: "", remaining: "")
        }

        var hasReachedWord = false
        var splitIndex = suggestion.endIndex
        for index in suggestion.indices {
            let character = suggestion[index]
            if character.isWhitespace {
                if hasReachedWord {
                    splitIndex = index
                    break
                }
            } else {
                hasReachedWord = true
            }
        }

        return Slice(
            accepted: String(suggestion[..<splitIndex]),
            remaining: String(suggestion[splitIndex...])
        )
    }

    public static func slice(
        in suggestion: String,
        scope: Scope
    ) -> Slice {
        switch scope {
        case .nextWord:
            nextWord(in: suggestion)
        case .entireSuggestion:
            Slice(accepted: suggestion, remaining: "")
        }
    }
}
