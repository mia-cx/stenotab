import Foundation
import CompletionCore

struct CompletionRequest: Sendable {
    let id: UInt64
    let prefix: String
    let suffix: String
    let context: CompletionContext
    let promptConfiguration: PromptConfiguration
    let partialWordFragment: String?
    let partialWordCandidates: [String]
}

struct CompletionResponse: Sendable {
    let requestID: UInt64
    let text: String?
    let isFinal: Bool

    init(
        requestID: UInt64,
        text: String?,
        isFinal: Bool = true
    ) {
        self.requestID = requestID
        self.text = text
        self.isFinal = isFinal
    }
}

protocol CompletionProvider: Sendable {
    func complete(_ request: CompletionRequest) async -> CompletionResponse
    func stream(
        _ request: CompletionRequest
    ) async -> AsyncStream<CompletionResponse>
}

extension CompletionProvider {
    func stream(
        _ request: CompletionRequest
    ) async -> AsyncStream<CompletionResponse> {
        AsyncStream { continuation in
            let producer = Task {
                continuation.yield(await complete(request))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }
}

actor SwitchingCompletionProvider: CompletionProvider {
    private var provider: any CompletionProvider

    init(_ provider: any CompletionProvider) {
        self.provider = provider
    }

    func use(_ provider: any CompletionProvider) {
        self.provider = provider
    }

    func complete(_ request: CompletionRequest) async -> CompletionResponse {
        await provider.complete(request)
    }

    func stream(
        _ request: CompletionRequest
    ) async -> AsyncStream<CompletionResponse> {
        await provider.stream(request)
    }
}

struct HeuristicCompletionProvider: CompletionProvider {
    private let phrases: [(trigger: String, completion: String)] = [
        ("looking forward", " to hearing from you"),
        ("thank", " you"),
        ("thanks", " for letting me know"),
        ("we should", " consider"),
        ("i think", " this is"),
        ("could you", " please"),
        ("let me know", " what you think"),
        ("hello", ","),
        ("good morning", "!"),
    ]

    func complete(_ request: CompletionRequest) async -> CompletionResponse {
        let tail = request.prefix.lowercased().suffix(80)
        let text = phrases.first { tail.hasSuffix($0.trigger) }?.completion
        return CompletionResponse(requestID: request.id, text: text)
    }
}

struct OpenAICompatibleCompletionProvider: CompletionProvider {
    let endpoint: URL
    let apiKey: String?
    let model: String
    let apiStyle: CompletionAPIStyle
    let maximumWords: Int

    func complete(_ request: CompletionRequest) async -> CompletionResponse {
        let updates = await stream(request)
        var latest = CompletionResponse(requestID: request.id, text: nil)
        for await update in updates {
            latest = update
        }
        return latest
    }

    func stream(
        _ request: CompletionRequest
    ) async -> AsyncStream<CompletionResponse> {
        let urlRequest = makeURLRequest(for: request, stream: true)
        return AsyncStream { continuation in
            let producer = Task {
                await performStreamingRequest(
                    urlRequest,
                    completionRequest: request,
                    continuation: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    private func makeURLRequest(
        for request: CompletionRequest,
        stream: Bool
    ) -> URLRequest {
        let resource = switch apiStyle {
        case .textCompletions, .gemmaChatPrefill:
            "completions"
        case .chatCompletions:
            "chat/completions"
        }
        let path = endpoint.path.hasSuffix("/v1")
            ? resource
            : "v1/\(resource)"
        var urlRequest = URLRequest(url: endpoint.appending(path: path))
        urlRequest.httpMethod = "POST"
        // TTFT includes prompt evaluation and can exceed the old two-second
        // one-shot deadline, especially when OCR context changes the cached
        // prefix. Superseding edits cancel the streaming task explicitly.
        let host = endpoint.host?.lowercased()
        let isLocalHost = host == "127.0.0.1"
            || host == "localhost"
            || host == "::1"
        urlRequest.timeoutInterval = isLocalHost ? 120 : 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        switch apiStyle {
        case .textCompletions:
            let prompt = CompletionPrompt.compose(
                prefix: String(request.prefix.suffix(1_500)),
                suffix: String(request.suffix.prefix(300)),
                context: request.context,
                configuration: request.promptConfiguration
            ).textCompletionPrompt
            urlRequest.httpBody = try? JSONEncoder().encode(
                TextCompletionBody(
                    model: model,
                    prompt: prompt,
                    maxTokens: 16,
                    temperature: 0,
                    stop: nil,
                    stream: stream
                )
            )
        case .gemmaChatPrefill:
            urlRequest.httpBody = try? JSONEncoder().encode(
                TextCompletionBody(
                    model: model,
                    prompt: GemmaAssistantPrefill.prompt(
                        prefix: String(request.prefix.suffix(1_500)),
                        suffix: String(request.suffix.prefix(300))
                    ),
                    maxTokens: 16,
                    temperature: 0,
                    stop: ["<turn|>"],
                    stream: stream
                )
            )
        case .chatCompletions:
            let prompt = CompletionPrompt.compose(
                prefix: String(request.prefix.suffix(1_500)),
                suffix: String(request.suffix.prefix(300)),
                context: request.context,
                configuration: request.promptConfiguration
            )
            urlRequest.httpBody = try? JSONEncoder().encode(
                ChatCompletionBody(
                    model: model,
                    messages: [
                        .init(
                            role: "system",
                            content: prompt.systemMessage
                        ),
                        .init(role: "user", content: prompt.userMessage),
                    ],
                    maxTokens: 16,
                    temperature: 0,
                    stop: nil,
                    stream: stream
                )
            )
        }
        return urlRequest
    }

    private func performStreamingRequest(
        _ urlRequest: URLRequest,
        completionRequest request: CompletionRequest,
        continuation: AsyncStream<CompletionResponse>.Continuation
    ) async {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(
                for: urlRequest
            )
            guard
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                continuation.yield(
                    CompletionResponse(requestID: request.id, text: nil)
                )
                return
            }

            let contentType = httpResponse.value(
                forHTTPHeaderField: "Content-Type"
            )?.lowercased() ?? ""
            guard contentType.contains("text/event-stream") else {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                }
                continuation.yield(
                    decodeOneShot(data, request: request)
                )
                return
            }

            var decoder = CompletionStreamDecoder()
            var rawText = ""
            var lastPublishedText: String?
            var didFinish = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let event = decoder.consume(line: line) else {
                    continue
                }
                rawText += event.delta
                let text = sanitizedText(rawText, request: request)
                if
                    let text,
                    !text.isEmpty,
                    text != lastPublishedText,
                    lastPublishedText.map(text.hasPrefix) ?? true
                {
                    lastPublishedText = text
                    continuation.yield(
                        CompletionResponse(
                            requestID: request.id,
                            text: text,
                            isFinal: event.isFinished
                        )
                    )
                } else if event.isFinished {
                    continuation.yield(
                        CompletionResponse(
                            requestID: request.id,
                            text: lastPublishedText,
                            isFinal: true
                        )
                    )
                }
                if event.isFinished {
                    didFinish = true
                    break
                }
            }
            if !didFinish {
                continuation.yield(
                    CompletionResponse(
                        requestID: request.id,
                        text: lastPublishedText,
                        isFinal: true
                    )
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            continuation.yield(
                CompletionResponse(requestID: request.id, text: nil)
            )
        }
    }

    private func decodeOneShot(
        _ data: Data,
        request: CompletionRequest
    ) -> CompletionResponse {
        let payload = try? JSONDecoder().decode(
            CompletionPayload.self,
            from: data
        )
        let rawText = payload?.choices.first.flatMap {
            $0.text ?? $0.message?.content
        }
        return CompletionResponse(
            requestID: request.id,
            text: rawText.flatMap {
                sanitizedText($0, request: request)
            }
        )
    }

    private func sanitizedText(
        _ raw: String,
        request: CompletionRequest
    ) -> String? {
        let beginsWithInsertionWhitespace =
            beginsWithHorizontalWhitespaceAfterFormattingNewlines(raw)
        if
            apiStyle == .textCompletions,
            let fragment = request.partialWordFragment,
            let partial = PartialWordCompletion.sanitize(
                raw,
                after: fragment,
                candidates: request.partialWordCandidates
            )
        {
            let text = CompletionSanitizer.sanitize(
                partial,
                after: request.prefix,
                maximumWords: maximumWords,
                inferLeadingSpace: false
            )
            return text.isEmpty ? nil : text
        }
        let shouldInferMissingSeparator =
            apiStyle == .textCompletions
            && request.partialWordFragment != nil
            && !request.partialWordCandidates.isEmpty
            && !beginsWithInsertionWhitespace
        let text = CompletionSanitizer.sanitize(
            raw,
            after: request.prefix,
            maximumWords: maximumWords,
            inferLeadingSpace:
                apiStyle == .chatCompletions
                || shouldInferMissingSeparator
        )
        return text.isEmpty ? nil : text
    }

    private func beginsWithHorizontalWhitespaceAfterFormattingNewlines(
        _ value: String
    ) -> Bool {
        var remainder = value[...]
        while remainder.first == "\n" || remainder.first == "\r" {
            remainder.removeFirst()
        }
        return remainder.first == " " || remainder.first == "\t"
    }
}

private struct ChatCompletionBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let maxTokens: Int
    let temperature: Double
    let stop: [String]?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stop, stream
        case maxTokens = "max_tokens"
    }
}

private struct TextCompletionBody: Encodable {
    let model: String
    let prompt: String
    let maxTokens: Int
    let temperature: Double
    let stop: [String]?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, prompt, temperature, stop, stream
        case maxTokens = "max_tokens"
    }
}

private struct CompletionPayload: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
        let text: String?
    }

    let choices: [Choice]
}

