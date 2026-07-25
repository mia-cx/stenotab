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

    func testRemovesGeneratedSeparatorWhenPrefixAlreadyEndsInWhitespace() {
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                " very much",
                after: "thank you ",
                maximumWords: 8,
                inferLeadingSpace: false
            ),
            "very much"
        )
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                "world",
                after: "hello ",
                maximumWords: 8,
                inferLeadingSpace: false
            ),
            "world"
        )
    }

    func testPreservesExactPartialWordContinuationForPrefill() {
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                "ping.",
                after: "actually ty",
                maximumWords: 8,
                inferLeadingSpace: false
            ),
            "ping."
        )
    }

    func testLeadingFormattingNewlinesDoNotEraseAValidCompletion() {
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                "\n\n the server is down\n\nContext:",
                after: "I think",
                maximumWords: 8,
                inferLeadingSpace: false
            ),
            " the server is down"
        )
    }

    func testOnlyTheFirstGeneratedContentLineIsUsedForInlineGhostText() {
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                " the first line\nsecond generated line",
                after: "Continue",
                maximumWords: 8,
                inferLeadingSpace: false
            ),
            " the first line"
        )
    }

    func testRemovesThePromptOnlyWritingMarkerFromACompletion() {
        XCTAssertEqual(
            CompletionSanitizer.sanitize(
                "§hing I can do",
                after: "anyt",
                maximumWords: 8,
                inferLeadingSpace: false
            ),
            "hing I can do"
        )
    }

    func testRejectsInternalPromptScaffolding() {
        for leaked in [
            "[Completion instructions]",
            "[Context]",
            "[Text before cursor]",
            "Completion instructions:",
            "Current application: Discord",
            "Relevant input history: hello",
            "User voice assessment: casual",
            "Custom voice: concise",
            "Some examples of my writing:",
            "My writing:",
            "I am typing the text at the end on my Mac.",
            "I am typing the text at the end of this document on my computer.",
            "I'm writing this on my Mac",
            "I'm writing a message in ChatGPT.",
            "I am writing a message in ChatGPT.",
            "Some text that is on screen around where I am typing:",
            "I have this saved to my clipboard:",
            "I have recently written text like:",
            "Other relevant examples of my writing are:",
            "I have noticed that my writing typically looks like this:",
            "I describe myself like this:",
            "Some additional context that may or may not be relevant to my writing:",
            "Some text that is visible on the screen around where I am typing:",
            "I am not an assistant and won't explain more than what the conversation requires.",
            "From this point forward I will only write real text.",
        ] {
            XCTAssertEqual(
                CompletionSanitizer.sanitize(
                    leaked,
                    after: "a",
                    maximumWords: 8,
                    inferLeadingSpace: false
                ),
                ""
            )
        }
    }

    func testRejectsMarkupAndCodeFenceLeakage() {
        for leaked in [
            "<code>\\n</code> or <code>\\r</code>",
            "<div>generated corpus markup</div>",
            "```html",
        ] {
            XCTAssertEqual(
                CompletionSanitizer.sanitize(
                    leaked,
                    after: "Do",
                    maximumWords: 8,
                    inferLeadingSpace: false
                ),
                ""
            )
        }
    }

    func testBoundsSingleUnbrokenProviderToken() {
        let sanitized = CompletionSanitizer.sanitize(
            String(repeating: "x", count: 10_000),
            after: "",
            maximumWords: 8,
            inferLeadingSpace: false
        )

        XCTAssertEqual(sanitized.count, 4_096)
    }
}
