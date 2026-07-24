public enum SuggestionAcceptance {
    public struct Options: Sendable, Equatable {
        public var includeTrailingSpace: Bool
        public var includeTrailingPunctuation: Bool

        public init(
            includeTrailingSpace: Bool = false,
            includeTrailingPunctuation: Bool = true
        ) {
            self.includeTrailingSpace = includeTrailingSpace
            self.includeTrailingPunctuation = includeTrailingPunctuation
        }
    }

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

    public static func nextWord(
        in suggestion: String,
        options: Options = Options()
    ) -> Slice {
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

        var accepted = String(suggestion[..<splitIndex])
        var remaining = String(suggestion[splitIndex...])

        if !options.includeTrailingPunctuation,
           let punctuationIndex = trailingPunctuationIndex(in: accepted) {
            remaining = String(accepted[punctuationIndex...]) + remaining
            accepted = String(accepted[..<punctuationIndex])
        }

        if options.includeTrailingSpace, remaining.first == " " {
            accepted.append(" ")
            remaining.removeFirst()
        }

        return Slice(accepted: accepted, remaining: remaining)
    }

    public static func slice(
        in suggestion: String,
        scope: Scope,
        options: Options = Options()
    ) -> Slice {
        switch scope {
        case .nextWord:
            nextWord(in: suggestion, options: options)
        case .entireSuggestion:
            Slice(accepted: suggestion, remaining: "")
        }
    }

    private static func trailingPunctuationIndex(
        in accepted: String
    ) -> String.Index? {
        var reachedWord = false
        for index in accepted.indices {
            let character = accepted[index]
            if !reachedWord {
                if !character.isWhitespace {
                    reachedWord = true
                }
                continue
            }
            if !isWordCharacter(character) {
                return index
            }
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "'"
            || character == "’"
            || character == "-"
            || character == "_"
    }
}
