import CompletionCore
import XCTest

final class SuggestionConsumptionTests: XCTestCase {
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
