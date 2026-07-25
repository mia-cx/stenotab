import XCTest
import CompletionCore
@testable import StenoTab

final class CompletionProviderTests: XCTestCase {
    private final class AbruptSSEURLProtocol:
        URLProtocol,
        @unchecked Sendable
    {
        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(
            for request: URLRequest
        ) -> URLRequest {
            request
        }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(
                self,
                didLoad: Data(
                    """
                    data: {"choices":[{"text":" partial","finish_reason":null}]}

                    """.utf8
                )
            )
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private let field = CapturedFieldState(
        text: "before selected after",
        selection: UTF16Selection(location: 7, length: 8)
    )
    private let sourceID = UUID()
    private let sourceContext = PersonalizationContext(
        applicationBundleIdentifier: "com.example.Source",
        editorIdentifier: "source-editor"
    )

    func testPrematureStreamTerminationRetainsPartialTextAsFailure() {
        let response = CompletionStreamTermination.failedResponse(
            requestID: 42,
            lastPublishedText: " partial",
            invocation: nil
        )

        XCTAssertEqual(response.requestID, 42)
        XCTAssertEqual(response.text, " partial")
        XCTAssertTrue(response.isFinal)
        XCTAssertTrue(response.didFail)
    }

    func testAbruptSSETerminationEmitsPartialTextAsFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AbruptSSEURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleCompletionProvider(
            endpoint: URL(string: "https://example.com/v1")!,
            apiKey: nil,
            model: "test-model",
            apiStyle: .textCompletions,
            maximumWords: 8,
            urlSession: session
        )

        var responses: [CompletionResponse] = []
        for await response in await provider.stream(request()) {
            responses.append(response)
        }

        XCTAssertEqual(responses.first?.text, "partial")
        XCTAssertEqual(responses.first?.isFinal, false)
        XCTAssertEqual(responses.last?.text, "partial")
        XCTAssertEqual(responses.last?.isFinal, true)
        XCTAssertEqual(responses.last?.didFail, true)
    }

    func testRemoteEndpointOriginExcludesCredentialsAndPath() {
        let provider = OpenAICompatibleCompletionProvider(
            endpoint: URL(
                string:
                    "https://user:secret@example.com:8443/team/v1?token=hidden"
            )!,
            apiKey: nil,
            model: "model",
            apiStyle: .chatCompletions,
            maximumWords: 8
        )

        XCTAssertEqual(
            provider.endpointOrigin,
            "https://example.com:8443"
        )
    }

    func testCapturedProviderInputMatchesEveryEncodedRequestStyle() throws {
        for style in [
            CompletionAPIStyle.textCompletions,
            .gemmaChatPrefill,
            .chatCompletions,
        ] {
            let provider = OpenAICompatibleCompletionProvider(
                endpoint: URL(string: "https://example.com/v1")!,
                apiKey: "not-retained",
                model: "test-model",
                apiStyle: style,
                maximumWords: 8
            )
            let request = request()
            let prepared = provider.makeURLRequest(for: request, stream: true)
            let body = try XCTUnwrap(prepared.urlRequest.httpBody)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body)
                    as? [String: Any]
            )
            let invocation = try XCTUnwrap(prepared.invocation)
            let seed = try XCTUnwrap(request.invocationSeed)

            XCTAssertEqual(json["model"] as? String, "test-model")
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertEqual(json["max_tokens"] as? Int, 16)
            XCTAssertEqual(json["temperature"] as? Double, 0)
            XCTAssertEqual(
                invocation.generation.endpointOrigin,
                "https://example.com"
            )
            XCTAssertEqual(
                invocation.generation.providerKind,
                "openai-compatible"
            )
            XCTAssertEqual(
                invocation.generation.modelIdentifier,
                json["model"] as? String
            )
            XCTAssertEqual(
                invocation.generation.maximumTokens,
                json["max_tokens"] as? Int
            )
            XCTAssertEqual(
                invocation.generation.temperature,
                json["temperature"] as? Double
            )
            XCTAssertEqual(invocation.id, seed.id)
            XCTAssertEqual(invocation.field, seed.field)
            XCTAssertEqual(invocation.context, seed.context)
            XCTAssertEqual(
                invocation.collectionGeneration,
                seed.collectionGeneration
            )
            XCTAssertEqual(invocation.startedAt, seed.startedAt)

            switch style {
            case .textCompletions:
                XCTAssertEqual(
                    json["prompt"] as? String,
                    invocation.prompt.textPrompt
                )
                XCTAssertEqual(invocation.generation.stopSequences, [])
                XCTAssertEqual(invocation.sourceEventIDs, seed.sourceEventIDs)
                XCTAssertEqual(invocation.sourceContexts, seed.sourceContexts)
            case .gemmaChatPrefill:
                XCTAssertEqual(
                    json["prompt"] as? String,
                    invocation.prompt.textPrompt
                )
                XCTAssertEqual(json["stop"] as? [String], ["<turn|>"])
                XCTAssertEqual(
                    invocation.generation.stopSequences,
                    json["stop"] as? [String]
                )
                XCTAssertEqual(invocation.sourceEventIDs, [])
                XCTAssertEqual(invocation.sourceContexts, [])
            case .chatCompletions:
                let messages = try XCTUnwrap(
                    json["messages"] as? [[String: Any]]
                )
                XCTAssertEqual(
                    messages.first?["content"] as? String,
                    invocation.prompt.systemMessage
                )
                XCTAssertEqual(
                    messages.last?["content"] as? String,
                    invocation.prompt.userMessage
                )
                XCTAssertEqual(invocation.generation.stopSequences, [])
                XCTAssertEqual(invocation.sourceEventIDs, seed.sourceEventIDs)
                XCTAssertEqual(invocation.sourceContexts, seed.sourceContexts)
            }
        }
    }

    private func request() -> CompletionRequest {
        let context = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Writer",
            editorIdentifier: "editor"
        )
        return CompletionRequest(
            id: 42,
            prefix: "before ",
            suffix: " after",
            context: CompletionContext(
                applicationName: "Writer",
                inputKind: "text",
                ocrContent: "recognized locally",
                clipboardContent: "copied text",
                inputHistory: "history",
                relevantInputHistory: "relevant",
                voiceAssessment: "voice"
            ),
            promptConfiguration: .defaults,
            partialWordFragment: nil,
            partialWordCandidates: [],
            invocationSeed: CompletionInvocationSeed(
                id: UUID(),
                field: field,
                context: context,
                sourceEventIDs: [sourceID],
                sourceContexts: [sourceContext],
                collectionGeneration: 37,
                startedAt: Date(timeIntervalSince1970: 10)
            )
        )
    }
}
