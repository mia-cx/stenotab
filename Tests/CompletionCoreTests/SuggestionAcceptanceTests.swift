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

    func testCanLeaveAttachedPunctuationForTheNextAcceptance() {
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(
                in: " Thursday, if that works",
                options: .init(includeTrailingPunctuation: false)
            ),
            .init(accepted: " Thursday", remaining: ", if that works")
        )
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(
                in: "word-completion works",
                options: .init(includeTrailingPunctuation: false)
            ),
            .init(accepted: "word-completion", remaining: " works")
        )
    }

    func testCanIncludeOneGeneratedTrailingSpace() {
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(
                in: " you very much",
                options: .init(includeTrailingSpace: true)
            ),
            .init(accepted: " you ", remaining: "very much")
        )
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(
                in: "ping.",
                options: .init(includeTrailingSpace: true)
            ),
            .init(accepted: "ping.", remaining: "")
        )
    }

    func testAcceptsTheWholeSuggestionWhenOnlyOneWordRemains() {
        XCTAssertEqual(
            SuggestionAcceptance.nextWord(in: "ping."),
            .init(accepted: "ping.", remaining: "")
        )
    }

    func testEntireSuggestionScopeAcceptsAllRemainingText() {
        XCTAssertEqual(
            SuggestionAcceptance.slice(
                in: " you very much",
                scope: .entireSuggestion
            ),
            .init(accepted: " you very much", remaining: "")
        )
    }
}
