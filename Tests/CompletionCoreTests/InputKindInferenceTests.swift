import CompletionCore
import XCTest

final class InputKindInferenceTests: XCTestCase {
    func testSemanticAXHintsBeatGenericRoles() {
        XCTAssertEqual(
            InputKindInference.classify(
                role: "AXTextArea",
                subrole: nil,
                isWebBacked: true,
                semanticHints: ["Add a comment"]
            ),
            "comment"
        )
        XCTAssertEqual(
            InputKindInference.classify(
                role: "AXTextField",
                subrole: "AXSearchField",
                isWebBacked: false,
                semanticHints: []
            ),
            "search"
        )
    }

    func testWebEditorsAndNativeTextAreasHaveConservativeFallbacks() {
        XCTAssertEqual(
            InputKindInference.classify(
                role: "AXEditableText",
                subrole: nil,
                isWebBacked: true,
                semanticHints: []
            ),
            "message"
        )
        XCTAssertEqual(
            InputKindInference.classify(
                role: "AXTextArea",
                subrole: nil,
                isWebBacked: false,
                semanticHints: []
            ),
            "multi-line text area"
        )
    }
}
