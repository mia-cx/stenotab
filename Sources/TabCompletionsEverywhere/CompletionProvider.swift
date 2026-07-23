import Foundation

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

    func complete(_ request: CompletionRequest) async -> CompletionResponse {
        let path = endpoint.path.hasSuffix("/v1")
            ? "chat/completions"
            : "v1/chat/completions"
        var urlRequest = URLRequest(url: endpoint.appending(path: path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 2
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let prompt = """
        Continue the text at <CURSOR>. Return only the short text to insert.
        TEXT:
        \(request.prefix.suffix(1_500))<CURSOR>\(request.suffix.prefix(300))
        """
        let body = CompletionBody(
            model: model,
            messages: [
                .init(
                    role: "system",
                    content: "You autocomplete text. Reply only with a short suffix to insert at the cursor."
                ),
                .init(role: "user", content: prompt),
            ],
            maxTokens: 16,
            temperature: 0.2,
            stop: ["\n\n"]
        )
        urlRequest.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return CompletionResponse(requestID: request.id, text: nil)
            }
            let payload = try JSONDecoder().decode(CompletionPayload.self, from: data)
            let text = payload.choices.first?.message.content
            return CompletionResponse(
                requestID: request.id,
                text: text?.isEmpty == false ? text : nil
            )
        } catch {
            return CompletionResponse(requestID: request.id, text: nil)
        }
    }
}

private struct CompletionBody: Encodable {
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

private struct CompletionPayload: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

enum ProviderFactory {
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> any CompletionProvider {
        guard
            let base = environment["TAB_COMPLETION_BASE_URL"],
            let url = URL(string: base),
            let model = environment["TAB_COMPLETION_MODEL"]
        else {
            return HeuristicCompletionProvider()
        }

        return OpenAICompatibleCompletionProvider(
            endpoint: url,
            apiKey: environment["TAB_COMPLETION_API_KEY"],
            model: model
        )
    }
}
