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
            acceptances: [
                CompletionAcceptanceCapture(
                    text: " sug",
                    scope: .nextWord,
                    acceptedAt: date.addingTimeInterval(0.15)
                )
            ],
            typedThroughText: "gestion",
            generationDidFail: true,
            resolution: .partiallyAccepted,
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
        let olderSupported = makeCompletionEpisode(
            id: UUID(),
            input: "older supported input",
            suggestion: " older suggestion",
            outcome: " older outcome",
            date: Date(timeIntervalSince1970: 400)
        )
        let newerSupported = makeCompletionEpisode(
            id: UUID(),
            input: "newer supported input",
            suggestion: " newer suggestion",
            outcome: " newer outcome",
            date: Date(timeIntervalSince1970: 401)
        )
        try await fixture.database.record(olderSupported)
        try await fixture.database.record(newerSupported)
        try await fixture.database.recordUnsupportedCompletionEpisodeForTesting(
            id: UUID(),
            storageVersion: 999,
            capturedAt: Date(timeIntervalSince1970: 402)
        )
        try await fixture.database.recordUnsupportedCompletionEpisodeForTesting(
            id: UUID(),
            storageVersion: 1_000,
            capturedAt: Date(timeIntervalSince1970: 403)
        )

        let episodes = try await fixture.database.completionEpisodes()
        XCTAssertEqual(episodes, [olderSupported, newerSupported])
        let latestSupported =
            try await fixture.database.completionEpisodes(limit: 1)
        XCTAssertEqual(latestSupported, [newerSupported])
    }

    func testLegacyCompletionEpisodeWithoutLineageIsRemovedOnUpgrade()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: "version two input",
            suggestion: " retained suggestion",
            outcome: " retained outcome",
            date: Date(timeIntervalSince1970: 405)
        )

        try await fixture.database
            .recordVersionTwoCompletionEpisodeForTesting(episode)

        let reopened = try PersonalizationDatabase(
            databaseURL: fixture.directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let hydrated = try await reopened.completionEpisodes()
        let eventCount = try await reopened.eventCount()
        XCTAssertEqual(hydrated, [])
        XCTAssertEqual(eventCount, 0)
    }

    func testLegacyMigrationRebuildsIndexesBeforeDeletingLegacyRows()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let legacy = makeCompletionEpisode(
            id: UUID(),
            input: "legacy private input",
            suggestion: " legacy",
            outcome: " legacy outcome",
            date: Date(timeIntervalSince1970: 405)
        )
        let current = makeCompletionEpisode(
            id: UUID(),
            input: "current private input",
            suggestion: " current",
            outcome: " current outcome",
            date: Date(timeIntervalSince1970: 406)
        )
        try await fixture.database
            .recordVersionTwoCompletionEpisodeForTesting(legacy)
        try await fixture.database.record(current)
        try await fixture.database
            .removeEventTextChunkIndexForTesting(eventID: current.id)
        try await fixture.database
            .insertCompletionEpisodeSourceIndexForTesting(
                completionEventID: current.id,
                sourceEventID: legacy.id
            )

        let reopened = try PersonalizationDatabase(
            databaseURL: fixture.directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )

        let episodes = try await reopened.completionEpisodes()
        let eventCount = try await reopened.eventCount()
        XCTAssertEqual(episodes, [current])
        XCTAssertEqual(eventCount, 1)
    }

    func testLegacyMigrationAuthenticatesRowsBeforeDeleting() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let legacy = makeCompletionEpisode(
            id: UUID(),
            input: "legacy input",
            suggestion: " legacy",
            outcome: " legacy outcome",
            date: Date(timeIntervalSince1970: 405)
        )
        let current = makeCompletionEpisode(
            id: UUID(),
            input: "current input",
            suggestion: " current",
            outcome: " current outcome",
            date: Date(timeIntervalSince1970: 406)
        )
        try await fixture.database
            .recordVersionTwoCompletionEpisodeForTesting(legacy)
        try await fixture.database.record(current)
        let swapped = try await fixture.database
            .swapFirstTwoCompletionEventPayloadsForTesting()
        XCTAssertTrue(swapped)

        let reopened = try PersonalizationDatabase(
            databaseURL: fixture.directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let countBeforeDelete = try await reopened.eventCount()
        XCTAssertEqual(countBeforeDelete, 2)

        try await reopened.deleteAll()
        let countAfterDelete = try await reopened.eventCount()
        XCTAssertEqual(countAfterDelete, 0)
    }

    func testLegacyMigrationDoesNotDeleteRowWithCorruptedKind()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: UUID(),
                fieldText: "canonical private input",
                selection: UTF16Selection(location: 23, length: 0),
                insertion: " continuation",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(editorIdentifier: "editor")
            )
        )
        try await fixture.database.record(capture)
        try await fixture.database.replaceEventKindForTesting(
            eventID: capture.id,
            kind: "completion_episode"
        )

        let reopened = try PersonalizationDatabase(
            databaseURL: fixture.directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let countAfterMigration = try await reopened.eventCount()
        XCTAssertEqual(countAfterMigration, 1)

        try await reopened.deleteAll()
        let countAfterDelete = try await reopened.eventCount()
        XCTAssertEqual(countAfterDelete, 0)
    }

    func testCorruptEpisodeCanReopenAndDeleteAll() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.database.record(
            makeCompletionEpisode(
                id: UUID(),
                input: "corrupt private input",
                suggestion: " corrupt",
                outcome: " corrupt outcome",
                date: Date(timeIntervalSince1970: 406)
            )
        )
        let corrupted = try await fixture.database
            .corruptFirstCompletionEventPayloadForTesting()
        XCTAssertTrue(corrupted)

        let reopened = try PersonalizationDatabase(
            databaseURL: fixture.directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let countBeforeDelete = try await reopened.eventCount()
        XCTAssertEqual(countBeforeDelete, 1)

        try await reopened.deleteAll()
        let countAfterDelete = try await reopened.eventCount()
        XCTAssertEqual(countAfterDelete, 0)
    }

    func testTargetedDeleteFailsClosedForUnsupportedEpisodeVersion()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let supported = makeCompletionEpisode(
            id: UUID(),
            input: "supported input",
            suggestion: " supported",
            outcome: " supported outcome",
            date: Date(timeIntervalSince1970: 406)
        )
        try await fixture.database.record(supported)
        try await fixture.database.recordUnsupportedCompletionEpisodeForTesting(
            id: UUID(),
            storageVersion: 999,
            capturedAt: Date(timeIntervalSince1970: 407)
        )

        do {
            try await fixture.database.deleteEvent(id: supported.id)
            XCTFail("Expected targeted deletion to fail closed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "Unsupported completion episode storage version"
                )
            )
        }
        let countBeforeDelete = try await fixture.database.eventCount()
        XCTAssertEqual(countBeforeDelete, 2)

        try await fixture.database.deleteAll()
        let countAfterDelete = try await fixture.database.eventCount()
        XCTAssertEqual(countAfterDelete, 0)
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

    func testHydrationRejectsChunkCiphertextSubstitution() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: String(repeating: "first private block ", count: 80),
            suggestion: " suggestion",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 406)
        )
        try await fixture.database.record(episode)
        let swapped = try await fixture.database
            .swapFirstTwoTextChunkPayloadsForTesting()
        XCTAssertTrue(swapped)

        do {
            _ = try await fixture.database.completionEpisodes()
            XCTFail("Expected substituted chunk ciphertext to be rejected")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("HMAC mismatch")
            )
        }
    }

    func testHydrationRejectsCompletionPayloadRowSubstitution() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.database.record(
            makeCompletionEpisode(
                id: UUID(),
                input: "first private input",
                suggestion: " first",
                outcome: " outcome",
                date: Date(timeIntervalSince1970: 406)
            )
        )
        try await fixture.database.record(
            makeCompletionEpisode(
                id: UUID(),
                input: "second private input",
                suggestion: " second",
                outcome: " outcome",
                date: Date(timeIntervalSince1970: 407)
            )
        )
        let swapped = try await fixture.database
            .swapFirstTwoCompletionEventPayloadsForTesting()
        XCTAssertTrue(swapped)

        do {
            _ = try await fixture.database.completionEpisodes()
            XCTFail("Expected substituted event payloads to be rejected")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("integrity mismatch")
            )
        }
    }

    func testTargetedDeleteFailsClosedForSubstitutedCompletionPayloads()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = makeCompletionEpisode(
            id: UUID(),
            input: "first private input",
            suggestion: " first",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 406)
        )
        let second = makeCompletionEpisode(
            id: UUID(),
            input: "second private input",
            suggestion: " second",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 407)
        )
        try await fixture.database.record(first)
        try await fixture.database.record(second)
        let swapped = try await fixture.database
            .swapFirstTwoCompletionEventPayloadsForTesting()
        XCTAssertTrue(swapped)

        do {
            try await fixture.database.deleteEvent(id: first.id)
            XCTFail("Expected targeted deletion to fail closed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("integrity mismatch")
            )
        }
        let countBeforeDelete = try await fixture.database.eventCount()
        XCTAssertEqual(countBeforeDelete, 2)

        try await fixture.database.deleteAll()
        let countAfterDelete = try await fixture.database.eventCount()
        XCTAssertEqual(countAfterDelete, 0)
    }

    func testTargetedDeleteFailsClosedForMissingAuthenticatedChunk()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: "private chunked input",
            suggestion: " suggestion",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 408)
        )
        try await fixture.database.record(episode)
        let deletedChunk = try await fixture.database
            .deleteFirstTextChunkForTesting()
        XCTAssertTrue(deletedChunk)

        do {
            try await fixture.database.deleteEvent(id: episode.id)
            XCTFail("Expected targeted deletion to fail closed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "Missing authenticated completion episode text chunk"
                )
            )
        }
        let countBeforeDeleteAll =
            try await fixture.database.eventCount()
        XCTAssertEqual(countBeforeDeleteAll, 1)

        try await fixture.database.deleteAll()
        let countAfterDeleteAll = try await fixture.database.eventCount()
        XCTAssertEqual(countAfterDeleteAll, 0)
    }

    func testDestructiveOperationsFailClosedForSubstitutedChunkCiphertext()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: String(repeating: "private chunked input ", count: 80),
            suggestion: " suggestion",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 409)
        )
        try await fixture.database.record(episode)
        let swapped = try await fixture.database
            .swapFirstTwoTextChunkPayloadsForTesting()
        XCTAssertTrue(swapped)

        do {
            try await fixture.database.deleteEvent(id: episode.id)
            XCTFail("Expected targeted deletion to fail closed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("HMAC mismatch")
            )
        }
        let countAfterTargetedDelete =
            try await fixture.database.eventCount()
        XCTAssertEqual(countAfterTargetedDelete, 1)

        do {
            _ = try await fixture.database.enforceRetention(
                PersonalizationRetentionPolicy(
                    maximumAge: 0,
                    maximumEncryptedBytes: nil
                ),
                now: Date(timeIntervalSince1970: 410)
            )
            XCTFail("Expected retention to fail closed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("HMAC mismatch")
            )
        }
        let countAfterRetention =
            try await fixture.database.eventCount()
        XCTAssertEqual(countAfterRetention, 1)

        try await fixture.database.deleteAll()
        let countAfterDeleteAll =
            try await fixture.database.eventCount()
        XCTAssertEqual(countAfterDeleteAll, 0)
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

    func testLongProviderPrefixReusesAuthenticatedFieldChunks() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = String(
            (0..<2_100).map { index in
                Character(UnicodeScalar(0x21 + ((index * 37) % 90))!)
            }
        )
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: input,
            suggestion: " suggestion",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 410)
        )

        try await fixture.database.record(episode)

        let overlap = try await fixture.database
            .firstCompletionFieldPromptChunkOverlapForTesting()
        XCTAssertGreaterThan(overlap, 0)
        let episodes = try await fixture.database.completionEpisodes()
        XCTAssertEqual(episodes, [episode])
    }

    func testDatabaseDeletionAndForeignKeyProtectionsAreEnabled() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let isEnabled =
            try await fixture.database.foreignKeyEnforcementEnabled()
        let secureDeletion =
            try await fixture.database.secureDeletionEnabled()
        XCTAssertTrue(isEnabled)
        XCTAssertTrue(secureDeletion)
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

        try await fixture.database
            .removeEventTextChunkIndexForTesting(eventID: second.id)
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

        try await fixture.database.replaceEventTimestampForTesting(
            eventID: second.id,
            capturedAt: Date(timeIntervalSince1970: 10_000)
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

    func testMultilineProviderPrefixRoundTripsAcrossChunkBoundaries()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstParagraph = String(
            repeating: "first paragraph content ",
            count: 18
        )
        let secondParagraph = String(
            repeating: "second paragraph content ",
            count: 90
        )
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: firstParagraph + "\n\n" + secondParagraph,
            suggestion: " exact suggestion",
            outcome: " exact outcome",
            date: Date(timeIntervalSince1970: 799)
        )

        try await fixture.database.record(episode)

        let stored = try await fixture.database.completionEpisodes()
        XCTAssertEqual(stored, [episode])
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

    func testApplicationScopedDeletionRemovesCompletionEpisodes()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chat = makeCompletionEpisode(
            id: UUID(),
            input: "private chat input",
            suggestion: " suggested reply",
            outcome: " final reply",
            date: Date(timeIntervalSince1970: 850),
            applicationBundleIdentifier: "com.example.Chat"
        )
        let writer = makeCompletionEpisode(
            id: UUID(),
            input: "writer input",
            suggestion: " document continuation",
            outcome: " document outcome",
            date: Date(timeIntervalSince1970: 851),
            applicationBundleIdentifier: "com.example.Writer"
        )
        try await fixture.database.record(chat)
        try await fixture.database.record(writer)

        let deleted = try await fixture.database.deleteEvents(
            scopeKind: "application",
            value: "com.example.Chat"
        )

        XCTAssertEqual(deleted, 1)
        let remaining = try await fixture.database.completionEpisodes()
        let exported = try await fixture.database.exportCorpus()
        XCTAssertEqual(
            remaining,
            [writer]
        )
        XCTAssertEqual(
            exported.completionEpisodes,
            [writer]
        )
    }

    func testDeletingPromptExampleAlsoDeletesDependentCompletionEpisode()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: UUID(),
                fieldText: "private source text",
                selection: UTF16Selection(location: 19, length: 0),
                insertion: " from chat",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Chat",
                    inputKind: "message",
                    editorIdentifier: "chat"
                ),
                capturedAt: Date(timeIntervalSince1970: 840)
            )
        )
        let dependent = makeCompletionEpisode(
            id: UUID(),
            input: "writer input",
            suggestion: " generated from retained example",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 850),
            applicationBundleIdentifier: "com.example.Writer",
            sourceEventIDs: [source.id],
            sourceContexts: [source.context]
        )
        try await fixture.database.record(source)
        try await fixture.database.record(dependent)
        try await fixture.database
            .removeCompletionEpisodeSourceIndexForTesting(
                completionEventID: dependent.id
            )

        try await fixture.database.deleteEvent(id: source.id)

        let eventCount = try await fixture.database.eventCount()
        let completionEpisodes =
            try await fixture.database.completionEpisodes()
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(completionEpisodes, [])
    }

    func testDeletingSourceCascadesThroughNestedCompletionLineage()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recursiveTriggersEnabled =
            try await fixture.database.recursiveTriggersEnabled()
        XCTAssertTrue(recursiveTriggersEnabled)
        let source = makeEpisode(
            id: UUID(),
            text: "source writing",
            app: "com.example.Source",
            editor: "source"
        )
        let dependent = makeCompletionEpisode(
            id: UUID(),
            input: "dependent input",
            suggestion: " dependent",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 850),
            sourceEventIDs: [source.id],
            sourceContexts: [source.context]
        )
        let nested = makeCompletionEpisode(
            id: UUID(),
            input: "nested input",
            suggestion: " nested",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 851),
            sourceEventIDs: [dependent.id],
            sourceContexts: [dependent.invocation.context]
        )
        try await fixture.database.record(source)
        try await fixture.database.record(dependent)
        try await fixture.database.record(nested)

        try await fixture.database.deleteEvent(id: source.id)

        let eventCount = try await fixture.database.eventCount()
        let completionEpisodes =
            try await fixture.database.completionEpisodes()
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(completionEpisodes, [])
    }

    func testRebuildRemovesForgedChunkReferenceBeforeTargetedDeletion()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let unrelated = makeEpisode(
            id: UUID(),
            text: "unrelated writing",
            app: "com.example.Writer",
            editor: "writer"
        )
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: "private completion input",
            suggestion: " suggestion",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 860)
        )
        try await fixture.database.record(unrelated)
        try await fixture.database.record(episode)
        let attached = try await fixture.database
            .attachFirstTextChunkForTesting(eventID: unrelated.id)
        XCTAssertTrue(attached)

        try await fixture.database.deleteEvent(id: episode.id)

        let storage =
            try await fixture.database.completionEpisodeStorageStatistics()
        XCTAssertEqual(storage.uniqueTextChunkCount, 0)
        XCTAssertEqual(storage.textChunkReferenceCount, 0)
        let remaining = try await fixture.database.writingEpisodes()
        XCTAssertEqual(remaining, [unrelated])
    }

    func testRebuildRemovesForgedSourceEdgeBeforeCascadeDeletion()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let unrelated = makeEpisode(
            id: UUID(),
            text: "unrelated writing",
            app: "com.example.Writer",
            editor: "writer"
        )
        let source = makeEpisode(
            id: UUID(),
            text: "source writing",
            app: "com.example.Chat",
            editor: "chat"
        )
        try await fixture.database.record(unrelated)
        try await fixture.database.record(source)
        try await fixture.database
            .insertCompletionEpisodeSourceIndexForTesting(
                completionEventID: unrelated.id,
                sourceEventID: source.id
            )

        try await fixture.database.deleteEvent(id: source.id)

        let remaining = try await fixture.database.writingEpisodes()
        XCTAssertEqual(remaining, [unrelated])
    }

    func testCompletionEpisodeWithMissingSourceIsNotStored() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let episode = makeCompletionEpisode(
            id: UUID(),
            input: "writer input",
            suggestion: " generated from absent source",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 850),
            sourceEventIDs: [UUID()]
        )

        do {
            try await fixture.database.record(episode)
            XCTFail("Expected missing source event to reject the record")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "Missing completion episode source event"
                )
            )
        }

        let eventCount = try await fixture.database.eventCount()
        let completionEpisodes =
            try await fixture.database.completionEpisodes()
        let storage =
            try await fixture.database.completionEpisodeStorageStatistics()
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(completionEpisodes, [])
        XCTAssertEqual(storage.uniqueTextChunkCount, 0)
        XCTAssertEqual(storage.textChunkReferenceCount, 0)
    }

    func testTargetedDeletionAtomicallyInvalidatesDerivedProjections()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                fieldText: "private source",
                selection: UTF16Selection(location: 14, length: 0),
                insertion: " text",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(editorIdentifier: "editor")
            )
        )
        try await fixture.database.record(capture)
        try await fixture.database.saveLanguageModel(
            PersonalLanguageModel()
        )
        try await fixture.database.saveVoiceAssessment(
            VoiceAssessment(
                summary: "Derived from private source.",
                sampleCount: 10,
                sourceEventCount: 10,
                generatedAt: Date()
            )
        )

        try await fixture.database.deleteEvent(id: capture.id)

        let languageModel =
            try await fixture.database.loadLanguageModel()
        let voiceAssessment =
            try await fixture.database.loadVoiceAssessment()
        XCTAssertNil(languageModel)
        XCTAssertNil(voiceAssessment)
    }

    func testSourceApplicationScopeDeletesDependentCompletionEpisode()
        async throws
    {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let sourceContext = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Chat",
            inputKind: "message",
            editorIdentifier: "chat"
        )
        let source = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: UUID(),
                fieldText: "private chat example",
                selection: UTF16Selection(location: 20, length: 0),
                insertion: " retained",
                acceptanceScope: .entireSuggestion,
                context: sourceContext,
                capturedAt: Date(timeIntervalSince1970: 840)
            )
        )
        let dependent = makeCompletionEpisode(
            id: UUID(),
            input: "writer input",
            suggestion: " generated from chat",
            outcome: " outcome",
            date: Date(timeIntervalSince1970: 850),
            applicationBundleIdentifier: "com.example.Writer",
            sourceEventIDs: [source.id],
            sourceContexts: [sourceContext]
        )
        try await fixture.database.record(source)
        try await fixture.database.record(dependent)
        try await fixture.database
            .removeEventScopeIndexForTesting(eventID: source.id)

        _ = try await fixture.database.deleteEvents(
            scopeKind: "application",
            value: "com.example.Chat"
        )

        let eventCount = try await fixture.database.eventCount()
        let completionEpisodes =
            try await fixture.database.completionEpisodes()
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(completionEpisodes, [])
    }

    func testStorageCapRecomputesAfterSourceCascadeDeletion() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let unrelated = makeCompletionEpisode(
            id: UUID(),
            input: "unrelated history",
            suggestion: " remains",
            outcome: " remains",
            date: Date(timeIntervalSince1970: 200)
        )
        try await fixture.database.record(unrelated)
        let unrelatedStorage =
            try await fixture.database.storageStatistics()

        let source = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: UUID(),
                fieldText: "old source",
                selection: UTF16Selection(location: 10, length: 0),
                insertion: " text",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(
                    editorIdentifier: "source"
                ),
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let dependent = makeCompletionEpisode(
            id: UUID(),
            input: String(repeating: "large dependent prompt ", count: 2_000),
            suggestion: " dependent",
            outcome: " dependent",
            date: Date(timeIntervalSince1970: 300),
            sourceEventIDs: [source.id],
            sourceContexts: [source.context]
        )
        try await fixture.database.record(source)
        try await fixture.database.record(dependent)

        _ = try await fixture.database.enforceRetention(
            PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes:
                    unrelatedStorage.encryptedPayloadBytes
            )
        )

        let remaining = try await fixture.database.completionEpisodes()
        XCTAssertEqual(remaining, [unrelated])
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

    func testStorageCapDropsProjectionBeforeCanonicalEvents() async throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                fieldText: "canonical history",
                selection: UTF16Selection(location: 17, length: 0),
                insertion: " remains",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(editorIdentifier: "editor"),
                capturedAt: Date(timeIntervalSince1970: 4_000)
            )
        )
        try await fixture.database.record(capture)
        let canonicalStorage =
            try await fixture.database.storageStatistics()
        try await fixture.database.saveVoiceAssessment(
            VoiceAssessment(
                summary: String(repeating: "derived projection ", count: 500),
                sampleCount: 10,
                sourceEventCount: 10,
                generatedAt: Date()
            )
        )
        let withProjection =
            try await fixture.database.storageStatistics()
        XCTAssertGreaterThan(
            withProjection.encryptedPayloadBytes,
            canonicalStorage.encryptedPayloadBytes
        )

        let removed = try await fixture.database.enforceRetention(
            PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes:
                    canonicalStorage.encryptedPayloadBytes
            )
        )

        XCTAssertEqual(removed, 0)
        let remaining = try await fixture.database.acceptedSuggestions()
        let assessment = try await fixture.database.loadVoiceAssessment()
        XCTAssertEqual(remaining, [capture])
        XCTAssertNil(assessment)
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
        promptInputOverride: String? = nil,
        applicationBundleIdentifier: String = "com.example.Editor",
        sourceEventIDs: [UUID] = [],
        sourceContexts: [PersonalizationContext] = []
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
                applicationBundleIdentifier: applicationBundleIdentifier,
                inputKind: "document",
                editorIdentifier: "editor"
            ),
            sourceEventIDs: sourceEventIDs,
            sourceContexts: sourceContexts,
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
