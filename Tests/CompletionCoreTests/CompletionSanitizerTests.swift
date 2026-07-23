import CompletionCore
import XCTest

final class CompletionSanitizerTests: XCTestCase {
    func testProducesAnInsertionLimitedToEightWords() {
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                "confirm the time for Thursday",
                after: "Thank you for sending this over, I’ll",
                maximumWords: 8
            ),
            " confirm the time for Thursday"
        )
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                " one two three four five six seven eight nine ten",
                after: "Count",
                maximumWords: 8
            ),
            " one two three four five six seven eight"
        )
    }

    func testPreservesModelSuppliedPunctuationAndLeadingWhitespace() {
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                " you",
                after: "thank",
                maximumWords: 8
            ),
            " you"
        )
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                "!",
                after: "sounds good",
                maximumWords: 8
            ),
            "!"
        )
    }
}
