import Foundation

public enum PersonalizationExampleSource:
    String, Codable, Sendable, Equatable
{
    case acceptedSuggestion = "accepted_suggestion"
    case directlyTyped = "directly_typed"
}

public struct PersonalizationExample:
    Codable, Sendable, Equatable, Identifiable
{
    public static let promptRecordSeparator = "\u{1E}"

    public let id: UUID
    public let inputText: String
    public let insertion: String
    public let context: PersonalizationContext
    public let capturedAt: Date
    public let source: PersonalizationExampleSource

    public init(
        id: UUID,
        inputText: String,
        insertion: String,
        context: PersonalizationContext,
        capturedAt: Date,
        source: PersonalizationExampleSource
    ) {
        self.id = id
        self.inputText = inputText
        self.insertion = insertion
        self.context = context
        self.capturedAt = capturedAt
        self.source = source
    }

    public init(_ capture: AcceptedSuggestionCapture) {
        self.init(
            id: capture.id,
            inputText: capture.field.text,
            insertion: capture.insertion,
            context: capture.context,
            capturedAt: capture.capturedAt,
            source: .acceptedSuggestion
        )
    }

    public var promptText: String {
        """
        Text:
        §\(inputText)
        Insertion:
        §\(insertion)
        """
    }

    public static func promptValue(
        from examples: [PersonalizationExample]
    ) -> String? {
        guard !examples.isEmpty else { return nil }
        return examples
            .map(\.promptText)
            .joined(separator: promptRecordSeparator)
    }

    public static func directlyTyped(
        from episode: WritingEpisodeCapture
    ) -> [PersonalizationExample] {
        episode.edits.compactMap { edit in
            guard
                edit.provenance == .directlyTyped,
                !edit.insertedText.isEmpty,
                let fieldBefore = edit.fieldBefore
            else {
                return nil
            }
            return PersonalizationExample(
                id: episode.id,
                inputText: fieldBefore.text,
                insertion: edit.insertedText,
                context: episode.context,
                capturedAt: edit.endedAt,
                source: .directlyTyped
            )
        }
    }
}

public struct PersonalizationPromptContext: Sendable, Equatable {
    public let frecentExamples: String?
    public let relevantExamples: String?
    public let voiceAssessment: String?
    public let frecentSourceEventIDs: [UUID]
    public let frecentSourceContexts: [PersonalizationContext]
    public let relevantSourceEventIDs: [UUID]
    public let relevantSourceContexts: [PersonalizationContext]
    public let voiceSourceEventIDs: [UUID]
    public let voiceSourceContexts: [PersonalizationContext]

    public init(
        frecentExamples: String? = nil,
        relevantExamples: String? = nil,
        voiceAssessment: String? = nil,
        frecentSourceEventIDs: [UUID] = [],
        frecentSourceContexts: [PersonalizationContext] = [],
        relevantSourceEventIDs: [UUID] = [],
        relevantSourceContexts: [PersonalizationContext] = [],
        voiceSourceEventIDs: [UUID] = [],
        voiceSourceContexts: [PersonalizationContext] = []
    ) {
        self.frecentExamples = frecentExamples
        self.relevantExamples = relevantExamples
        self.voiceAssessment = voiceAssessment
        self.frecentSourceEventIDs = frecentSourceEventIDs
        self.frecentSourceContexts = frecentSourceContexts
        self.relevantSourceEventIDs = relevantSourceEventIDs
        self.relevantSourceContexts = relevantSourceContexts
        self.voiceSourceEventIDs = voiceSourceEventIDs
        self.voiceSourceContexts = voiceSourceContexts
    }

    public static let empty = PersonalizationPromptContext()

    public func sourceEventIDs(
        includeFrecent: Bool,
        includeRelevant: Bool,
        includeVoiceAssessment: Bool = false
    ) -> [UUID] {
        let candidates =
            (includeFrecent ? frecentSourceEventIDs : [])
            + (includeRelevant ? relevantSourceEventIDs : [])
            + (includeVoiceAssessment ? voiceSourceEventIDs : [])
        return candidates.reduce(into: []) { result, id in
            if !result.contains(id) {
                result.append(id)
            }
        }
    }

    public func sourceContexts(
        includeFrecent: Bool,
        includeRelevant: Bool,
        includeVoiceAssessment: Bool = false
    ) -> [PersonalizationContext] {
        let candidates =
            (includeFrecent ? frecentSourceContexts : [])
            + (includeRelevant ? relevantSourceContexts : [])
            + (includeVoiceAssessment ? voiceSourceContexts : [])
        return candidates.reduce(into: []) { result, context in
            if !result.contains(context) {
                result.append(context)
            }
        }
    }
}

