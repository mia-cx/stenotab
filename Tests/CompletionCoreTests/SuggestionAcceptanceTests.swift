import CompletionCore
import XCTest

final class SuggestionAcceptanceTests: XCTestCase {
    func testAcceptsOneWordAndKeepsTheRestForAnotherTab() {
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(in: " you very much"),
            .init(accepted: " you", remaining: " very much")
        )
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(in: "ing about this"),
            .init(accepted: "ing", remaining: " about this")
        )
    }

    func testKeepsPunctuationAttachedToTheAcceptedWord() {
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(in: " Thursday, if that works"),
            .init(accepted: " Thursday,", remaining: " if that works")
        )
    }

    func testAcceptsTheWholeSuggestionWhenOnlyOneWordRemains() {
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(in: "ping."),
            .init(accepted: "ping.", remaining: "")
        )
    }
}
