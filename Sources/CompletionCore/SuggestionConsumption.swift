public struct SuggestionConsumption: Sendable, Equatable {
    public struct AttributedOutcome: Sendable, Equatable {
        public let outcome: Outcome
        public let suggestionAttributedPrefix: String
    }

    public enum Outcome: Sendable, Equatable {
        case matched(remaining: String)
        case awaitingStream
        case waitingForWhitespace
        case triggerInference
        case diverged
    }

    private var streamed: [Character]
    private var consumed: [Character]
    private var confirmedConsumedCount: Int
    private var isFinal: Bool
    private var isWaitingForWhitespace: Bool

    public var hasFinishedStreaming: Bool {
        isFinal
    }

    public var consumedSuggestionText: String {
        let maximumCount = min(
            confirmedConsumedCount,
            consumed.count,
            streamed.count
        )
        let matchedCount = (0..<maximumCount).first {
            consumed[$0] != streamed[$0]
        } ?? maximumCount
        return String(consumed.prefix(matchedCount))
    }

    public init(suggestion: String, isFinal: Bool = true) {
        streamed = Array(suggestion)
        consumed = []
        confirmedConsumedCount = 0
        self.isFinal = isFinal
        isWaitingForWhitespace = isFinal && suggestion.isEmpty
    }

    private init(waitingForWhitespace: Bool) {
        streamed = []
        consumed = []
        confirmedConsumedCount = 0
        isFinal = true
        isWaitingForWhitespace = waitingForWhitespace
    }

    public static func waitingForWhitespace() -> Self {
        Self(waitingForWhitespace: true)
    }

    public mutating func update(
        suggestion: String,
        isFinal: Bool
    ) -> Outcome {
        streamed = Array(suggestion)
        self.isFinal = isFinal
        return evaluate()
    }

    public mutating func finishStreaming() -> Outcome {
        isFinal = true
        return evaluate()
    }

    public mutating func apply(insertedText: String) -> Outcome {
        for character in insertedText {
            if isWaitingForWhitespace {
                if character.isCompletionWhitespace {
                    return .triggerInference
                }
                continue
            }

            let index = consumed.count
            if index < streamed.count, streamed[index] != character {
                return .diverged
            }
            consumed.append(character)
            if
                index < streamed.count,
                confirmedConsumedCount == index
            {
                confirmedConsumedCount += 1
            }
        }

        return evaluate()
    }

    public mutating func applyWithAttribution(
        insertedText: String
    ) -> AttributedOutcome {
        let consumedCountBefore = consumedSuggestionText.count
        let outcome = apply(insertedText: insertedText)
        let matchedPrefix = String(
            consumedSuggestionText.dropFirst(consumedCountBefore)
        )
        return AttributedOutcome(
            outcome: outcome,
            suggestionAttributedPrefix: matchedPrefix
        )
    }

    private mutating func evaluate() -> Outcome {
        for index in 0..<min(consumed.count, streamed.count)
        where consumed[index] != streamed[index] {
            return .diverged
        }

        if consumed.count < streamed.count {
            return .matched(
                remaining: String(streamed.dropFirst(consumed.count))
            )
        }
        if !isFinal {
            return .awaitingStream
        }

        isWaitingForWhitespace = true
        if consumed.count > streamed.count {
            let typedPastCompletion = consumed.dropFirst(streamed.count)
            if typedPastCompletion.contains(where: \.isCompletionWhitespace) {
                return .triggerInference
            }
        }
        return .waitingForWhitespace
    }
}

private extension Character {
    var isCompletionWhitespace: Bool {
        unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }
}
