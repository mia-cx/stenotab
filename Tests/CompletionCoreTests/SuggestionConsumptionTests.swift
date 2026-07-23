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
}
