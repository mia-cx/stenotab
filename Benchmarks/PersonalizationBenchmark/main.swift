import CompletionCore
import Foundation
import NaturalLanguage

private struct TimingSummary {
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let operationsPerSecond: Double
    let checksum: Int
}

@inline(never)
private func consume(_ value: Int, into checksum: inout Int) {
    checksum = checksum &* 31 &+ value
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func measure(
    iterations: Int,
    operation: () -> Int
) -> TimingSummary {
    let clock = ContinuousClock()
    var samples: [Double] = []
    var checksum = 0
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = clock.now
        consume(operation(), into: &checksum)
        samples.append(milliseconds(clock.now - start))
    }
    samples.sort()
    let p50 = samples[min(samples.count - 1, samples.count / 2)]
    let p95Index = min(
        samples.count - 1,
        Int(Double(samples.count - 1) * 0.95)
    )
    let totalMilliseconds = samples.reduce(0, +)
    return TimingSummary(
        p50Milliseconds: p50,
        p95Milliseconds: samples[p95Index],
        operationsPerSecond:
            Double(iterations) / (totalMilliseconds / 1_000),
        checksum: checksum
    )
}

private func printResult(
    name: String,
    corpus: String,
    summary: TimingSummary,
    acceptanceP95: Double
) {
    let status =
        summary.p95Milliseconds <= acceptanceP95 ? "PASS" : "REVIEW"
    print(
        [
            name,
            corpus,
            String(format: "%.3f", summary.p50Milliseconds),
            String(format: "%.3f", summary.p95Milliseconds),
            String(format: "%.0f", summary.operationsPerSecond),
            String(summary.checksum),
            status
        ].joined(separator: "\t")
    )
}

private let context = PersonalizationContext(
    applicationBundleIdentifier: "com.example.Chat",
    inputKind: "message",
    detectedLanguage: "en",
    editorIdentifier: "benchmark"
)
private let now = Date(timeIntervalSince1970: 2_000_000)

private func makeLanguageModel() -> PersonalLanguageModel {
    var model = PersonalLanguageModel()
    for index in 0..<2_000 {
        model.learn(
            insertedText: "topic\(index) phrase\(index)",
            precedingText: "discuss ",
            signal: .directlyTyped,
            context: context,
            at: now.addingTimeInterval(Double(index))
        )
    }
    for index in 0..<20 {
        model.learn(
            insertedText: "pull request for this",
            precedingText: "can you open a ",
            signal: .acceptedSuggestion,
            context: context,
            at: now.addingTimeInterval(Double(index))
        )
    }
    return model
}

private func makeExamples(count: Int) -> [PersonalizationExample] {
    (0..<count).map { index in
        PersonalizationExample(
            id: UUID(),
            inputText:
                "discussion \(index) about accessibility and signatures",
            insertion: " with follow up \(index)",
            context: index.isMultiple(of: 3)
                ? context
                : PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Writer",
                    inputKind: "document",
                    detectedLanguage: "en",
                    editorIdentifier: "benchmark-\(index)"
                ),
            capturedAt: now.addingTimeInterval(Double(-index * 60)),
            source: index.isMultiple(of: 2)
                ? .acceptedSuggestion
                : .directlyTyped
        )
    }
}

private func makeVectors(
    examples: [PersonalizationExample],
    dimensions: Int
) -> [UUID: [Double]] {
    Dictionary(uniqueKeysWithValues: examples.enumerated().map {
        index, example in
        let vector = (0..<dimensions).map { dimension in
            let value = (index &* 31 &+ dimension &* 17) % 101
            return Double(value) / 100
        }
        return (example.id, vector)
    })
}

let model = makeLanguageModel()
let examples = makeExamples(count: 10_000)
let semanticExamples = Array(examples.prefix(2_000))
let vectors = makeVectors(examples: semanticExamples, dimensions: 512)
let queryVector = (0..<512).map { dimension in
    Double((dimension &* 17) % 101) / 100
}
let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
let embeddingQuery =
    "can you open a pull request for the accessibility signing fix"

for _ in 0..<20 {
    _ = model.completion(
        for: "can you open a pull req",
        context: context,
        at: now
    )
    _ = sentenceEmbedding?.vector(for: embeddingQuery)
}

print(
    "benchmark\tcorpus\tp50_ms\tp95_ms\tops_per_second"
        + "\tchecksum\tstatus"
)
printResult(
    name: "local_completion",
    corpus: "2,020 learned phrases",
    summary: measure(iterations: 2_000) {
        model.completion(
            for: "can you open a pull req",
            context: context,
            at: now
        )?.insertion.utf16.count ?? 0
    },
    acceptanceP95: 1
)
printResult(
    name: "query_embedding",
    corpus: "Apple NL 11-word query",
    summary: measure(iterations: 100) {
        sentenceEmbedding?.vector(for: embeddingQuery)?.count ?? 0
    },
    acceptanceP95: 20
)
printResult(
    name: "frecent_retrieval",
    corpus: "10,000 examples",
    summary: measure(iterations: 100) {
        FrecentExampleRetriever.retrieve(
            from: examples,
            context: context,
            at: now,
            limit: 5
        ).count
    },
    acceptanceP95: 20
)
printResult(
    name: "semantic_retrieval",
    corpus: "2,000 x 512-d vectors",
    summary: measure(iterations: 40) {
        SemanticExampleRetriever.retrieve(
            from: semanticExamples,
            vectors: vectors,
            queryVector: queryVector,
            context: context,
            at: now,
            limit: 5
        ).count
    },
    acceptanceP95: 50
)
