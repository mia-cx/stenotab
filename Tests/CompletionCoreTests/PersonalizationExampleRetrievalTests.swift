import XCTest
@testable import CompletionCore

final class PersonalizationExampleRetrievalTests: XCTestCase {
    func testExampleUsesLiteralTextAndInsertionFormat() {
        let example = PersonalizationExample(
            id: UUID(),
            inputText: "can you open a pull req",
            insertion: "uest for this",
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date(timeIntervalSince1970: 10),
            source: .acceptedSuggestion
        )

        XCTAssertEqual(
            example.promptText,
            """
            Text:
            §can you open a pull req
            Insertion:
            §uest for this
            """
        )
    }

    func testPromptValueKeepsPairedExamplesAsDistinctRecords() {
        let context = PersonalizationContext(editorIdentifier: "editor")
        let examples = [
            PersonalizationExample(
                id: UUID(),
                inputText: "can you open a pull req",
                insertion: "uest",
                context: context,
                capturedAt: Date(),
                source: .acceptedSuggestion
            ),
            PersonalizationExample(
                id: UUID(),
                inputText: "that sounds",
                insertion: " good to me",
                context: context,
                capturedAt: Date(),
                source: .directlyTyped
            )
        ]

        XCTAssertEqual(
            PersonalizationExample.promptValue(from: examples),
            examples[0].promptText
                + PersonalizationExample.promptRecordSeparator
                + examples[1].promptText
        )
    }

    func testFrecentRetrievalDeduplicatesAndPrefersMatchingScope() {
        let now = Date(timeIntervalSince1970: 10_000)
        let chat = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Chat",
            editorIdentifier: "chat"
        )
        let work = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Work",
            editorIdentifier: "work"
        )
        let duplicateID = UUID()
        let examples = [
            PersonalizationExample(
                id: duplicateID,
                inputText: "open a pull req",
                insertion: "uest",
                context: chat,
                capturedAt: now.addingTimeInterval(-100),
                source: .acceptedSuggestion
            ),
            PersonalizationExample(
                id: UUID(),
                inputText: "open a pull req",
                insertion: "uest",
                context: chat,
                capturedAt: now.addingTimeInterval(-50),
                source: .acceptedSuggestion
            ),
            PersonalizationExample(
                id: UUID(),
                inputText: "formal greeting",
                insertion: " dear colleague",
                context: work,
                capturedAt: now.addingTimeInterval(-10),
                source: .directlyTyped
            )
        ]

        let retrieved = FrecentExampleRetriever.retrieve(
            from: examples,
            context: chat,
            at: now,
            limit: 2
        )

        XCTAssertEqual(retrieved.count, 2)
        XCTAssertEqual(retrieved[0].inputText, "open a pull req")
        XCTAssertEqual(
            retrieved.filter { $0.inputText == "open a pull req" }.count,
            1
        )
    }

    func testSemanticRetrievalUsesCosineSimilarityAndScope() {
        let now = Date(timeIntervalSince1970: 20_000)
        let chat = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Chat",
            editorIdentifier: "chat"
        )
        let relevant = PersonalizationExample(
            id: UUID(),
            inputText: "accessibility permission stopped working",
            insertion: " after the signature changed",
            context: chat,
            capturedAt: now,
            source: .acceptedSuggestion
        )
        let unrelated = PersonalizationExample(
            id: UUID(),
            inputText: "dinner recipe",
            insertion: " with more garlic",
            context: chat,
            capturedAt: now,
            source: .acceptedSuggestion
        )

        let retrieved = SemanticExampleRetriever.retrieve(
            from: [unrelated, relevant],
            vectors: [
                relevant.id: [1, 0, 0],
                unrelated.id: [0, 1, 0]
            ],
            queryVector: [0.95, 0.05, 0],
            context: chat,
            at: now,
            limit: 1
        )

        XCTAssertEqual(retrieved, [relevant])
    }
}
