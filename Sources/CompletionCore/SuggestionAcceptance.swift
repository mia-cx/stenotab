public enum SuggestionAcceptance {
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
}