public enum FrecentExampleRetriever {
    private struct ExampleGroup {
        var representative: PersonalizationExample
        var count: Int
    }

    private struct ScoredExample {
        let example: PersonalizationExample
        let score: Double
    }

    public static func retrieve(
        from examples: [PersonalizationExample],
        context: PersonalizationContext,
        at date: Date = Date(),
        limit: Int = 5
    ) -> [PersonalizationExample] {
        guard limit > 0 else { return [] }
        var grouped: [String: ExampleGroup] = [:]
        grouped.reserveCapacity(examples.count)
        for example in examples {
            let key = signature(for: example)
            if var existing = grouped[key] {
                existing.count += 1
                if example.capturedAt > existing.representative.capturedAt {
                    existing.representative = example
                }
                grouped[key] = existing
            } else {
                grouped[key] = ExampleGroup(
                    representative: example,
                    count: 1
                )
            }
        }
        var best: [ScoredExample] = []
        best.reserveCapacity(limit + 1)
        for group in grouped.values {
            let representative = group.representative
            let age = max(
                0,
                date.timeIntervalSince(representative.capturedAt)
            )
            let recency = exp(-age / (14 * 24 * 60 * 60))
            let frequency = log1p(Double(group.count))
            let scope = scopeMatch(
                representative.context,
                context
            )
            let accepted =
                representative.source == .acceptedSuggestion ? 0.25 : 0
            best.append(
                ScoredExample(
                    example: representative,
                    score: recency + frequency + scope + accepted
                )
            )
            best.sort(by: precedes)
            if best.count > limit {
                best.removeLast()
            }
        }
        return best.map(\.example)
    }

    private static func signature(
        for example: PersonalizationExample
    ) -> String {
        example.inputText.lowercased()
            + "\u{1F}"
            + example.insertion.lowercased()
    }

    private static func precedes(
        _ lhs: ScoredExample,
        _ rhs: ScoredExample
    ) -> Bool {
        if lhs.score == rhs.score {
            return lhs.example.capturedAt > rhs.example.capturedAt
        }
        return lhs.score > rhs.score
    }
}

public enum SemanticExampleRetriever {
    private struct ScoredExample {
        let example: PersonalizationExample
        let score: Double
    }

    public static func retrieve(
        from examples: [PersonalizationExample],
        vectors: [UUID: [Double]],
        queryVector: [Double],
        context: PersonalizationContext,
        at date: Date = Date(),
        limit: Int = 5,
        minimumSimilarity: Double = 0.2
    ) -> [PersonalizationExample] {
        guard limit > 0, !queryVector.isEmpty else { return [] }
        let scored: [ScoredExample] = examples.compactMap {
            example -> ScoredExample? in
            guard
                let vector = vectors[example.id],
                let similarity = cosineSimilarity(
                    vector,
                    queryVector
                ),
                similarity >= minimumSimilarity
            else {
                return nil
            }
            let age = max(0, date.timeIntervalSince(example.capturedAt))
            let recency = exp(-age / (30 * 24 * 60 * 60)) * 0.1
            let score =
                similarity
                + scopeMatch(example.context, context) * 0.1
                + recency
            return ScoredExample(example: example, score: score)
        }
        return scored.sorted {
            if $0.score == $1.score {
                return $0.example.capturedAt > $1.example.capturedAt
            }
            return $0.score > $1.score
        }
        .prefix(limit)
        .map(\.example)
    }

    private static func cosineSimilarity(
        _ lhs: [Double],
        _ rhs: [Double]
    ) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsMagnitude += lhs[index] * lhs[index]
            rhsMagnitude += rhs[index] * rhs[index]
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }
}

private func scopeMatch(
    _ lhs: PersonalizationContext,
    _ rhs: PersonalizationContext
) -> Double {
    var score = 0.0
    if let value = lhs.applicationBundleIdentifier,
       value == rhs.applicationBundleIdentifier {
        score += 1
    }
    if let value = lhs.website, value == rhs.website {
        score += 1
    }
    if let value = lhs.inputKind, value == rhs.inputKind {
        score += 0.5
    }
    if let value = lhs.detectedLanguage,
       value == rhs.detectedLanguage {
        score += 0.5
    }
    return score
}
