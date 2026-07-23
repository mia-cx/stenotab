import Foundation
import CompletionCore

struct CompletionRequest: Sendable {
    let id: UInt64
    let prefix: String
    let suffix: String
}

struct CompletionResponse: Sendable {
    let requestID: UInt64
    let text: String?
}

protocol CompletionProvider: Sendable {
    func complete(_ request: CompletionRequest) async -> CompletionResponse
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
        case .textCompletions:
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
            urlRequest.httpBody = try? JSONEncoder().encode(
                TextCompletionBody(
                    model: model,
                    prompt: String(request.prefix.suffix(1_500)),
                    maxTokens: 16,
                    temperature: 0,
                    stop: ["\n"]
                )
            )
        case .chatCompletions:
            let prompt = """
            Autocomplete at <CURSOR>. Return only the natural text to insert, \
            at most \(maximumWords) words. Never repeat existing text.
            CONTEXT:
            \(request.prefix.suffix(1_500))<CURSOR>\(request.suffix.prefix(300))
            """
            urlRequest.httpBody = try? JSONEncoder().encode(
                ChatCompletionBody(
                    model: model,
                    messages: [.init(role: "user", content: prompt)],
                    maxTokens: 16,
                    temperature: 0,
                    stop: ["\n"]
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
            let text = rawText.map {
                CompletionSanitizer.sanitize(
                    $0,
                    after: request.prefix,
                    maximumWords: maximumWords
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
    let stop: [String]

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
    let stop: [String]

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
            let base = environment["TAB_COMPLETION_BASE_URL"],
            let url = URL(string: base),
            let model = environment["TAB_COMPLETION_MODEL"]
        {
            return OpenAICompatibleCompletionProvider(
                endpoint: url,
                apiKey: environment["TAB_COMPLETION_API_KEY"],
                model: model,
                apiStyle: CompletionAPIStyle(
                    rawValue: environment["TAB_COMPLETION_API_STYLE"]
                        ?? "chatCompletions"
                ) ?? .chatCompletions,
                maximumWords: Int(
                    environment["TAB_COMPLETION_MAXIMUM_WORDS"] ?? ""
                ) ?? 8
            )
        }

        if
            let configuration = localConfiguration(),
            let profile = LocalModelProfiles.profile(
                id: configuration.profileID
            ),
            let url = URL(string: configuration.baseURL)
        {
            return OpenAICompatibleCompletionProvider(
                endpoint: url,
                apiKey: nil,
                model: profile.repository,
                apiStyle: profile.apiStyle,
                maximumWords: configuration.maximumWords
            )
        }

        return HeuristicCompletionProvider()
    }

    private static func localConfiguration()
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
            .appending(path: "Tab Completions Everywhere")
            .appending(path: "local-model.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(
            LocalCompletionConfiguration.self,
            from: data
        )
    }
}
