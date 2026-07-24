import CompletionCore
import XCTest

final class SuggestionRefillPolicyTests: XCTestCase {
    func testPrefetchesAsTabAcceptanceApproachesTheEnd() {
        XCTAssertTrue(
            SuggestionRefillPolicy.shouldPrefetch(
                remainingSuggestion: " very much"
            )
        )
        XCTAssertTrue(
            SuggestionRefillPolicy.shouldPrefetch(
                remainingSuggestion: " much"
            )
        )
        XCTAssertFalse(
            SuggestionRefillPolicy.shouldPrefetch(
                remainingSuggestion: " very much for checking"
            )
        )
        XCTAssertFalse(
            SuggestionRefillPolicy.shouldPrefetch(
                remainingSuggestion: ""
            )
        )
    }
}
