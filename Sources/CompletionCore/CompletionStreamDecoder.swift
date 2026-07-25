import Foundation

public struct CompletionStreamEvent: Equatable, Sendable {
    public let delta: String
    public let isFinished: Bool

    public init(delta: String, isFinished: Bool) {
        self.delta = delta
        self.isFinished = isFinished
    }
}

public struct CompletionStreamDecoder: Sendable {
    public init() {}

    public mutating func consume(line: String) -> CompletionStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst("data:".count)
        if payload.first == " " {
            payload.removeFirst()
        }
        if payload == "[DONE]" {
            return CompletionStreamEvent(delta: "", isFinished: true)
        }
        guard
            let data = String(payload).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return nil
        }

        if
            let choices = root["choices"] as? [[String: Any]],
            let choice = choices.first
        {
            let delta = choice["text"] as? String
                ?? (choice["delta"] as? [String: Any])?["content"] as? String
                ?? ""
            let finishReason = choice["finish_reason"]
            let isFinished = finishReason != nil
                && !(finishReason is NSNull)
            guard !delta.isEmpty || isFinished else { return nil }
            return CompletionStreamEvent(
                delta: delta,
                isFinished: isFinished
            )
        }

        let delta = root["content"] as? String ?? ""
        let isFinished = root["stop"] as? Bool ?? false
        guard !delta.isEmpty || isFinished else { return nil }
        return CompletionStreamEvent(
            delta: delta,
            isFinished: isFinished
        )
    }
}
