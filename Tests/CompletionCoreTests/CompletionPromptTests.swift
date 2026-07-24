import CompletionCore
import XCTest

final class CompletionPromptTests: XCTestCase {
    func testChatPromptKeepsContextSeparateFromLiteralUserText() {
        let context = CompletionContext(
            applicationName: "Discord",
            website: nil,
            inputKind: "message box"
        )

        let prompt = CompletionPrompt.chatUser(
            prefix: "Do anyt",
            suffix: "",
            context: context
        )

        XCTAssertEqual(
            CompletionPrompt.systemInstruction,
            "Continue the user's current text at the cursor. Match their voice. "
                + "Produce only text that should be inserted."
        )
        XCTAssertTrue(prompt.contains("The user is typing in: Discord"))
        XCTAssertTrue(prompt.contains("Kind of input: message box"))
        XCTAssertTrue(prompt.hasSuffix("Do anyt"))
        XCTAssertFalse(prompt.contains("Clipboard content:"))
        XCTAssertFalse(prompt.contains("User Voice:"))
    }

    func testBasePromptSeparatesTextFromInsertionWithDemonstrations() {
        let context = CompletionContext(
            applicationName: "ChatGPT",
            website: nil,
            inputKind: "message box"
        )

        let prompt = CompletionPrompt.base(
            prefix: "this sounds like me",
            suffix: "after the caret",
            context: context
        )

        XCTAssertTrue(
            prompt.hasPrefix(
                "Task: Continue the final Text value. "
                    + "Output only the characters to insert."
            )
        )
        XCTAssertTrue(prompt.contains("Insertion: tomorrow"))
        XCTAssertTrue(prompt.contains("Insertion: weird"))
        XCTAssertTrue(
            prompt.hasSuffix(
                "Text: this sounds like me\nInsertion:"
            )
        )
        XCTAssertFalse(prompt.contains("ChatGPT"))
        XCTAssertFalse(prompt.contains("after the caret"))
    }

    func testWordSuffixPromptEndsAtContinuationCue() {
        let prompt = CompletionPrompt.wordSuffix(prefix: "Do anythi")

        XCTAssertTrue(prompt.contains("Text: We can do anyth"))
        XCTAssertTrue(prompt.hasSuffix("Text: Do anythi\nContinuation:"))
    }
}
