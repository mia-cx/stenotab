import XCTest
@testable import CompletionCore

final class PersonalizationExampleRetrievalTests: XCTestCase {
    func testPromptLineageIncludesOnlyEnabledHistoryComponents() {
        let frecentID = UUID()
        let relevantID = UUID()
        let voiceID = UUID()
        let frecentContext = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Frecent",
            editorIdentifier: "frecent"
        )
        let relevantContext = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Relevant",
            editorIdentifier: "relevant"
        )
        let voiceContext = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Voice",
            editorIdentifier: "voice"
        )
        let context = PersonalizationPromptContext(
            frecentExamples: "frecent",
            relevantExamples: "relevant",
            frecentSourceEventIDs: [frecentID],
            frecentSourceContexts: [frecentContext],
            relevantSourceEventIDs: [relevantID],
            relevantSourceContexts: [relevantContext],
            voiceSourceEventIDs: [voiceID],
            voiceSourceContexts: [voiceContext]
        )

        XCTAssertEqual(
            context.sourceEventIDs(
                includeFrecent: true,
                includeRelevant: false
            ),
            [frecentID]
        )
        XCTAssertEqual(
            context.sourceContexts(
                includeFrecent: false,
                includeRelevant: true
            ),
            [relevantContext]
        )
        XCTAssertEqual(
            context.sourceEventIDs(
                includeFrecent: false,
                includeRelevant: false,
                includeVoiceAssessment: true
            ),
            [voiceID]
        )
        XCTAssertEqual(
            context.sourceContexts(
                includeFrecent: false,
                includeRelevant: false
            ),
            []
        )
    }

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

    func testDirectlyTypedEditsHaveStableDistinctRetrievalIdentities() {
        let episodeID = UUID()
        let firstField = CapturedFieldState(
            text: "hello",
            selection: UTF16Selection(location: 5, length: 0)
        )
        let secondField = CapturedFieldState(
            text: "hello there",
            selection: UTF16Selection(location: 11, length: 0)
        )
        let episode = WritingEpisodeCapture(
            id: episodeID,
            initialField: firstField,
            finalField: CapturedFieldState(
                text: "hello there friend",
                selection: UTF16Selection(location: 18, length: 0)
            ),
            edits: [
                WritingEditCapture(
                    insertedText: " there",
                    provenance: .directlyTyped,
                    selectionBefore: firstField.selection,
                    selectionAfter: secondField.selection,
                    fieldBefore: firstField,
                    fieldAfter: secondField,
                    startedAt: Date(timeIntervalSince1970: 1),
                    endedAt: Date(timeIntervalSince1970: 2)
                ),
                WritingEditCapture(
                    insertedText: " friend",
                    provenance: .directlyTyped,
                    selectionBefore: secondField.selection,
                    selectionAfter:
                        UTF16Selection(location: 18, length: 0),
                    fieldBefore: secondField,
                    fieldAfter: CapturedFieldState(
                        text: "hello there friend",
                        selection:
                            UTF16Selection(location: 18, length: 0)
                    ),
                    startedAt: Date(timeIntervalSince1970: 3),
                    endedAt: Date(timeIntervalSince1970: 4)
                ),
            ],
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 4),
            boundary: .idle
        )

        let firstPass = PersonalizationExample.directlyTyped(from: episode)
        let secondPass = PersonalizationExample.directlyTyped(from: episode)

        XCTAssertEqual(firstPass.count, 2)
        XCTAssertNotEqual(firstPass[0].id, firstPass[1].id)
        XCTAssertEqual(firstPass.map(\.id), secondPass.map(\.id))
        XCTAssertEqual(
            firstPass.compactMap(\.sourceEventID),
            [episodeID, episodeID]
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
