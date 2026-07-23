import CompletionCore
import XCTest

final class GemmaAssistantPrefillTests: XCTestCase {
    func testFormatsExistingTextAsAnUnclosedModelTurn() {
        XCTAssertEqual(
            GemmaAssistantPrefill.prompt(
                prefix: "I am typ",
                suffix: ""
            ),
            """
            <bos><|turn>user
            Continue the assistant text naturally. Return only the continuation.<turn|>
            <|turn>model
            I am typ
            """
        )
    }

    func testIncludesExistingSuffixAsContextWithoutAddingItToPrefill() {
        let prompt = GemmaAssistantPrefill.prompt(
            prefix: "hello ",
            suffix: "world"
        )

        XCTAssertTrue(prompt.contains("Existing text after the cursor: world"))
        XCTAssertTrue(prompt.hasSuffix("<|turn>model\nhello "))
    }
}
