import CompletionCore
import Foundation
@testable import StenoTabPersistence
import XCTest

final class PersonalizationDatabaseTests: XCTestCase {
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
}
