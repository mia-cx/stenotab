import CompletionCore
import XCTest

final class SuggestionConsumptionTests: XCTestCase {
    func testInterruptedPartialStreamCanFinishAndResolve() {
        var state = SuggestionConsumption(
            suggestion: " hi",
            isFinal: false
        )

        XCTAssertEqual(
            state.apply(insertedText: " hi"),
            .awaitingStream
        )
        XCTAssertEqual(state.finishStreaming(), .waitingForWhitespace)
        XCTAssertTrue(state.hasFinishedStreaming)
    }

    func testInterruptedPartialStreamWithRunAheadDivergesOnFinish() {
        var state = SuggestionConsumption(
            suggestion: "he",
            isFinal: false
        )
        _ = state.applyWithAttribution(insertedText: "hello")

        XCTAssertEqual(state.finishStreaming(), .diverged)
        XCTAssertEqual(state.consumedSuggestionText, "he")
        XCTAssertTrue(state.hasFinishedStreaming)
    }

    func testMatchingCharactersConsumeSuggestionWithoutTriggeringInference() {
        var state = SuggestionConsumption(suggestion: " you")

        XCTAssertEqual(state.apply(insertedText: " "), .matched(remaining: "you"))
        XCTAssertEqual(state.apply(insertedText: "y"), .matched(remaining: "ou"))
        XCTAssertEqual(state.apply(insertedText: "ou"), .waitingForWhitespace)
    }

    func testMultiWordSuggestionKeepsItsLiteralSpacesWhileMatching() {
        var state = SuggestionConsumption(suggestion: " you very much")

        XCTAssertEqual(
            state.apply(insertedText: " you"),
            .matched(remaining: " very much")
        )
        XCTAssertEqual(
            state.apply(insertedText: " very"),
            .matched(remaining: " much")
        )
        XCTAssertEqual(
            state.apply(insertedText: " much"),
            .waitingForWhitespace
        )
    }

    func testCompletedSuggestionTriggersOnlyAtNextWhitespace() {
        var state = SuggestionConsumption.waitingForWhitespace()

        XCTAssertEqual(state.apply(insertedText: "!"), .waitingForWhitespace)
        XCTAssertEqual(state.apply(insertedText: " "), .triggerInference)
    }

    func testAttributionExcludesPunctuationTypedAfterSuggestion() {
        var state = SuggestionConsumption.waitingForWhitespace()

        let result = state.applyWithAttribution(insertedText: "!")

        XCTAssertEqual(result.outcome, .waitingForWhitespace)
        XCTAssertEqual(result.suggestionAttributedPrefix, "")
    }

    func testAttributionSplitsMatchedPrefixFromDivergence() {
        var state = SuggestionConsumption(suggestion: "hello")

        let result = state.applyWithAttribution(insertedText: "heX")

        XCTAssertEqual(result.outcome, .diverged)
        XCTAssertEqual(result.suggestionAttributedPrefix, "he")
    }

    func testAttributionOnlyIncludesTextAlreadyConfirmedByStream() {
        var state = SuggestionConsumption(
            suggestion: "he",
            isFinal: false
        )

        let result = state.applyWithAttribution(insertedText: "hello")

        XCTAssertEqual(result.outcome, .awaitingStream)
        XCTAssertEqual(result.suggestionAttributedPrefix, "he")
        XCTAssertEqual(state.consumedSuggestionText, "he")
    }

    func testLaterDivergentStreamCannotClaimRunAheadText() {
        var state = SuggestionConsumption(
            suggestion: "he",
            isFinal: false
        )
        _ = state.applyWithAttribution(insertedText: "hello")

        XCTAssertEqual(
            state.update(suggestion: "hero", isFinal: true),
            .diverged
        )
        XCTAssertEqual(state.consumedSuggestionText, "he")
    }

    func testMatchingLaterStreamEndsRunAheadAssociation() {
        var state = SuggestionConsumption(
            suggestion: "he",
            isFinal: false
        )
        _ = state.applyWithAttribution(insertedText: "hel")

        XCTAssertEqual(
            state.update(suggestion: "hello", isFinal: true),
            .diverged
        )
        XCTAssertEqual(state.consumedSuggestionText, "he")
    }

    func testDivergingFromSuggestionTriggersFreshInference() {
        var state = SuggestionConsumption(suggestion: " you")

        XCTAssertEqual(state.apply(insertedText: " "), .matched(remaining: "you"))
        XCTAssertEqual(state.apply(insertedText: "n"), .diverged)
    }

    func testMatchingTypingCanRunAheadOfAStreamingSuggestion() {
        var state = SuggestionConsumption(
            suggestion: " hel",
            isFinal: false
        )

        XCTAssertEqual(
            state.apply(insertedText: " hel"),
            .awaitingStream
        )
        XCTAssertEqual(
            state.update(
                suggestion: " hello wor",
                isFinal: false
            ),
            .matched(remaining: "lo wor")
        )
        XCTAssertEqual(
            state.apply(insertedText: "lo "),
            .matched(remaining: "wor")
        )
        XCTAssertEqual(
            state.update(
                suggestion: " hello world",
                isFinal: true
            ),
            .matched(remaining: "world")
        )
        XCTAssertEqual(
            state.apply(insertedText: "world"),
            .waitingForWhitespace
        )
    }

    func testTabAcceptanceConsumesOnlyItsSliceWhileStreamKeepsGrowing() {
        var state = SuggestionConsumption(
            suggestion: " hello wor",
            isFinal: false
        )
        let acceptance = SuggestionAcceptance.slice(
            in: " hello wor",
            scope: .nextWord
        )

        XCTAssertEqual(acceptance.accepted, " hello")
        XCTAssertEqual(
            state.apply(insertedText: acceptance.accepted),
            .matched(remaining: " wor")
        )
        XCTAssertEqual(
            state.update(
                suggestion: " hello world from here",
                isFinal: true
            ),
            .matched(remaining: " world from here")
        )
    }
}
