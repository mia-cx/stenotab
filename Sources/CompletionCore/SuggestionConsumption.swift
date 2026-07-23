public struct SuggestionConsumption: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case matched(remaining: String)
        case waitingForWhitespace
        case triggerInference
        case diverged
    }

    private var remaining: String?
    private var isWaitingForWhitespace: Bool

    public init(suggestion: String) {
        remaining = suggestion
        isWaitingForWhitespace = suggestion.isEmpty
    }

    private init(waitingForWhitespace: Bool) {
        remaining = nil
        isWaitingForWhitespace = waitingForWhitespace
    }

    public static func waitingForWhitespace() -> Self {
        Self(waitingForWhitespace: true)
    }

    public mutating func apply(insertedText: String) -> Outcome {
        for character in insertedText {
            if isWaitingForWhitespace {
                if character.isCompletionWhitespace {
                    return .triggerInference
                }
                continue
            }

            guard let expected = remaining?.first, character == expected else {
                return .diverged
            }

            remaining?.removeFirst()
            if remaining?.isEmpty == true {
                remaining = nil
                isWaitingForWhitespace = true
            }
        }

        if isWaitingForWhitespace {
            return .waitingForWhitespace
        }
        return .matched(remaining: remaining ?? "")
    }
}

private extension Character {
    var isCompletionWhitespace: Bool {
        unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }
}