enum ProviderFactory {
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any CompletionProvider {
        if
            let base = environment["STENOTAB_BASE_URL"],
            let url = URL(string: base),
            let model = environment["STENOTAB_MODEL"]
        {
            return OpenAICompatibleCompletionProvider(
                endpoint: url,
                apiKey: environment["STENOTAB_API_KEY"],
                model: model,
                apiStyle: CompletionAPIStyle(
                    rawValue: environment["STENOTAB_API_STYLE"]
                        ?? "chatCompletions"
                ) ?? .chatCompletions,
                maximumWords: Int(
                    environment["STENOTAB_MAXIMUM_WORDS"] ?? ""
                ) ?? 8
            )
        }

        if let configuration = localConfiguration(),
           let provider = makeLocal(configuration: configuration) {
            return provider
        }

        return HeuristicCompletionProvider()
    }

    static func makeLocal(
        configuration: LocalCompletionConfiguration,
        baseURL: URL? = nil,
        modelID: String? = nil
    ) -> (any CompletionProvider)? {
        guard
            let profile = configuration.selectedProfile,
            let url = baseURL ?? URL(string: configuration.baseURL)
        else {
            return nil
        }
        return OpenAICompatibleCompletionProvider(
            endpoint: url,
            apiKey: nil,
            model: modelID ?? profile.serverModelID,
            apiStyle: profile.apiStyle,
            maximumWords: configuration.maximumWords
        )
    }

    static func localConfiguration()
        -> LocalCompletionConfiguration?
    {
        guard
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }
        let url = applicationSupport
            .appending(path: "StenoTab")
            .appending(path: "local-model.json")
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: url) {
            return try? decoder.decode(
                LocalCompletionConfiguration.self,
                from: data
            )
        }
        return nil
    }
}
