import CompletionCore
import XCTest

final class HuggingFaceRepositorySelectionTests: XCTestCase {
    func testNormalizesRepositoryIDsAndHuggingFaceURLs() {
        XCTAssertEqual(
            HuggingFaceRepositorySelection.normalizedRepositoryID(
                from: " mradermacher/gemma-4-E2B-GGUF "
            ),
            "mradermacher/gemma-4-E2B-GGUF"
        )
        XCTAssertEqual(
            HuggingFaceRepositorySelection.normalizedRepositoryID(
                from:
                    "https://huggingface.co/mradermacher/gemma-4-E2B-GGUF"
            ),
            "mradermacher/gemma-4-E2B-GGUF"
        )
        XCTAssertNil(
            HuggingFaceRepositorySelection.normalizedRepositoryID(
                from: "https://example.com/owner/model"
            )
        )
        XCTAssertNil(
            HuggingFaceRepositorySelection.normalizedRepositoryID(
                from: "../model"
            )
        )
    }

    func testPrefersSingleFileQ4KMAndRejectsSplitFiles() {
        XCTAssertEqual(
            HuggingFaceRepositorySelection.preferredGGUFFile(
                from: [
                    "model.Q8_0.gguf",
                    "model.Q4_K_M-00001-of-00002.gguf",
                    "model.Q4_K_M-00002-of-00002.gguf",
                    "model.Q4_K_S.gguf",
                    "model.Q4_K_M.gguf",
                ]
            ),
            "model.Q4_K_M.gguf"
        )
        XCTAssertNil(
            HuggingFaceRepositorySelection.preferredGGUFFile(
                from: [
                    "README.md",
                    "model-00001-of-00002.gguf",
                    "model-00002-of-00002.gguf",
                ]
            )
        )
    }
}
