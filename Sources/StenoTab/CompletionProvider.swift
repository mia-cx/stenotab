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
}

protocol CompletionProvider: Sendable {
    func complete(_ request: CompletionRequest) async -> CompletionResponse
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
        urlRequest.timeoutInterval = 2
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
                    stop: nil
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
                    stop: ["<turn|>"]
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
                    stop: nil
                )
            )
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return CompletionResponse(requestID: request.id, text: nil)
            }
            let payload = try JSONDecoder().decode(CompletionPayload.self, from: data)
            let rawText = payload.choices.first.flatMap {
                $0.text ?? $0.message?.content
            }
            let text = rawText.flatMap { raw -> String? in
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
                    return CompletionSanitizer.sanitize(
                        partial,
                        after: request.prefix,
                        maximumWords: maximumWords,
                        inferLeadingSpace: false
                    )
                }
                let shouldInferMissingSeparator =
                    apiStyle == .textCompletions
                    && request.partialWordFragment != nil
                    && !request.partialWordCandidates.isEmpty
                    && !beginsWithInsertionWhitespace
                return CompletionSanitizer.sanitize(
                    raw,
                    after: request.prefix,
                    maximumWords: maximumWords,
                    inferLeadingSpace:
                        apiStyle == .chatCompletions
                        || shouldInferMissingSeparator
                )
            }
            return CompletionResponse(
                requestID: request.id,
                text: text?.isEmpty == false ? text : nil
            )
        } catch {
            return CompletionResponse(requestID: request.id, text: nil)
        }
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

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stop
        case maxTokens = "max_tokens"
    }
}

private struct TextCompletionBody: Encodable {
    let model: String
    let prompt: String
    let maxTokens: Int
    let temperature: Double
    let stop: [String]?

    enum CodingKeys: String, CodingKey {
        case model, prompt, temperature, stop
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
