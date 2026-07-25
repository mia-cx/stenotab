import CompletionCore
import Foundation
import StenoTabPersistence
@testable import StenoTab
import XCTest

final class PersonalizationIntegrationTests: XCTestCase {
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
    func testClearingSuggestionDiscardsUnobservedPendingOutcome() {
        let expected = CapturedFieldState(
            text: "before after",
            selection: UTF16Selection(location: 12, length: 0)
        )

        XCTAssertTrue(
            CompletionCoordinator.shouldDiscardPendingOutcomeBeforeClearing(
                pendingResolution: .accepted,
                expectedField: expected
            )
        )
        XCTAssertFalse(
            CompletionCoordinator.shouldDiscardPendingOutcomeBeforeClearing(
                pendingResolution: nil,
                expectedField: expected
            )
        )
        XCTAssertFalse(
            CompletionCoordinator.shouldDiscardPendingOutcomeBeforeClearing(
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
        let episode = makeCompletionEpisode(
            context: PersonalizationContext(editorIdentifier: "editor"),
            index: 0,
            collectionGeneration: store.captureGeneration,
            date: Date(timeIntervalSinceNow: 24 * 60 * 60)
        )

        store.deleteAll()
        await store.flushPendingPersistence()
        store.record(episode)
        await store.flushPendingPersistence()

        let storedEpisodes = try await database.completionEpisodes()
        XCTAssertEqual(storedEpisodes, [])
    }

    private func makeCompletionEpisode(
        context: PersonalizationContext,
        index: Int,
        collectionGeneration: UInt64? = nil,
        date suppliedDate: Date? = nil
    ) -> CompletionEpisodeCapture {
        let date =
            suppliedDate
            ?? Date(timeIntervalSince1970: 1_000 + Double(index))
        let id = UUID()
        let initialText = "quasarUniqueToken input \(index)"
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
