import CompletionCore
import Foundation
@testable import StenoTabPersistence
import XCTest

final class PersonalizationDatabaseTests: XCTestCase {
    private struct LegacyPersonalizationCorpusExport: Codable {
        let formatVersion: Int
        let exportedAt: Date
        let acceptedSuggestions: [AcceptedSuggestionCapture]
        let completionFeedback: [CompletionFeedbackCapture]
        let writingEpisodes: [WritingEpisodeCapture]
    }

    func testKeychainProviderReturnsStable64ByteKey() throws {
        let provider = KeychainPersonalizationKeyProvider(
            service: "cx.mia.stenotab.tests.\(UUID().uuidString)",
            account: "corpus-key"
        )
        defer { try? provider.deleteKeyForTesting() }

        let first = try provider.keyData()
        let second = try provider.keyData()

        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(second, first)
        XCTAssertNotEqual(first, Data(repeating: 0, count: 64))
    }

    func testAcceptedCaptureRoundTripsEncryptedAndCanBeDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appending(path: "personalization.sqlite")
        let database = try PersonalizationDatabase(
            databaseURL: databaseURL,
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: UUID(uuidString: "86AE8A8C-9705-4D35-AEAB-A97603580366")!,
                fieldText: "private complete field text",
                selection: UTF16Selection(location: 27, length: 0),
                insertion: " with literal space",
                acceptanceScope: .nextWord,
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Editor",
                    website: "example.com",
                    inputKind: "comment",
                    detectedLanguage: "en",
                    editorIdentifier: "editor-1"
                ),
                capturedAt: Date(timeIntervalSince1970: 123)
            )
        )

        try await database.record(capture)

        let storedCaptures = try await database.acceptedSuggestions()
        let storedEventCount = try await database.eventCount()
        XCTAssertEqual(storedCaptures, [capture])
        XCTAssertEqual(storedEventCount, 1)

        let bytes = try Data(contentsOf: databaseURL)
        XCTAssertNil(
            bytes.range(of: Data("private complete field text".utf8))
        )
        XCTAssertNil(
            bytes.range(of: Data(" with literal space".utf8))
        )
        XCTAssertNil(bytes.range(of: Data("example.com".utf8)))

        try await database.deleteAll()

        let deletedEventCount = try await database.eventCount()
        let deletedCaptures = try await database.acceptedSuggestions()
        XCTAssertEqual(deletedEventCount, 0)
        XCTAssertEqual(deletedCaptures, [])
    }

    func testCompletionEpisodeRoundTripsEncryptedAndAppearsInExport()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let date = Date(timeIntervalSince1970: 321)
        let invocation = CompletionInvocationCapture(
            id: UUID(
                uuidString: "2AE7CE10-339F-4B88-90CE-C14C55072291"
            )!,
            field: CapturedFieldState(
                text: "private input",
                selection: UTF16Selection(location: 13, length: 0)
            ),
            prompt: CapturedCompletionPrompt(
                transport: .textCompletion,
                textPrompt:
                    "SECRET OCR CONTEXT\n\nMy writing:\n§private input"
            ),
            generation: CompletionGenerationMetadata(
                providerKind: "local",
                modelIdentifier: "gemma-4-e2b",
                maximumTokens: 16,
                temperature: 0,
                stopSequences: []
            ),
            context: PersonalizationContext(
                applicationBundleIdentifier: "com.example.Editor",
                inputKind: "message",
                editorIdentifier: "editor"
            ),
            startedAt: date
        )
        let episode = CompletionEpisodeCapture(
            id: invocation.id,
            invocation: invocation,
            suggestionRevisions: [
                CompletionSuggestionRevision(
                    text: " suggestion",
                    isFinal: true,
                    observedAt: date.addingTimeInterval(0.1)
                )
            ],
            acceptances: [],
            typedThroughText: "",
            resolution: .rejected,
            finalField: CapturedFieldState(
                text: "private input outcome",
                selection: UTF16Selection(location: 21, length: 0)
            ),
            actualInsertedText: " outcome",
            endedAt: date.addingTimeInterval(0.2)
        )

        try await fixture.database.record(episode)

        let storedEpisodes =
            try await fixture.database.completionEpisodes()
        XCTAssertEqual(
            storedEpisodes,
            [episode]
        )
        let export = try await fixture.database.exportCorpus(at: date)
        XCTAssertEqual(export.completionEpisodes, [episode])
        let raw = try Data(
            contentsOf: fixture.directory.appending(
                path: "personalization.sqlite"
            )
        )
        XCTAssertNil(raw.range(of: Data("SECRET OCR CONTEXT".utf8)))
        XCTAssertNil(raw.range(of: Data("private input outcome".utf8)))
        XCTAssertNil(raw.range(of: Data("private input".utf8)))
    }

    func testUnsupportedCompletionEpisodeDoesNotHideSupportedRows()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supported = makeCompletionEpisode(
            id: UUID(),
            input: "supported input",
            suggestion: " suggestion",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 400)
        )
        try await fixture.database.record(supported)
        try await fixture.database.recordUnsupportedCompletionEpisodeForTesting(
            id: UUID(),
            storageVersion: 999,
            capturedAt: Date(timeIntervalSince1970: 401)
        )

        let episodes = try await fixture.database.completionEpisodes()
        XCTAssertEqual(episodes, [supported])
    }

    func testTextDeltasPreserveDifferentlyNormalizedUTF8Exactly() throws {
        let composed = "Café déjà vu"
        let decomposed = "Cafe\u{301} de\u{301}ja\u{300} vu"
        let delta = StoredTextDelta(from: composed, to: decomposed)

        XCTAssertEqual(delta.applying(to: composed), decomposed)
        XCTAssertEqual(
            Data(try XCTUnwrap(delta.applying(to: composed)).utf8),
            Data(decomposed.utf8)
        )
    }

    func testPromptSuffixReuseRequiresExactUTF8Bytes() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let decomposedInput = "Cafe\u{301}"
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: decomposedInput,
            suggestion: " works",
            outcome: " works",
            date: Date(timeIntervalSince1970: 402),
            promptInputOverride: "Café"
        )

        try await fixture.database.record(episode)

        let episodes = try await fixture.database.completionEpisodes()
        XCTAssertEqual(episodes, [episode])
    }

    func testForeignKeyEnforcementIsEnabled() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let isEnabled =
            try await fixture.database.foreignKeyEnforcementEnabled()
        XCTAssertTrue(isEnabled)
    }

    func testCorpusExportDecodesVersionOneWithoutCompletionEpisodes()
        throws
    {
        let legacy = LegacyPersonalizationCorpusExport(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 654),
            acceptedSuggestions: [],
            completionFeedback: [],
            writingEpisodes: []
        )

        let encoded = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(
            PersonalizationCorpusExport.self,
            from: encoded
        )

        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.completionEpisodes, [])
    }

    func testCompletionEpisodeTextIsDeduplicatedAndGarbageCollected()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let sharedInput = String(
            repeating:
                "This is a long existing input whose unchanged history "
                + "should not be encrypted again for every suggestion. "
                + "Café, naïef, 日本語, 👨‍👩‍👧‍👦. ",
            count: 24
        )
        let first = makeCompletionEpisode(
            id: UUID(),
            input: sharedInput,
            suggestion: "first suggestion",
            outcome: " first outcome",
            date: Date(timeIntervalSince1970: 700)
        )
        let second = makeCompletionEpisode(
            id: UUID(),
            input: sharedInput + " first outcome",
            suggestion: "second suggestion",
            outcome: " second outcome",
            date: Date(timeIntervalSince1970: 701)
        )

        try await fixture.database.record(first)
        let afterFirst =
            try await fixture.database.completionEpisodeStorageStatistics()
        try await fixture.database.record(second)
        let afterSecond =
            try await fixture.database.completionEpisodeStorageStatistics()
        let overallStorage =
            try await fixture.database.storageStatistics()

        let storedEpisodes =
            try await fixture.database.completionEpisodes()
        XCTAssertEqual(storedEpisodes, [first, second])
        XCTAssertGreaterThan(
            afterSecond.textChunkReferenceCount,
            afterSecond.uniqueTextChunkCount
        )
        XCTAssertLessThan(
            afterSecond.encryptedTextChunkBytes,
            afterFirst.encryptedTextChunkBytes * 2
        )
        XCTAssertGreaterThan(
            overallStorage.encryptedPayloadBytes,
            afterSecond.encryptedTextChunkBytes
        )

        try await fixture.database.deleteEvent(id: first.id)
        let episodesAfterDeletingFirst =
            try await fixture.database.completionEpisodes()
        XCTAssertEqual(episodesAfterDeletingFirst, [second])
        let storageAfterDeletingFirst =
            try await fixture.database.completionEpisodeStorageStatistics()
        XCTAssertGreaterThan(
            storageAfterDeletingFirst.uniqueTextChunkCount,
            0
        )

        let expired = try await fixture.database.enforceRetention(
            PersonalizationRetentionPolicy(
                maximumAge: 1,
                maximumEncryptedBytes: nil
            ),
            now: Date(timeIntervalSince1970: 800)
        )
        XCTAssertEqual(expired, 1)
        let afterDeletingBoth =
            try await fixture.database.completionEpisodeStorageStatistics()
        XCTAssertEqual(afterDeletingBoth.uniqueTextChunkCount, 0)
        XCTAssertEqual(afterDeletingBoth.textChunkReferenceCount, 0)
        XCTAssertEqual(afterDeletingBoth.encryptedTextChunkBytes, 0)
    }

    func testWritingEpisodesCanBeInspectedAndDeletedByRecordOrScope()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = makeEpisode(
            id: UUID(
                uuidString: "FDDDB2B2-E86B-42BF-9B7F-60E62BCE9A9C"
            )!,
            text: "a complete multiline field\nwith private text",
            app: "com.example.Chat",
            editor: "chat"
        )
        let second = makeEpisode(
            id: UUID(
                uuidString: "02F01EA7-9F25-4D2A-9D70-B5A8E4A43BE7"
            )!,
            text: "a document",
            app: "com.example.Writer",
            editor: "writer"
        )

        try await fixture.database.record(first)
        try await fixture.database.record(second)
        let initiallyStored = try await fixture.database.writingEpisodes()
        XCTAssertEqual(
            initiallyStored,
            [first, second]
        )

        try await fixture.database.deleteEvent(id: second.id)
        let afterRecordDeletion =
            try await fixture.database.writingEpisodes()
        XCTAssertEqual(
            afterRecordDeletion,
            [first]
        )

        try await fixture.database.record(second)
        let deleted = try await fixture.database.deleteEvents(
            scopeKind: "application",
            value: "com.example.Chat"
        )
        XCTAssertEqual(deleted, 1)
        let afterScopeDeletion =
            try await fixture.database.writingEpisodes()
        XCTAssertEqual(
            afterScopeDeletion,
            [second]
        )
    }

    func testRetentionRemovesWholeOldestRowsAndReportsEncryptedStorage()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let old = makeEpisode(
            id: UUID(),
            text: "old",
            app: "com.example.Editor",
            editor: "old",
            date: Date(timeIntervalSince1970: 100)
        )
        let recent = makeEpisode(
            id: UUID(),
            text: "recent",
            app: "com.example.Editor",
            editor: "recent",
            date: Date(timeIntervalSince1970: 1_000)
        )
        try await fixture.database.record(old)
        try await fixture.database.record(recent)

        let before = try await fixture.database.storageStatistics()
        XCTAssertEqual(before.eventCount, 2)
        XCTAssertGreaterThan(before.encryptedPayloadBytes, 0)

        let removed = try await fixture.database.enforceRetention(
            PersonalizationRetentionPolicy(
                maximumAge: 500,
                maximumEncryptedBytes: nil
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(removed, 1)
        let afterAgeRetention =
            try await fixture.database.writingEpisodes()
        XCTAssertEqual(afterAgeRetention, [recent])

        let recentStatistics =
            try await fixture.database.storageStatistics()
        let byteRemoved = try await fixture.database.enforceRetention(
            PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes:
                    recentStatistics.encryptedPayloadBytes - 1
            ),
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(byteRemoved, 1)
        let finalCount = try await fixture.database.eventCount()
        XCTAssertEqual(finalCount, 0)
    }

    func testCompletionFeedbackRoundTripsEncrypted() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let feedback = try XCTUnwrap(
            PersonalizationCapture.typedSuggestionMatch(
                id: UUID(),
                fieldText: "private prefix",
                selection: UTF16Selection(location: 14, length: 0),
                suggestionText: " and private suffix",
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Chat",
                    editorIdentifier: "editor"
                ),
                capturedAt: Date(timeIntervalSince1970: 900)
            )
        )

        try await fixture.database.record(feedback)
        let stored = try await fixture.database.completionFeedback()

        XCTAssertEqual(stored, [feedback])
        let raw = try Data(
            contentsOf: fixture.directory.appending(
                path: "personalization.sqlite"
            )
        )
        XCTAssertNil(raw.range(of: Data("private suffix".utf8)))
    }

    func testPersonalLanguageModelSnapshotRoundTripsEncrypted() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var model = PersonalLanguageModel()
        let learnedAt = Date(timeIntervalSince1970: 1_234)
        for _ in 0..<3 {
            model.learn(
                insertedText: "ExtremelyPrivateVocabulary",
                precedingText: "use ",
                signal: .directlyTyped,
                context: PersonalizationContext(editorIdentifier: "editor"),
                at: learnedAt
            )
        }

        try await fixture.database.saveLanguageModel(model)
        let stored = try await fixture.database.loadLanguageModel()

        XCTAssertEqual(stored, model)
        let raw = try Data(
            contentsOf: fixture.directory.appending(
                path: "personalization.sqlite"
            )
        )
        XCTAssertNil(
            raw.range(
                of: Data("ExtremelyPrivateVocabulary".utf8)
            )
        )
    }

    func testEmbeddingRoundTripsEncryptedAndFollowsEventDeletion()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let eventID = UUID()
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: eventID,
                fieldText: "semantic private source",
                selection: UTF16Selection(location: 23, length: 0),
                insertion: " material",
                acceptanceScope: .nextWord,
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Editor",
                    editorIdentifier: "editor"
                )
            )
        )
        try await fixture.database.record(capture)
        try await fixture.database.saveEmbedding(
            eventID: eventID,
            modelIdentifier: "test-embedding-v1",
            vector: [0.125, -0.75, 0.5],
            at: Date(timeIntervalSince1970: 2_000)
        )

        let storedEmbeddings = try await fixture.database.embeddings()
        XCTAssertEqual(
            storedEmbeddings,
            [
                StoredPersonalizationEmbedding(
                    eventID: eventID,
                    modelIdentifier: "test-embedding-v1",
                    vector: [0.125, -0.75, 0.5],
                    createdAt: Date(timeIntervalSince1970: 2_000)
                )
            ]
        )
        let raw = try Data(
            contentsOf: fixture.directory.appending(
                path: "personalization.sqlite"
            )
        )
        XCTAssertNil(
            raw.range(of: Data("[0.125,-0.75,0.5]".utf8))
        )

        try await fixture.database.deleteEvent(id: eventID)
        let deletedEmbeddings = try await fixture.database.embeddings()
        XCTAssertEqual(deletedEmbeddings, [])
    }

    func testVoiceAssessmentProjectionRoundTripsEncrypted() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let assessment = VoiceAssessment(
            summary: "I use PrivateCamelCase and short replies.",
            sampleCount: 25,
            sourceEventCount: 30,
            generatedAt: Date(timeIntervalSince1970: 3_000)
        )

        try await fixture.database.saveVoiceAssessment(
            assessment,
            at: assessment.generatedAt
        )

        let stored = try await fixture.database.loadVoiceAssessment()
        XCTAssertEqual(stored, assessment)
        let raw = try Data(
            contentsOf: fixture.directory.appending(
                path: "personalization.sqlite"
            )
        )
        XCTAssertNil(
            raw.range(of: Data("PrivateCamelCase".utf8))
        )
    }

    func testStorageCapCountsEncryptedEmbeddingsAndProjections()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let eventID = UUID()
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: eventID,
                fieldText: "storage accounting input",
                selection: UTF16Selection(location: 24, length: 0),
                insertion: " continuation",
                acceptanceScope: .nextWord,
                context: PersonalizationContext(
                    editorIdentifier: "editor"
                )
            )
        )
        try await fixture.database.record(capture)
        let beforeDerivedData =
            try await fixture.database.storageStatistics()

        try await fixture.database.saveEmbedding(
            eventID: eventID,
            modelIdentifier: "test-512",
            vector: Array(repeating: 0.25, count: 512)
        )
        try await fixture.database.saveVoiceAssessment(
            VoiceAssessment(
                summary: "I write concise messages.",
                sampleCount: 10,
                sourceEventCount: 10,
                generatedAt: Date()
            )
        )
        let afterDerivedData =
            try await fixture.database.storageStatistics()

        XCTAssertGreaterThan(
            afterDerivedData.encryptedPayloadBytes,
            beforeDerivedData.encryptedPayloadBytes
        )
        let removed = try await fixture.database.enforceRetention(
            PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes:
                    beforeDerivedData.encryptedPayloadBytes
            )
        )
        XCTAssertEqual(removed, 1)
        let remainingEmbeddings =
            try await fixture.database.embeddings()
        XCTAssertEqual(remainingEmbeddings, [])
    }

    private func makeDatabase() throws -> (
        database: PersonalizationDatabase,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            try PersonalizationDatabase(
                databaseURL: directory.appending(
                    path: "personalization.sqlite"
                ),
                keyProvider: StaticPersonalizationKeyProvider(
                    keyData: Data(repeating: 0x42, count: 64)
                )
            ),
            directory
        )
    }

    private func makeEpisode(
        id: UUID,
        text: String,
        app: String,
        editor: String,
        date: Date = Date(timeIntervalSince1970: 500)
    ) -> WritingEpisodeCapture {
        let initial = CapturedFieldState(
            text: text,
            selection: UTF16Selection(
                location: text.utf16.count,
                length: 0
            )
        )
        let finalText = text + "!"
        return WritingEpisodeCapture(
            id: id,
            initialField: initial,
            finalField: CapturedFieldState(
                text: finalText,
                selection: UTF16Selection(
                    location: finalText.utf16.count,
                    length: 0
                )
            ),
            edits: [
                WritingEditCapture(
                    insertedText: "!",
                    provenance: .directlyTyped,
                    selectionBefore: initial.selection,
                    selectionAfter: UTF16Selection(
                        location: finalText.utf16.count,
                        length: 0
                    ),
                    startedAt: date,
                    endedAt: date
                )
            ],
            context: PersonalizationContext(
                applicationBundleIdentifier: app,
                inputKind: "document",
                editorIdentifier: editor
            ),
            startedAt: date,
            endedAt: date,
            boundary: .idle
        )
    }

    private func makeCompletionEpisode(
        id: UUID,
        input: String,
        suggestion: String,
        outcome: String,
        date: Date,
        promptInputOverride: String? = nil
    ) -> CompletionEpisodeCapture {
        let finalText = input + outcome
        let invocation = CompletionInvocationCapture(
            id: id,
            field: CapturedFieldState(
                text: input,
                selection: UTF16Selection(
                    location: input.utf16.count,
                    length: 0
                )
            ),
            prompt: CapturedCompletionPrompt(
                transport: .textCompletion,
                textPrompt:
                    "Stable OCR and clipboard context.\n\n"
                    + "My writing:\n§"
                    + (promptInputOverride ?? input)
            ),
            generation: CompletionGenerationMetadata(
                providerKind: "local-openai-compatible",
                modelIdentifier: "gemma-4-e2b",
                maximumTokens: 16,
                temperature: 0,
                stopSequences: []
            ),
            context: PersonalizationContext(
                applicationBundleIdentifier: "com.example.Editor",
                inputKind: "document",
                editorIdentifier: "editor"
            ),
            startedAt: date
        )
        return CompletionEpisodeCapture(
            id: id,
            invocation: invocation,
            suggestionRevisions: [
                CompletionSuggestionRevision(
                    text: String(suggestion.prefix(5)),
                    isFinal: false,
                    observedAt: date
                ),
                CompletionSuggestionRevision(
                    text: suggestion,
                    isFinal: true,
                    observedAt: date.addingTimeInterval(0.05)
                ),
            ],
            acceptances: [],
            typedThroughText: "",
            resolution: .rejected,
            finalField: CapturedFieldState(
                text: finalText,
                selection: UTF16Selection(
                    location: finalText.utf16.count,
                    length: 0
                )
            ),
            actualInsertedText: outcome,
            endedAt: date.addingTimeInterval(0.1)
        )
    }
}
