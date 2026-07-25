import CompletionCore
import XCTest

final class CompletionStreamDecoderTests: XCTestCase {
    func testDecodesOpenAITextCompletionDeltasAndDoneMarker() {
        var decoder = CompletionStreamDecoder()

        let first = decoder.consume(
            line: #"data: {"choices":[{"text":" hel","finish_reason":null}]}"#
        )
        let second = decoder.consume(
            line: #"data: {"choices":[{"text":"lo","finish_reason":null}]}"#
        )
        let done = decoder.consume(line: "data: [DONE]")

        XCTAssertEqual(
            first,
            CompletionStreamEvent(delta: " hel", isFinished: false)
        )
        XCTAssertEqual(
            second,
            CompletionStreamEvent(delta: "lo", isFinished: false)
        )
        XCTAssertEqual(
            done,
            CompletionStreamEvent(delta: "", isFinished: true)
        )
    }
}
