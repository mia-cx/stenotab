import CompletionCore
import Foundation
@testable import StenoTabPersistence
@testable import StenoTab
import XCTest

final class PersonalizationIntegrationTests: XCTestCase {
    @MainActor
    private final class ResetSpy: PersonalizationHistoryResetting {
        private(set) var historyResetCount = 0
        private(set) var writingResetCount = 0

        func personalizationHistoryWillReset() {
            historyResetCount += 1
        }

        func writingHistoryWillReset() {
            writingResetCount += 1
        }
    }

    func testInFlightRecordIsRemovedWhenConsentIsRevoked()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let consentEpoch = PersonalizationConsentEpoch()
        let worker = PersonalizationModelWorker(
            database: database,
            collectionConsentEpoch: consentEpoch
        )
        _ = try await worker.prepare()
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "RevokedUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        await worker.setRecordDidPersistForTesting {
            consentEpoch.advance(to: 1)
        }

        let model = try await worker.record(
            capture,
            retentionPolicy: PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes: nil
            ),
            generation: 0,
            consentGeneration: 0
        )

        let storedSuggestions = try await database.acceptedSuggestions()
        XCTAssertEqual(storedSuggestions, [])
        XCTAssertEqual(model.vocabularyEntries(), [])
    }

    func testLateConsentRevocationRemovesDerivedAcceptedCapture()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let consentEpoch = PersonalizationConsentEpoch()
        let worker = PersonalizationModelWorker(
            database: database,
            collectionConsentEpoch: consentEpoch
        )
        _ = try await worker.prepare()
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "LateRevocationUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        await worker.setRecordWillFinalizeConsentForTesting {
            consentEpoch.advance(to: 1)
        }

        let model = try await worker.record(
            capture,
            retentionPolicy: PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes: nil
            ),
            generation: 0,
            consentGeneration: 0
        )
        let storedSuggestions = try await database.acceptedSuggestions()
        let storedVoiceAssessment =
            try await database.loadVoiceAssessment()

        XCTAssertEqual(storedSuggestions, [])
        XCTAssertEqual(model.vocabularyEntries(), [])
        XCTAssertNil(storedVoiceAssessment)
    }

    func testCompletionEpisodeIsRemovedWhenConsentRevokesAfterPersist()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let consentEpoch = PersonalizationConsentEpoch()
        let worker = PersonalizationModelWorker(
            database: database,
            collectionConsentEpoch: consentEpoch
        )
        _ = try await worker.prepare()
        let episode = makeCompletionEpisode(
            context: PersonalizationContext(editorIdentifier: "editor"),
            index: 700,
            collectionGeneration: 0,
            initialText: String(repeating: "private prompt ", count: 200)
        )
        await worker.setRecordDidPersistForTesting {
            consentEpoch.advance(to: 1)
        }

        _ = try await worker.record(
            episode,
            retentionPolicy: PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes: nil
            ),
            generation: 0,
            consentGeneration: 0
        )
        let storedEpisodes = try await database.completionEpisodes()

        XCTAssertEqual(storedEpisodes, [])
        let statistics =
            try await database.completionEpisodeStorageStatistics()
        XCTAssertEqual(statistics.uniqueTextChunkCount, 0)
        XCTAssertEqual(statistics.textChunkReferenceCount, 0)
    }

    @MainActor
    func testRestartRemovesPendingCaptureFromRevokedGeneration()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "CrashWindowUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        try await database.recordPendingConsent(
            capture,
            collectionGeneration: 0
        )
        let originalStore =
            PersonalizationSettingsStore(defaults: defaults)
        originalStore.collectionEnabled = false

        let restartedStore =
            PersonalizationSettingsStore(defaults: defaults)
        restartedStore.attach(database: database)
        await restartedStore.flushPendingPersistence()
        let storedSuggestions = try await database.acceptedSuggestions()

        XCTAssertEqual(storedSuggestions, [])
        XCTAssertEqual(restartedStore.vocabularyEntries, [])
    }

    @MainActor
    func testRestartRemovesPendingWritingFromRevokedDirectGeneration()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let date = Date()
        let initial = CapturedFieldState(
            text: "",
            selection: UTF16Selection(location: 0, length: 0)
        )
        let final = CapturedFieldState(
            text: "PendingDirectRestartToken",
            selection: UTF16Selection(location: 25, length: 0)
        )
        let episode = WritingEpisodeCapture(
            id: UUID(),
            initialField: initial,
            finalField: final,
            edits: [
                WritingEditCapture(
                    insertedText: final.text,
                    provenance: .directlyTyped,
                    selectionBefore: initial.selection,
                    selectionAfter: final.selection,
                    fieldBefore: initial,
                    fieldAfter: final,
                    startedAt: date,
                    endedAt: date
                ),
            ],
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: date,
            endedAt: date,
            boundary: .submitted
        )
        try await database.recordPendingConsent(
            episode,
            collectionGeneration: 0,
            directTypingGeneration: 0
        )
        let originalStore =
            PersonalizationSettingsStore(defaults: defaults)
        originalStore.collectDirectTyping = false

        let restartedStore =
            PersonalizationSettingsStore(defaults: defaults)
        restartedStore.attach(database: database)
        await restartedStore.flushPendingPersistence()

        let storedEpisodes = try await database.writingEpisodes()
        XCTAssertEqual(storedEpisodes, [])
        XCTAssertEqual(restartedStore.vocabularyEntries, [])
    }

    func testRestartRebuildsModelForPromotedPendingCapture()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        try await database.saveLanguageModel(PersonalLanguageModel())
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "RecoveredProjectionUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        try await database.recordPendingConsent(
            capture,
            collectionGeneration: 0
        )
        let worker = PersonalizationModelWorker(database: database)

        let recoveredModel = try await worker.prepare()

        XCTAssertEqual(
            recoveredModel.vocabularyEntries().map(\.normalized),
            ["recoveredprojectionuniquetoken"]
        )
    }

    func testDirectTypingRevocationDoesNotCancelAcceptedSuggestion()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let collectionConsentEpoch = PersonalizationConsentEpoch()
        let directTypingConsentEpoch = PersonalizationConsentEpoch()
        let worker = PersonalizationModelWorker(
            database: database,
            collectionConsentEpoch: collectionConsentEpoch,
            directTypingConsentEpoch: directTypingConsentEpoch
        )
        _ = try await worker.prepare()
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "AcceptedWhileDirectTypingTurnsOff",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        await worker.setRecordDidPersistForTesting {
            directTypingConsentEpoch.advance(to: 1)
        }

        let model = try await worker.record(
            capture,
            retentionPolicy: PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes: nil
            ),
            generation: 0,
            consentGeneration: 0
        )

        let storedSuggestionIDs =
            try await database.acceptedSuggestions().map(\.id)
        XCTAssertEqual(storedSuggestionIDs, [capture.id])
        XCTAssertFalse(model.vocabularyEntries().isEmpty)
    }

    func testLateWritingRecordIsRemovedWhenConsentIsRevoked()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let consentEpoch = PersonalizationConsentEpoch()
        let directTypingConsentEpoch = PersonalizationConsentEpoch()
        let worker = PersonalizationModelWorker(
            database: database,
            collectionConsentEpoch: consentEpoch,
            directTypingConsentEpoch: directTypingConsentEpoch
        )
        _ = try await worker.prepare()
        let date = Date()
        let initial = CapturedFieldState(
            text: "",
            selection: UTF16Selection(location: 0, length: 0)
        )
        let final = CapturedFieldState(
            text: "RevokedDirectToken",
            selection: UTF16Selection(location: 18, length: 0)
        )
        let episode = WritingEpisodeCapture(
            id: UUID(),
            initialField: initial,
            finalField: final,
            edits: [
                WritingEditCapture(
                    insertedText: final.text,
                    provenance: .directlyTyped,
                    selectionBefore: initial.selection,
                    selectionAfter: final.selection,
                    fieldBefore: initial,
                    fieldAfter: final,
                    startedAt: date,
                    endedAt: date
                ),
            ],
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: date,
            endedAt: date,
            boundary: .submitted
        )
        await worker.setRecordWillFinalizeConsentForTesting {
            directTypingConsentEpoch.advance(to: 1)
        }

        let model = try await worker.record(
            episode,
            retentionPolicy: PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes: nil
            ),
            generation: 0,
            consentGeneration: 0,
            directTypingConsentGeneration: 0
        )

        let storedEpisodes = try await database.writingEpisodes()
        XCTAssertEqual(storedEpisodes, [])
        XCTAssertEqual(model.vocabularyEntries(), [])
    }

    @MainActor
    func testDisablingCollectionCancelsPersonalizationConsumers() throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationSettingsStore(defaults: defaults)
        var didResetConsumers = false
        store.onHistoryReset = {
            didResetConsumers = true
        }

        store.collectionEnabled = false

        XCTAssertTrue(didResetConsumers)
    }

    @MainActor
    func testConsentToggleAndEpochUseOneAuthoritativeState()
        throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationSettingsStore(defaults: defaults)

        store.collectionEnabled = false
        store.collectDirectTyping = false
        defaults.set(
            true,
            forKey: "personalization.collectionEnabled"
        )
        defaults.set(
            "0",
            forKey: "personalization.collectionConsentGeneration"
        )
        defaults.set(
            true,
            forKey: "personalization.collectDirectTyping"
        )
        defaults.set(
            "0",
            forKey: "personalization.directTypingConsentGeneration"
        )

        let restarted = PersonalizationSettingsStore(defaults: defaults)

        XCTAssertFalse(restarted.collectionEnabled)
        XCTAssertFalse(restarted.collectDirectTyping)
    }

    @MainActor
    func testAppDelegateRoutesBothConsentResetsToCoordinatorBoundary()
        throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationSettingsStore(defaults: defaults)
        let resetter = ResetSpy()
        AppDelegate.connectPersonalizationResetHandlers(
            settings: store,
            resetter: resetter
        )

        store.collectDirectTyping = false
        store.collectionEnabled = false

        XCTAssertEqual(resetter.writingResetCount, 1)
        XCTAssertEqual(resetter.historyResetCount, 1)
    }

    @MainActor
    func testRecoveryDeleteAllRemainsAvailableWithoutDatabase()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(
            path: "personalization.sqlite"
        )
        let keyProvider = StaticPersonalizationKeyProvider(
            keyData: Data(repeating: 0x42, count: 64)
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        var didDelete = false
        store.attachRecoveryDeleteAll {
            didDelete = true
            return try PersonalizationDatabase(
                databaseURL: databaseURL,
                keyProvider: keyProvider
            )
        }

        XCTAssertTrue(store.recoveryDeletionIsAvailable)
        store.deleteAll()
        await store.flushPendingPersistence()

        XCTAssertTrue(didDelete)
        XCTAssertFalse(store.recoveryDeletionIsAvailable)
        XCTAssertNil(store.operationError)

        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "RecoveredStorage",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        store.record(capture)
        await store.flushPendingPersistence()
        let reopened = try PersonalizationDatabase(
            databaseURL: databaseURL,
            keyProvider: keyProvider
        )
        let storedIDs =
            try await reopened.acceptedSuggestions().map(\.id)
        XCTAssertEqual(storedIDs, [capture.id])
    }

    @MainActor
    func testDisablingDirectTypingCancelsWritingCapture() throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationSettingsStore(defaults: defaults)
        var didResetConsumers = false
        store.onWritingHistoryReset = {
            didResetConsumers = true
        }

        store.collectDirectTyping = false

        XCTAssertTrue(didResetConsumers)
    }

    @MainActor
    func testHidingHistoryInspectorClearsDecryptedRecords() async throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "private inspector text",
                selection: UTF16Selection(location: 22, length: 0)
            ),
            insertion: " secret",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        store.record(capture)
        await store.flushPendingPersistence()
        XCTAssertEqual(store.recentAcceptedSuggestions, [])

        store.setHistoryInspectorVisible(true)
        await store.flushPendingPersistence()
        XCTAssertEqual(store.recentAcceptedSuggestions.map(\.id), [capture.id])

        store.setHistoryInspectorVisible(false)

        XCTAssertEqual(store.recentAcceptedSuggestions, [])
        XCTAssertEqual(store.recentEpisodes, [])
        XCTAssertEqual(store.recentCompletionEpisodes, [])
    }

    @MainActor
    func testClosingInspectorCancelsQueuedHistoryDecryption() async throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        try await database.record(
            AcceptedSuggestionCapture(
                id: UUID(),
                field: CapturedFieldState(
                    text: "queued private text",
                    selection: UTF16Selection(location: 19, length: 0)
                ),
                insertion: " secret",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(
                    editorIdentifier: "editor"
                ),
                capturedAt: Date()
            )
        )
        store.historyInspectorWillLoadRecordsForTesting = {
            store.setHistoryInspectorVisible(false)
        }

        store.setHistoryInspectorVisible(true)
        await store.flushPendingPersistence()

        XCTAssertEqual(store.recentAcceptedSuggestions, [])
        XCTAssertEqual(store.recentEpisodes, [])
        XCTAssertEqual(store.recentCompletionEpisodes, [])
    }

    @MainActor
    func testStaleRecordResultCannotRepublishInvalidatedModel() async throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        store.recordDidLoadDerivedStateForTesting = {
            store.invalidateCollectionGenerationForTesting()
        }
        store.record(
            AcceptedSuggestionCapture(
                id: UUID(),
                field: CapturedFieldState(
                    text: "",
                    selection: UTF16Selection(location: 0, length: 0)
                ),
                insertion: "MustNotRepublish",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(
                    editorIdentifier: "editor"
                ),
                capturedAt: Date()
            )
        )

        await store.flushPendingPersistence()

        XCTAssertEqual(store.vocabularyEntries, [])
        XCTAssertNil(
            store.personalCompletion(
                for: "Must",
                context: PersonalizationContext(
                    editorIdentifier: "editor"
                )
            )
        )
    }

    @MainActor
    func testDisablingCollectionRejectsLoadedPromptsAndQueuedWrites()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let context = PersonalizationContext(editorIdentifier: "editor")
        let storedCapture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "StoredUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: context,
            capturedAt: Date()
        )
        store.record(storedCapture)
        await store.flushPendingPersistence()
        store.promptContextDidLoadForTesting = {
            store.collectionEnabled = false
        }

        let loadedAfterDisable = await store.promptContext(
            for: "StoredUniqueToken",
            context: context
        )

        XCTAssertEqual(loadedAfterDisable, .empty)
        store.collectionEnabled = true
        let queuedCapture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "QueuedUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: context,
            capturedAt: Date()
        )
        store.record(queuedCapture)
        store.collectionEnabled = false
        await store.flushPendingPersistence()

        let storedSuggestions = try await database.acceptedSuggestions()
        XCTAssertEqual(storedSuggestions.map(\.id), [storedCapture.id])
    }

    @MainActor
    func testDisableBeforeAttachCanImmediatelyResumeCollection()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.collectionEnabled = false
        store.attach(database: database)
        await store.flushPendingPersistence()
        store.collectionEnabled = true
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "ResumedUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )

        store.record(capture)
        await store.flushPendingPersistence()

        let storedSuggestions = try await database.acceptedSuggestions()
        XCTAssertEqual(storedSuggestions.map(\.id), [capture.id])
    }

    @MainActor
    func testDisablingCollectionDoesNotStrandSuccessfulDeleteAll()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let context = PersonalizationContext(editorIdentifier: "editor")
        let oldCapture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "OldUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: context,
            capturedAt: Date()
        )
        store.record(oldCapture)
        await store.flushPendingPersistence()

        store.deleteAll()
        store.collectionEnabled = false
        await store.flushPendingPersistence()

        let suggestionsAfterDelete =
            try await database.acceptedSuggestions()
        XCTAssertEqual(suggestionsAfterDelete, [])
        XCTAssertEqual(store.vocabularyEntries, [])
        store.collectionEnabled = true
        let newCapture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "NewUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: context,
            capturedAt: Date()
        )
        store.record(newCapture)
        await store.flushPendingPersistence()

        let storedSuggestions = try await database.acceptedSuggestions()
        XCTAssertEqual(storedSuggestions.map(\.id), [newCapture.id])
    }

    @MainActor
    func testQueuedWritingEpisodeHonorsDirectTypingToggle() async throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let date = Date()
        let initial = CapturedFieldState(
            text: "",
            selection: UTF16Selection(location: 0, length: 0)
        )
        let final = CapturedFieldState(
            text: "DirectUniqueToken",
            selection: UTF16Selection(location: 17, length: 0)
        )
        let episode = WritingEpisodeCapture(
            id: UUID(),
            initialField: initial,
            finalField: final,
            edits: [
                WritingEditCapture(
                    insertedText: final.text,
                    provenance: .directlyTyped,
                    selectionBefore: initial.selection,
                    selectionAfter: final.selection,
                    fieldBefore: initial,
                    fieldAfter: final,
                    startedAt: date,
                    endedAt: date
                ),
            ],
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: date,
            endedAt: date,
            boundary: .submitted
        )

        store.record(episode)
        store.collectDirectTyping = false
        await store.flushPendingPersistence()

        let storedEpisodes = try await database.writingEpisodes()
        XCTAssertEqual(storedEpisodes, [])
    }

    @MainActor
    func testSettingsLoadDisablesLegacyClipboardAndOCROptIns() throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var legacyConfiguration = PromptConfiguration.defaults
        legacyConfiguration.context.includeClipboard = true
        legacyConfiguration.context.includeOCR = true
        let overrides = PromptConfiguration.Overrides(
            configuration: legacyConfiguration,
            relativeTo: .defaults
        )
        defaults.set(
            try JSONEncoder().encode(overrides),
            forKey: "prompt-lab.overrides.v2"
        )
        defaults.set(
            0,
            forKey: "prompt-lab.context-retention-disclosure-version"
        )

        let store = PromptSettingsStore(defaults: defaults)

        XCTAssertFalse(store.configuration.context.includeClipboard)
        XCTAssertFalse(store.configuration.context.includeOCR)
        XCTAssertEqual(
            defaults.integer(
                forKey: "prompt-lab.context-retention-disclosure-version"
            ),
            PromptContextRetentionMigration.currentDisclosureVersion
        )
        XCTAssertNil(defaults.data(forKey: "prompt-lab.overrides.v2"))
    }

    @MainActor
    func testSettingsLoadMigratesLegacyFullConfiguration() throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var legacyConfiguration = PromptConfiguration.defaults
        legacyConfiguration.context.includeClipboard = true
        legacyConfiguration.context.includeOCR = true
        defaults.set(
            try JSONEncoder().encode(legacyConfiguration),
            forKey: "prompt-lab.configuration.v1"
        )

        let store = PromptSettingsStore(defaults: defaults)

        XCTAssertFalse(store.configuration.context.includeClipboard)
        XCTAssertFalse(store.configuration.context.includeOCR)
        XCTAssertNil(defaults.data(forKey: "prompt-lab.configuration.v1"))
        XCTAssertEqual(
            defaults.integer(
                forKey: "prompt-lab.context-retention-disclosure-version"
            ),
            PromptContextRetentionMigration.currentDisclosureVersion
        )
    }

    func testCompletionEpisodesRemainClassicalPersonalizationNeutral()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let worker = PersonalizationModelWorker(database: database)
        let context = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Writer",
            inputKind: "document",
            editorIdentifier: "editor"
        )
        let beforeModel = try await worker.prepare()
        let beforeContext = try await worker.promptContext(
            for: "quasarUniqueToken",
            context: context
        )
        var episodes: [CompletionEpisodeCapture] = []
        var afterModel = beforeModel
        for index in 0..<10 {
            let episode = makeCompletionEpisode(
                context: context,
                index: index
            )
            episodes.append(episode)
            afterModel = try await worker.record(
                episode,
                retentionPolicy: PersonalizationRetentionPolicy(
                    maximumAge: nil,
                    maximumEncryptedBytes: nil
                ),
                generation: 0
            )
        }
        let afterContext = try await worker.promptContext(
            for: "quasarUniqueToken",
            context: context
        )
        let storedEpisodes = try await database.completionEpisodes()
        let storedEmbeddings = try await database.embeddings()
        let storedVoiceAssessment =
            try await database.loadVoiceAssessment()

        XCTAssertEqual(afterModel, beforeModel)
        XCTAssertEqual(beforeContext, .empty)
        XCTAssertEqual(afterContext, .empty)
        XCTAssertEqual(storedEpisodes, episodes)
        XCTAssertEqual(storedEmbeddings, [])
        XCTAssertNil(storedVoiceAssessment)

        let restartedWorker = PersonalizationModelWorker(database: database)
        let restartedModel = try await restartedWorker.prepare()
        let restartedContext = try await restartedWorker.promptContext(
            for: "quasarUniqueToken",
            context: context
        )
        let restartedEmbeddings = try await database.embeddings()
        let restartedVoiceAssessment =
            try await database.loadVoiceAssessment()
        XCTAssertEqual(restartedModel, beforeModel)
        XCTAssertEqual(restartedContext, .empty)
        XCTAssertEqual(restartedEmbeddings, [])
        XCTAssertNil(restartedVoiceAssessment)
    }

    func testWorkerSuppliesPromptRecordCharacterCounts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let worker = PersonalizationModelWorker(database: database)
        _ = try await worker.prepare()
        let context = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Writer",
            inputKind: "document",
            editorIdentifier: "editor"
        )
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text:
                    String(repeating: "a", count: 1_500)
                    + PersonalizationExample.promptRecordSeparator
                    + String(repeating: "b", count: 1_500),
                selection: UTF16Selection(location: 3_001, length: 0)
            ),
            insertion: " completed",
            acceptanceScope: .entireSuggestion,
            context: context,
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        _ = try await worker.record(
            capture,
            retentionPolicy: PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes: nil
            ),
            generation: 0
        )

        let promptContext = try await worker.promptContext(
            for: "",
            context: context
        )

        XCTAssertEqual(
            promptContext.frecentRecordCharacterCounts,
            [PersonalizationExample(capture).promptText.count]
        )
    }

    func testPreparePurgesUnlineagedVoiceAssessmentBelowThreshold()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        try await database.saveVoiceAssessment(
            VoiceAssessment(
                summary: "Legacy private voice summary.",
                sampleCount: 20,
                sourceEventCount: 20,
                generatedAt: Date(timeIntervalSince1970: 2_000),
                analyzerVersion: nil
            )
        )
        let worker = PersonalizationModelWorker(database: database)

        _ = try await worker.prepare()

        let workerAssessment = await worker.voiceAssessmentSnapshot()
        let storedAssessment = try await database.loadVoiceAssessment()
        XCTAssertNil(workerAssessment)
        XCTAssertNil(storedAssessment)
    }

    @MainActor
    func testDeleteAllSynchronouslyInvalidatesPendingCaptureState()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        var didInvalidatePendingCaptureState = false
        store.onHistoryReset = {
            didInvalidatePendingCaptureState = true
        }

        store.deleteAll()

        XCTAssertTrue(didInvalidatePendingCaptureState)
        await store.flushPendingPersistence()
    }

    @MainActor
    func testExportWaitsForQueuedDeleteAll() async throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        store.record(
            AcceptedSuggestionCapture(
                id: UUID(),
                field: CapturedFieldState(
                    text: "",
                    selection: UTF16Selection(location: 0, length: 0)
                ),
                insertion: "delete before export",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(
                    editorIdentifier: "editor"
                ),
                capturedAt: Date()
            )
        )
        await store.flushPendingPersistence()

        store.deleteAll()
        let data = try await store.exportData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(
            PersonalizationCorpusExport.self,
            from: data
        )

        XCTAssertEqual(export.acceptedSuggestions, [])
        XCTAssertEqual(export.writingEpisodes, [])
        XCTAssertEqual(export.completionEpisodes, [])
    }

    @MainActor
    func testClearingSuggestionDefersUnobservedPendingOutcomeSettlement() {
        let expected = CapturedFieldState(
            text: "before after",
            selection: UTF16Selection(location: 12, length: 0)
        )

        XCTAssertTrue(
            CompletionCoordinator
                .shouldDeferPendingOutcomeSettlementWhileClearing(
                pendingResolution: .accepted,
                expectedField: expected
            )
        )
        XCTAssertFalse(
            CompletionCoordinator
                .shouldDeferPendingOutcomeSettlementWhileClearing(
                pendingResolution: nil,
                expectedField: expected
            )
        )
        XCTAssertFalse(
            CompletionCoordinator
                .shouldDeferPendingOutcomeSettlementWhileClearing(
                pendingResolution: .accepted,
                expectedField: nil
            )
        )
    }

    @MainActor
    func testDeleteAllRejectsOlderGenerationDespiteFutureWallClock()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "DeleteAllUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        store.record(capture)
        await store.flushPendingPersistence()
        XCTAssertFalse(store.vocabularyEntries.isEmpty)
        let episode = makeCompletionEpisode(
            context: PersonalizationContext(editorIdentifier: "editor"),
            index: 0,
            collectionGeneration: store.captureGeneration,
            date: Date(timeIntervalSinceNow: 24 * 60 * 60)
        )

        store.deleteAll()
        XCTAssertTrue(store.vocabularyEntries.isEmpty)
        await store.flushPendingPersistence()
        store.record(episode)
        await store.flushPendingPersistence()

        let storedEpisodes = try await database.completionEpisodes()
        XCTAssertEqual(storedEpisodes, [])
    }

    @MainActor
    func testStoreRecordsCurrentGenerationCompletionEpisode()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let captureDate = Date(
            timeIntervalSince1970:
                floor(Date().timeIntervalSince1970)
        )
        let episode = makeCompletionEpisode(
            context: PersonalizationContext(
                applicationBundleIdentifier: "com.example.Writer",
                editorIdentifier: "editor"
            ),
            index: 0,
            collectionGeneration: store.captureGeneration,
            date: captureDate
        )

        store.record(episode)
        await store.flushPendingPersistence()

        let storedEpisodes = try await database.completionEpisodes()
        XCTAssertEqual(storedEpisodes, [episode])
    }

    @MainActor
    func testApplicationDeleteUsesGenerationBeforeWallClockBoundary()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let targetBundleIdentifier = "com.example.Target"
        let targetContext = PersonalizationContext(
            applicationBundleIdentifier: targetBundleIdentifier,
            editorIdentifier: "target-editor"
        )
        let otherContext = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Other",
            editorIdentifier: "other-editor"
        )
        let generation = store.captureGeneration
        let targetSuggestion = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "ApplicationDeleteUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: targetContext,
            capturedAt: Date()
        )
        let targetEpisode = makeCompletionEpisode(
            context: targetContext,
            index: 0,
            collectionGeneration: generation,
            date: Date()
        )
        let otherEpisode = makeCompletionEpisode(
            context: otherContext,
            index: 1,
            collectionGeneration: generation,
            date: Date().addingTimeInterval(1)
        )
        let staleTargetEpisode = makeCompletionEpisode(
            context: targetContext,
            index: 2,
            collectionGeneration: generation,
            date: Date(timeIntervalSinceNow: 24 * 60 * 60)
        )
        store.record(targetSuggestion)
        store.record(targetEpisode)
        store.record(otherEpisode)
        await store.flushPendingPersistence()
        XCTAssertFalse(store.vocabularyEntries.isEmpty)
        var didResetHistory = false
        store.onHistoryReset = {
            didResetHistory = true
        }

        store.deleteApplicationHistory(
            bundleIdentifier: targetBundleIdentifier
        )

        XCTAssertTrue(didResetHistory)
        XCTAssertTrue(store.vocabularyEntries.isEmpty)
        await store.flushPendingPersistence()
        let boundaryTargetEpisode = makeCompletionEpisode(
            context: targetContext,
            index: 3,
            collectionGeneration: store.captureGeneration,
            date: targetEpisode.invocation.startedAt
        )
        store.record(staleTargetEpisode)
        store.record(boundaryTargetEpisode)
        await store.flushPendingPersistence()

        let storedEpisodes = try await database.completionEpisodes()
        XCTAssertEqual(
            storedEpisodes.map(\.id),
            [otherEpisode.id, boundaryTargetEpisode.id]
        )
        XCTAssertEqual(
            storedEpisodes.map(\.invocation.context),
            [otherContext, targetContext]
        )
    }

    @MainActor
    func testDeleteEventImmediatelyInvalidatesDerivedPersonalization()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let context = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Writer",
            editorIdentifier: "editor"
        )
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "QuasarUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: context,
            capturedAt: Date()
        )
        store.record(capture)
        await store.flushPendingPersistence()
        XCTAssertEqual(
            store.vocabularyEntries.map(\.normalized),
            ["quasaruniquetoken"]
        )
        let promptContext = await store.promptContext(
            for: "QuasarUniqueToken",
            context: context
        )
        XCTAssertNotEqual(promptContext, .empty)
        store.promptContextDidLoadForTesting = {
            store.deleteEvent(id: capture.id)
        }
        let overlappingPromptContext = await store.promptContext(
            for: "QuasarUniqueToken",
            context: context
        )
        XCTAssertEqual(overlappingPromptContext, .empty)
        await store.flushPendingPersistence()

        store.record(capture)
        await store.flushPendingPersistence()
        var didResetHistory = false
        store.onHistoryReset = {
            didResetHistory = true
        }

        store.deleteEvent(id: capture.id)

        XCTAssertTrue(didResetHistory)
        XCTAssertTrue(store.vocabularyEntries.isEmpty)
        let invalidatedPromptContext = await store.promptContext(
            for: "QuasarUniqueToken",
            context: context
        )
        XCTAssertEqual(invalidatedPromptContext, .empty)
        await store.flushPendingPersistence()
        let storedSuggestions = try await database.acceptedSuggestions()
        XCTAssertEqual(storedSuggestions, [])
    }

    @MainActor
    func testFailedDeleteRecoversStoreAndAllowsLaterWrites() async throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()
        let context = PersonalizationContext(editorIdentifier: "editor")
        let episode = makeCompletionEpisode(
            context: context,
            index: 99,
            collectionGeneration: store.captureGeneration,
            initialText:
                (0..<400).map { "private chunk \($0) " }.joined()
        )
        try await database.record(episode)
        let swapped =
            try await database.swapFirstTwoTextChunkPayloadsForTesting()
        XCTAssertTrue(swapped)

        store.deleteEvent(id: episode.id)
        await store.flushPendingPersistence()

        XCTAssertNotNil(store.operationError)
        XCTAssertEqual(store.storedEventCount, 1)
        let laterCapture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "RecoveryUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: context,
            capturedAt: Date()
        )
        store.record(laterCapture)
        await store.flushPendingPersistence()

        let storedSuggestions = try await database.acceptedSuggestions()
        XCTAssertEqual(storedSuggestions.map(\.id), [laterCapture.id])
    }

    func testConsentCleanupIgnoresUnrelatedCorruptCompletion()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let consentEpoch = PersonalizationConsentEpoch()
        let worker = PersonalizationModelWorker(
            database: database,
            collectionConsentEpoch: consentEpoch
        )
        _ = try await worker.prepare()
        let corruptEpisode = makeCompletionEpisode(
            context: PersonalizationContext(editorIdentifier: "editor"),
            index: 100,
            initialText:
                (0..<400).map { "private chunk \($0) " }.joined()
        )
        try await database.record(corruptEpisode)
        let deletedChunk =
            try await database.deleteFirstTextChunkForTesting()
        XCTAssertTrue(deletedChunk)
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "MustNotRemain",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        await worker.setRecordDidPersistForTesting {
            consentEpoch.advance(to: 1)
        }

        let model = try await worker.record(
            capture,
            retentionPolicy: PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes: nil
            ),
            generation: 0,
            consentGeneration: 0
        )

        let eventCount = try await database.eventCount()
        let storedSuggestions = try await database.acceptedSuggestions()
        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(storedSuggestions, [])
        XCTAssertEqual(model.vocabularyEntries(), [])
    }

    @MainActor
    func testAttachEnforcesRetentionWithoutPendingConsentEvents()
        async throws
    {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1, forKey: "personalization.retentionDays")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let oldCapture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "",
                selection: UTF16Selection(location: 0, length: 0)
            ),
            insertion: "ExpiredUniqueToken",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date().addingTimeInterval(-2 * 24 * 60 * 60)
        )
        try await database.record(oldCapture)

        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()

        let eventCount = try await database.eventCount()
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(store.storedEventCount, 0)
        XCTAssertEqual(store.vocabularyEntries, [])
    }

    @MainActor
    func testPrepareFailureKeepsDeleteAllAvailable() async throws {
        let suiteName = "cx.mia.stenotab.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        try await database.record(
            AcceptedSuggestionCapture(
                id: UUID(),
                field: CapturedFieldState(
                    text: "",
                    selection: UTF16Selection(location: 0, length: 0)
                ),
                insertion: "UnreadableUniqueToken",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(
                    editorIdentifier: "editor"
                ),
                capturedAt: Date()
            )
        )
        let didCorrupt =
            try await database
            .corruptFirstAcceptedSuggestionPayloadForTesting()
        XCTAssertTrue(didCorrupt)
        let store = PersonalizationSettingsStore(defaults: defaults)
        store.attach(database: database)
        await store.flushPendingPersistence()

        XCTAssertTrue(store.recoveryDeletionIsAvailable)
        XCTAssertNotNil(store.operationError)
        store.deleteAll()
        await store.flushPendingPersistence()

        let eventCount = try await database.eventCount()
        XCTAssertEqual(eventCount, 0)
        XCTAssertFalse(store.recoveryDeletionIsAvailable)
        XCTAssertNil(store.operationError)
    }

    func testVoiceInputsUseReplacementTextAndGlobalChronology()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let context = PersonalizationContext(editorIdentifier: "editor")
        var acceptedIDs: [UUID] = []
        for index in 0..<200 {
            let id = UUID()
            acceptedIDs.append(id)
            let fieldText =
                index == 199 ? "abc🌍def" : "accepted \(index)"
            let selection =
                index == 199
                ? UTF16Selection(location: 3, length: 2)
                : UTF16Selection(
                    location: fieldText.utf16.count,
                    length: 0
                )
            try await database.record(
                AcceptedSuggestionCapture(
                    id: id,
                    field: CapturedFieldState(
                        text: fieldText,
                        selection: selection
                    ),
                    insertion: index == 199 ? "Q" : " old",
                    acceptanceScope: .entireSuggestion,
                    context: context,
                    capturedAt: Date(
                        timeIntervalSince1970: Double(index)
                    )
                )
            )
        }
        let episodeID = UUID()
        let episodeDate = Date(timeIntervalSince1970: 1_000)
        let initialField = CapturedFieldState(
            text: "newest",
            selection: UTF16Selection(location: 6, length: 0)
        )
        let finalField = CapturedFieldState(
            text: "newest writing",
            selection: UTF16Selection(location: 14, length: 0)
        )
        try await database.record(
            WritingEpisodeCapture(
                id: episodeID,
                initialField: initialField,
                finalField: finalField,
                edits: [
                    WritingEditCapture(
                        insertedText: " writing",
                        provenance: .directlyTyped,
                        selectionBefore: initialField.selection,
                        selectionAfter: finalField.selection,
                        fieldBefore: initialField,
                        fieldAfter: finalField,
                        startedAt: episodeDate,
                        endedAt: episodeDate
                    ),
                ],
                context: context,
                startedAt: episodeDate,
                endedAt: episodeDate,
                boundary: .submitted
            )
        )
        let worker = PersonalizationModelWorker(database: database)

        _ = try await worker.prepare()
        let texts = await worker.voiceTextsForTesting()
        let sourceIDs = await worker.voiceSourceIDsForTesting()

        XCTAssertEqual(texts.count, 200)
        XCTAssertTrue(texts.contains("abcQdef"))
        XCTAssertEqual(texts.last, "newest writing")
        XCTAssertTrue(sourceIDs.contains(episodeID))
        XCTAssertFalse(sourceIDs.contains(acceptedIDs[0]))
    }

    func testPrepareReenforcesByteCapAfterDerivedRegeneration()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PersonalizationDatabase(
            databaseURL: directory.appending(
                path: "personalization.sqlite"
            ),
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let capture = AcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "canonical",
                selection: UTF16Selection(location: 9, length: 0)
            ),
            insertion: " history",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date()
        )
        try await database.record(capture)
        let canonicalBytes =
            try await database.storageStatistics().encryptedPayloadBytes
        let worker = PersonalizationModelWorker(database: database)

        _ = try await worker.prepare(
            retentionPolicy: PersonalizationRetentionPolicy(
                maximumAge: nil,
                maximumEncryptedBytes: canonicalBytes
            )
        )

        let finalStatistics = try await database.storageStatistics()
        let remaining = try await database.acceptedSuggestions()
        let storedProjection = try await database.loadLanguageModel()
        XCTAssertLessThanOrEqual(
            finalStatistics.encryptedPayloadBytes,
            canonicalBytes
        )
        XCTAssertEqual(remaining.map(\.id), [capture.id])
        XCTAssertNil(storedProjection)
    }

    private func makeCompletionEpisode(
        context: PersonalizationContext,
        index: Int,
        collectionGeneration: UInt64? = nil,
        date suppliedDate: Date? = nil,
        initialText suppliedInitialText: String? = nil
    ) -> CompletionEpisodeCapture {
        let date =
            suppliedDate
            ?? Date(timeIntervalSince1970: 1_000 + Double(index))
        let id = UUID()
        let initialText =
            suppliedInitialText ?? "quasarUniqueToken input \(index)"
        let finalText = initialText + " generatedUniqueToken\(index)"
        return CompletionEpisodeCapture(
            id: id,
            invocation: CompletionInvocationCapture(
                id: id,
                field: CapturedFieldState(
                    text: initialText,
                    selection: UTF16Selection(
                        location: initialText.utf16.count,
                        length: 0
                    )
                ),
                prompt: CapturedCompletionPrompt(
                    transport: .textCompletion,
                    textPrompt: "My writing:\n§\(initialText)"
                ),
                generation: CompletionGenerationMetadata(
                    providerKind: "test",
                    modelIdentifier: "test-model",
                    maximumTokens: 16,
                    temperature: 0,
                    stopSequences: []
                ),
                context: context,
                collectionGeneration: collectionGeneration,
                startedAt: date
            ),
            suggestionRevisions: [
                CompletionSuggestionRevision(
                    text: " generatedUniqueToken\(index)",
                    isFinal: true,
                    observedAt: date
                )
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
            actualInsertedText: " generatedUniqueToken\(index)",
            endedAt: date
        )
    }
}
