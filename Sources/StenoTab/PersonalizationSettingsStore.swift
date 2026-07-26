import CompletionCore
import Foundation
import NaturalLanguage
import StenoTabPersistence

final class PersonalizationConsentEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64

    init(generation: UInt64 = 0) {
        self.generation = generation
    }

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func advance(to generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.generation = max(self.generation, generation)
    }
}

@MainActor
final class PersonalizationSettingsStore: ObservableObject {
    private enum RecentHistoryKind {
        case acceptedSuggestions
        case completionEpisodes
        case none
        case writingEpisodes
    }

    private enum Keys {
        static let collectionEnabled =
            "personalization.collectionEnabled"
        static let collectDirectTyping =
            "personalization.collectDirectTyping"
        static let useLocalCompletions =
            "personalization.useLocalCompletions"
        static let retentionDays = "personalization.retentionDays"
        static let maximumStorageMegabytes =
            "personalization.maximumStorageMegabytes"
    }

    @Published var collectionEnabled: Bool {
        didSet {
            defaults.set(
                collectionEnabled,
                forKey: Keys.collectionEnabled
            )
            if oldValue, !collectionEnabled {
                collectionConsentGeneration &+= 1
                let consentGeneration = collectionConsentGeneration
                collectionConsentEpoch.advance(to: consentGeneration)
                onHistoryReset?()
            }
        }
    }
    @Published var collectDirectTyping: Bool {
        didSet {
            defaults.set(
                collectDirectTyping,
                forKey: Keys.collectDirectTyping
            )
            if oldValue, !collectDirectTyping {
                collectionConsentGeneration &+= 1
                collectionConsentEpoch.advance(
                    to: collectionConsentGeneration
                )
            }
        }
    }
    @Published var useLocalCompletions: Bool {
        didSet {
            defaults.set(
                useLocalCompletions,
                forKey: Keys.useLocalCompletions
            )
        }
    }
    @Published var retentionDays: Int {
        didSet {
            defaults.set(retentionDays, forKey: Keys.retentionDays)
            enforceRetention()
        }
    }
    @Published var maximumStorageMegabytes: Int {
        didSet {
            defaults.set(
                maximumStorageMegabytes,
                forKey: Keys.maximumStorageMegabytes
            )
            enforceRetention()
        }
    }
    @Published private(set) var storedEventCount = 0
    @Published private(set) var encryptedPayloadBytes = 0
    @Published private(set) var recentEpisodes: [WritingEpisodeCapture] = []
    @Published private(set) var recentAcceptedSuggestions:
        [AcceptedSuggestionCapture] = []
    @Published private(set) var recentCompletionEpisodes:
        [CompletionEpisodeCapture] = []
    @Published private(set) var operationError: String?
    @Published private(set) var languageModel = PersonalLanguageModel()
    @Published private(set) var voiceAssessment: VoiceAssessment?

    var onHistoryReset: (() -> Void)?
    var captureGeneration: UInt64 { collectionGeneration }

    private let defaults: UserDefaults
    private var collectionGeneration: UInt64 = 0
    private var collectionConsentGeneration: UInt64 = 0
    private let collectionConsentEpoch = PersonalizationConsentEpoch()
    private var derivedPersonalizationIsInvalidated = false
    private var completionEpisodeDeleteAllBoundary: Date?
    private var completionEpisodeApplicationDeletionBoundaries:
        [String: Date] = [:]
    private var database: PersonalizationDatabase?
    private var isHistoryInspectorVisible = false
    private var modelWorker: PersonalizationModelWorker?
    private var pendingPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var persistenceTail: Task<Void, Never>?
#if DEBUG
    var promptContextDidLoadForTesting: (() -> Void)?
#endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collectionEnabled = defaults.object(
            forKey: Keys.collectionEnabled
        ) as? Bool ?? true
        collectDirectTyping = defaults.object(
            forKey: Keys.collectDirectTyping
        ) as? Bool ?? true
        useLocalCompletions = defaults.object(
            forKey: Keys.useLocalCompletions
        ) as? Bool ?? true
        retentionDays = defaults.object(
            forKey: Keys.retentionDays
        ) as? Int ?? 365
        maximumStorageMegabytes = defaults.object(
            forKey: Keys.maximumStorageMegabytes
        ) as? Int ?? 100
    }

    func attach(database: PersonalizationDatabase) {
        self.database = database
        let worker = PersonalizationModelWorker(
            database: database,
            collectionConsentEpoch: collectionConsentEpoch
        )
        modelWorker = worker
        let generation = collectionGeneration
        enqueuePersistenceOperation { [self] in
            do {
                let preparedModel = try await worker.prepare()
                let preparedVoiceAssessment =
                    await worker.voiceAssessmentSnapshot()
                let statistics = try await database.storageStatistics()
                guard generation == collectionGeneration else { return }
                languageModel = preparedModel
                voiceAssessment = preparedVoiceAssessment
                storedEventCount = statistics.eventCount
                encryptedPayloadBytes = statistics.encryptedPayloadBytes
                operationError = nil
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func refresh() {
        guard let database else { return }
        let generation = collectionGeneration
        enqueuePersistenceOperation { [self] in
            do {
                let statistics = try await database.storageStatistics()
                let episodes = try await database.writingEpisodes(
                    limit: 20
                )
                let acceptedSuggestions =
                    try await database.acceptedSuggestions(limit: 20)
                let completionEpisodes =
                    try await database.completionEpisodes(limit: 20)
                guard generation == collectionGeneration else { return }
                storedEventCount = statistics.eventCount
                encryptedPayloadBytes =
                    statistics.encryptedPayloadBytes
                recentEpisodes = episodes
                recentAcceptedSuggestions = acceptedSuggestions
                recentCompletionEpisodes = completionEpisodes
                operationError = nil
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func setHistoryInspectorVisible(_ isVisible: Bool) {
        isHistoryInspectorVisible = isVisible
        if isVisible {
            refresh()
        }
    }

    private func refreshAfterRecording(
        _ historyKind: RecentHistoryKind,
        generation: UInt64,
        consentGeneration: UInt64
    ) async throws {
        guard let database else { return }
        let statistics = try await database.storageStatistics()
        let inspectorWasVisible = isHistoryInspectorVisible
        var acceptedSuggestions:
            [AcceptedSuggestionCapture]?
        var completionEpisodes:
            [CompletionEpisodeCapture]?
        var writingEpisodes:
            [WritingEpisodeCapture]?
        guard inspectorWasVisible else {
            guard
                generation == collectionGeneration,
                collectionEnabled,
                consentGeneration == collectionConsentGeneration,
                !derivedPersonalizationIsInvalidated
            else {
                return
            }
            storedEventCount = statistics.eventCount
            encryptedPayloadBytes = statistics.encryptedPayloadBytes
            operationError = nil
            return
        }
        switch historyKind {
        case .acceptedSuggestions:
            acceptedSuggestions =
                try await database.acceptedSuggestions(limit: 20)
        case .completionEpisodes:
            completionEpisodes =
                try await database.completionEpisodes(limit: 20)
        case .none:
            break
        case .writingEpisodes:
            writingEpisodes =
                try await database.writingEpisodes(limit: 20)
        }
        guard
            generation == collectionGeneration,
            collectionEnabled,
            consentGeneration == collectionConsentGeneration,
            !derivedPersonalizationIsInvalidated
        else {
            return
        }
        storedEventCount = statistics.eventCount
        encryptedPayloadBytes = statistics.encryptedPayloadBytes
        if let acceptedSuggestions {
            recentAcceptedSuggestions = acceptedSuggestions
        }
        if let completionEpisodes {
            recentCompletionEpisodes = completionEpisodes
        }
        if let writingEpisodes {
            recentEpisodes = writingEpisodes
        }
        operationError = nil
    }

    func deleteAll() {
        guard let modelWorker else { return }
        invalidateDerivedPersonalization()
        let previousBoundary = completionEpisodeDeleteAllBoundary
        let attemptedBoundary = Date()
        completionEpisodeDeleteAllBoundary = attemptedBoundary
        collectionGeneration &+= 1
        let generation = collectionGeneration
        enqueuePersistenceOperation { [self] in
            do {
                let rebuiltModel = try await modelWorker.deleteAll(
                    generation: generation
                )
                guard generation == collectionGeneration else { return }
                languageModel = rebuiltModel
                voiceAssessment = nil
                storedEventCount = 0
                encryptedPayloadBytes = 0
                recentEpisodes = []
                recentAcceptedSuggestions = []
                recentCompletionEpisodes = []
                finishDerivedPersonalizationInvalidation(
                    generation: generation
                )
                operationError = nil
            } catch {
                if
                    completionEpisodeDeleteAllBoundary == attemptedBoundary
                {
                    completionEpisodeDeleteAllBoundary = previousBoundary
                }
                await recoverAfterFailedDestructiveOperation(
                    error,
                    generation: generation,
                    modelWorker: modelWorker
                )
            }
        }
    }

    func record(_ capture: AcceptedSuggestionCapture) {
        guard collectionEnabled, let modelWorker else { return }
        let policy = retentionPolicy
        let generation = collectionGeneration
        let consentGeneration = collectionConsentGeneration
        enqueuePersistenceOperation { [self] in
            guard
                collectionEnabled,
                generation == collectionGeneration,
                consentGeneration == collectionConsentGeneration,
                !derivedPersonalizationIsInvalidated
            else {
                return
            }
            do {
                let updatedModel = try await modelWorker.record(
                    capture,
                    retentionPolicy: policy,
                    generation: generation,
                    consentGeneration: consentGeneration
                )
                let updatedVoiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
                guard
                    generation == collectionGeneration,
                    collectionEnabled,
                    consentGeneration == collectionConsentGeneration,
                    !derivedPersonalizationIsInvalidated
                else {
                    return
                }
                languageModel = updatedModel
                voiceAssessment = updatedVoiceAssessment
                try await refreshAfterRecording(
                    .acceptedSuggestions,
                    generation: generation,
                    consentGeneration: consentGeneration
                )
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func record(_ episode: WritingEpisodeCapture) {
        guard
            collectionEnabled,
            collectDirectTyping,
            let modelWorker
        else {
            return
        }
        let policy = retentionPolicy
        let generation = collectionGeneration
        let consentGeneration = collectionConsentGeneration
        enqueuePersistenceOperation { [self] in
            guard
                collectionEnabled,
                collectDirectTyping,
                generation == collectionGeneration,
                consentGeneration == collectionConsentGeneration,
                !derivedPersonalizationIsInvalidated
            else {
                return
            }
            do {
                let updatedModel = try await modelWorker.record(
                    episode,
                    retentionPolicy: policy,
                    generation: generation,
                    consentGeneration: consentGeneration
                )
                let updatedVoiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
                guard
                    generation == collectionGeneration,
                    collectionEnabled,
                    consentGeneration == collectionConsentGeneration,
                    !derivedPersonalizationIsInvalidated
                else {
                    return
                }
                languageModel = updatedModel
                voiceAssessment = updatedVoiceAssessment
                try await refreshAfterRecording(
                    .writingEpisodes,
                    generation: generation,
                    consentGeneration: consentGeneration
                )
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func record(_ feedback: CompletionFeedbackCapture) {
        guard collectionEnabled, let modelWorker else { return }
        let policy = retentionPolicy
        let generation = collectionGeneration
        let consentGeneration = collectionConsentGeneration
        enqueuePersistenceOperation { [self] in
            guard
                collectionEnabled,
                generation == collectionGeneration,
                consentGeneration == collectionConsentGeneration,
                !derivedPersonalizationIsInvalidated
            else {
                return
            }
            do {
                let updatedModel = try await modelWorker.record(
                    feedback,
                    retentionPolicy: policy,
                    generation: generation,
                    consentGeneration: consentGeneration
                )
                guard
                    generation == collectionGeneration,
                    collectionEnabled,
                    consentGeneration == collectionConsentGeneration,
                    !derivedPersonalizationIsInvalidated
                else {
                    return
                }
                languageModel = updatedModel
                try await refreshAfterRecording(
                    .none,
                    generation: generation,
                    consentGeneration: consentGeneration
                )
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func record(_ episode: CompletionEpisodeCapture) {
        guard collectionEnabled, let modelWorker else { return }
        if let invocationGeneration =
            episode.invocation.collectionGeneration
        {
            guard invocationGeneration == collectionGeneration else { return }
        } else {
            let applicationDeletedAt =
                episode.invocation.context.applicationBundleIdentifier
                    .flatMap {
                        completionEpisodeApplicationDeletionBoundaries[$0]
                    }
            guard CompletionEpisodeDeletionBoundaryPolicy.allowsCapture(
                invocationStartedAt: episode.invocation.startedAt,
                deleteAllAt: completionEpisodeDeleteAllBoundary,
                applicationDeletedAt: applicationDeletedAt
            ) else {
                return
            }
        }
        let policy = retentionPolicy
        let generation = collectionGeneration
        let consentGeneration = collectionConsentGeneration
        enqueuePersistenceOperation { [self] in
            guard
                collectionEnabled,
                generation == collectionGeneration,
                consentGeneration == collectionConsentGeneration,
                !derivedPersonalizationIsInvalidated
            else {
                return
            }
            do {
                let updatedModel = try await modelWorker.record(
                    episode,
                    retentionPolicy: policy,
                    generation: generation,
                    consentGeneration: consentGeneration
                )
                guard
                    generation == collectionGeneration,
                    collectionEnabled,
                    consentGeneration == collectionConsentGeneration,
                    !derivedPersonalizationIsInvalidated
                else {
                    return
                }
                languageModel = updatedModel
                try await refreshAfterRecording(
                    .completionEpisodes,
                    generation: generation,
                    consentGeneration: consentGeneration
                )
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func flushPendingPersistence() async {
        while !pendingPersistenceTasks.isEmpty {
            let tasks = Array(pendingPersistenceTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    private func enqueuePersistenceOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let id = UUID()
        let predecessor = persistenceTail
        let task = Task { [weak self] in
            await predecessor?.value
            await operation()
            self?.pendingPersistenceTasks.removeValue(forKey: id)
        }
        pendingPersistenceTasks[id] = task
        persistenceTail = task
    }

    func deleteEvent(id: UUID) {
        guard let modelWorker else { return }
        invalidateDerivedPersonalization()
        collectionGeneration &+= 1
        let generation = collectionGeneration
        enqueuePersistenceOperation { [self] in
            do {
                let rebuiltModel = try await modelWorker.deleteEvent(
                    id: id,
                    generation: generation
                )
                let rebuiltVoiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
                guard generation == collectionGeneration else { return }
                languageModel = rebuiltModel
                voiceAssessment = rebuiltVoiceAssessment
                finishDerivedPersonalizationInvalidation(
                    generation: generation
                )
                refresh()
            } catch {
                await recoverAfterFailedDestructiveOperation(
                    error,
                    generation: generation,
                    modelWorker: modelWorker
                )
            }
        }
    }

    func deleteApplicationHistory(bundleIdentifier: String) {
        guard let modelWorker else { return }
        invalidateDerivedPersonalization()
        let previousBoundary =
            completionEpisodeApplicationDeletionBoundaries[bundleIdentifier]
        let attemptedBoundary = Date()
        completionEpisodeApplicationDeletionBoundaries[bundleIdentifier] =
            attemptedBoundary
        collectionGeneration &+= 1
        let generation = collectionGeneration
        enqueuePersistenceOperation { [self] in
            do {
                let rebuiltModel = try await modelWorker.deleteEvents(
                    scopeKind: "application",
                    value: bundleIdentifier,
                    generation: generation
                )
                let rebuiltVoiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
                guard generation == collectionGeneration else { return }
                languageModel = rebuiltModel
                voiceAssessment = rebuiltVoiceAssessment
                finishDerivedPersonalizationInvalidation(
                    generation: generation
                )
                refresh()
            } catch {
                if
                    completionEpisodeApplicationDeletionBoundaries[
                        bundleIdentifier
                    ] == attemptedBoundary
                {
                    completionEpisodeApplicationDeletionBoundaries[
                        bundleIdentifier
                    ] = previousBoundary
                }
                await recoverAfterFailedDestructiveOperation(
                    error,
                    generation: generation,
                    modelWorker: modelWorker
                )
            }
        }
    }

    func exportData() async throws -> Data {
        guard let database else {
            throw PersonalizationPersistenceError.database(
                "Personalization database is unavailable"
            )
        }
        let export = try await database.exportCorpus()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    var retentionPolicy: PersonalizationRetentionPolicy {
        PersonalizationRetentionPolicy(
            maximumAge: retentionDays > 0
                ? TimeInterval(retentionDays * 24 * 60 * 60)
                : nil,
            maximumEncryptedBytes: maximumStorageMegabytes > 0
                ? maximumStorageMegabytes * 1_024 * 1_024
                : nil
        )
    }

    func enforceRetention() {
        guard let modelWorker else { return }
        invalidateDerivedPersonalization()
        collectionGeneration &+= 1
        let generation = collectionGeneration
        let policy = retentionPolicy
        enqueuePersistenceOperation { [self] in
            do {
                let rebuiltModel = try await modelWorker.enforceRetention(
                    policy,
                    generation: generation
                )
                let rebuiltVoiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
                guard generation == collectionGeneration else { return }
                languageModel = rebuiltModel
                voiceAssessment = rebuiltVoiceAssessment
                finishDerivedPersonalizationInvalidation(
                    generation: generation
                )
                refresh()
            } catch {
                await recoverAfterFailedDestructiveOperation(
                    error,
                    generation: generation,
                    modelWorker: modelWorker
                )
            }
        }
    }

    private func invalidateDerivedPersonalization() {
        derivedPersonalizationIsInvalidated = true
        languageModel = PersonalLanguageModel()
        voiceAssessment = nil
        onHistoryReset?()
    }

    private func finishDerivedPersonalizationInvalidation(
        generation: UInt64
    ) {
        guard generation == collectionGeneration else { return }
        derivedPersonalizationIsInvalidated = false
    }

    private func recoverAfterFailedDestructiveOperation(
        _ originalError: Error,
        generation: UInt64,
        modelWorker: PersonalizationModelWorker
    ) async {
        let originalErrorDescription = String(describing: originalError)
        guard generation == collectionGeneration else {
            operationError = originalErrorDescription
            return
        }
        do {
            let recoveredModel = try await modelWorker.prepare()
            let recoveredVoiceAssessment =
                await modelWorker.voiceAssessmentSnapshot()
            let recoveredStatistics: PersonalizationStorageStatistics? =
                if let database {
                    try await database.storageStatistics()
                } else {
                    nil
                }
            guard generation == collectionGeneration else {
                operationError = originalErrorDescription
                return
            }
            languageModel = recoveredModel
            voiceAssessment = recoveredVoiceAssessment
            if let recoveredStatistics {
                storedEventCount = recoveredStatistics.eventCount
                encryptedPayloadBytes =
                    recoveredStatistics.encryptedPayloadBytes
            }
            finishDerivedPersonalizationInvalidation(
                generation: generation
            )
            operationError = originalErrorDescription
        } catch {
            operationError =
                originalErrorDescription
                + "; recovery failed: "
                + String(describing: error)
        }
    }

    func report(error: Error) {
        operationError = String(describing: error)
    }

    func reassessVoice() {
        guard
            !derivedPersonalizationIsInvalidated,
            let modelWorker
        else {
            return
        }
        let generation = collectionGeneration
        enqueuePersistenceOperation { [self] in
            do {
                let assessment = try await modelWorker.reassessVoice()
                guard
                    generation == collectionGeneration,
                    !derivedPersonalizationIsInvalidated
                else {
                    return
                }
                voiceAssessment = assessment
                operationError = nil
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func personalCompletion(
        for prefix: String,
        context: PersonalizationContext
    ) -> PersonalCompletion? {
        guard
            useLocalCompletions,
            !derivedPersonalizationIsInvalidated
        else {
            return nil
        }
        return languageModel.completion(for: prefix, context: context)
    }

    var vocabularyEntries: [PersonalVocabularyEntry] {
        guard !derivedPersonalizationIsInvalidated else { return [] }
        return languageModel.vocabularyEntries(limit: 30)
    }

    func promptContext(
        for prefix: String,
        context: PersonalizationContext
    ) async -> PersonalizationPromptContext {
        guard
            collectionEnabled,
            !derivedPersonalizationIsInvalidated,
            let modelWorker
        else {
            return .empty
        }
        let generation = collectionGeneration
        do {
            let promptContext = try await modelWorker.promptContext(
                for: prefix,
                context: context
            )
#if DEBUG
            let didLoad = promptContextDidLoadForTesting
            promptContextDidLoadForTesting = nil
            didLoad?()
#endif
            guard
                collectionEnabled,
                generation == collectionGeneration,
                !derivedPersonalizationIsInvalidated
            else {
                return .empty
            }
            return promptContext
        } catch {
            operationError = String(describing: error)
            return .empty
        }
    }
}

actor PersonalizationModelWorker {
    private struct EmbeddedText {
        let modelIdentifier: String
        let vector: [Double]
    }

    private struct VoiceSource {
        let id: UUID
        let context: PersonalizationContext
    }

    private let database: PersonalizationDatabase
    private var model = PersonalLanguageModel()
    private var examples: [PersonalizationExample] = []
    private var semanticExamples: [PersonalizationExample] = []
    private var embeddings: [UUID: StoredPersonalizationEmbedding] = [:]
    private var voiceAssessment: VoiceAssessment?
    private var voiceTexts: [String] = []
    private var voiceSourceEventCount = 0
    private var voiceSources: [VoiceSource] = []
    private var collectionGeneration: UInt64 = 0
    private let collectionConsentEpoch: PersonalizationConsentEpoch
    private var collectionOperationIsRunning = false
    private var collectionOperationWaiters:
        [CheckedContinuation<Void, Never>] = []
#if DEBUG
    private var recordDidPersistForTesting: (@Sendable () -> Void)?
#endif

    init(
        database: PersonalizationDatabase,
        collectionConsentEpoch: PersonalizationConsentEpoch =
            PersonalizationConsentEpoch()
    ) {
        self.database = database
        self.collectionConsentEpoch = collectionConsentEpoch
    }

    func prepare() async throws -> PersonalLanguageModel {
        if let stored = try await database.loadLanguageModel(),
           !stored.requiresRebuild {
            model = stored
        } else {
            _ = try await rebuildLanguageModel()
        }
        voiceAssessment = try await database.loadVoiceAssessment()
        try await reloadRetrievalIndex()
        try await updateVoiceAssessmentIfNeeded()
        return model
    }

#if DEBUG
    func setRecordDidPersistForTesting(
        _ callback: @escaping @Sendable () -> Void
    ) {
        recordDidPersistForTesting = callback
    }
#endif

    func record(
        _ capture: AcceptedSuggestionCapture,
        retentionPolicy: PersonalizationRetentionPolicy,
        generation: UInt64,
        consentGeneration: UInt64 = 0
    ) async throws -> PersonalLanguageModel {
        await acquireCollectionOperation()
        defer { releaseCollectionOperation() }
        guard
            generation == collectionGeneration,
            consentGeneration == collectionConsentEpoch.current
        else {
            return model
        }
        try await database.record(capture)
#if DEBUG
        let didPersist = recordDidPersistForTesting
        recordDidPersistForTesting = nil
        didPersist?()
#endif
        if let revokedModel = try await removeRecordIfConsentRevoked(
            id: capture.id,
            consentGeneration: consentGeneration
        ) {
            return revokedModel
        }
        model.ingest(capture)
        try await database.saveLanguageModel(model)
        let example = PersonalizationExample(capture)
        examples.append(example)
        semanticExamples.append(example)
        try await embedIfNeeded(example)
        voiceTexts.append(capture.field.text + capture.insertion)
        voiceSourceEventCount += 1
        appendVoiceSource(id: capture.id, context: capture.context)
        try await updateVoiceAssessmentIfNeeded()
        let removed = try await database.enforceRetention(retentionPolicy)
        if removed > 0 {
            _ = try await rebuild()
        }
        return model
    }

    func record(
        _ episode: WritingEpisodeCapture,
        retentionPolicy: PersonalizationRetentionPolicy,
        generation: UInt64,
        consentGeneration: UInt64 = 0
    ) async throws -> PersonalLanguageModel {
        await acquireCollectionOperation()
        defer { releaseCollectionOperation() }
        guard
            generation == collectionGeneration,
            consentGeneration == collectionConsentEpoch.current
        else {
            return model
        }
        try await database.record(episode)
#if DEBUG
        let didPersist = recordDidPersistForTesting
        recordDidPersistForTesting = nil
        didPersist?()
#endif
        if let revokedModel = try await removeRecordIfConsentRevoked(
            id: episode.id,
            consentGeneration: consentGeneration
        ) {
            return revokedModel
        }
        model.ingest(episode)
        try await database.saveLanguageModel(model)
        let removed = try await database.enforceRetention(retentionPolicy)
        if removed > 0 {
            _ = try await rebuild()
            return model
        }
        examples.append(
            contentsOf: PersonalizationExample.directlyTyped(from: episode)
        )
        voiceTexts.append(episode.finalField.text)
        voiceSourceEventCount += 1
        appendVoiceSource(id: episode.id, context: episode.context)
        try await updateVoiceAssessmentIfNeeded()
        return model
    }

    func record(
        _ feedback: CompletionFeedbackCapture,
        retentionPolicy: PersonalizationRetentionPolicy,
        generation: UInt64,
        consentGeneration: UInt64 = 0
    ) async throws -> PersonalLanguageModel {
        await acquireCollectionOperation()
        defer { releaseCollectionOperation() }
        guard
            generation == collectionGeneration,
            consentGeneration == collectionConsentEpoch.current
        else {
            return model
        }
        try await database.record(feedback)
        if let revokedModel = try await removeRecordIfConsentRevoked(
            id: feedback.id,
            consentGeneration: consentGeneration
        ) {
            return revokedModel
        }
        model.ingest(feedback)
        try await database.saveLanguageModel(model)
        let removed = try await database.enforceRetention(retentionPolicy)
        if removed > 0 {
            _ = try await rebuild()
        }
        return model
    }

    func record(
        _ episode: CompletionEpisodeCapture,
        retentionPolicy: PersonalizationRetentionPolicy,
        generation: UInt64,
        consentGeneration: UInt64 = 0
    ) async throws -> PersonalLanguageModel {
        await acquireCollectionOperation()
        defer { releaseCollectionOperation() }
        guard
            generation == collectionGeneration,
            consentGeneration == collectionConsentEpoch.current
        else {
            return model
        }
        try await database.record(episode)
        if let revokedModel = try await removeRecordIfConsentRevoked(
            id: episode.id,
            consentGeneration: consentGeneration
        ) {
            return revokedModel
        }
        let removed = try await database.enforceRetention(retentionPolicy)
        if removed > 0 {
            _ = try await rebuild()
        }
        return model
    }

    private func removeRecordIfConsentRevoked(
        id: UUID,
        consentGeneration: UInt64
    ) async throws -> PersonalLanguageModel? {
        guard consentGeneration != collectionConsentEpoch.current else {
            return nil
        }
        try await database.deleteEvent(id: id)
        return try await rebuild()
    }

    func deleteEvent(
        id: UUID,
        generation: UInt64
    ) async throws -> PersonalLanguageModel {
        await acquireCollectionOperation()
        defer { releaseCollectionOperation() }
        collectionGeneration = max(collectionGeneration, generation)
        try await database.deleteEvent(id: id)
        return try await rebuild()
    }

    func deleteEvents(
        scopeKind: String,
        value: String,
        generation: UInt64
    ) async throws -> PersonalLanguageModel {
        await acquireCollectionOperation()
        defer { releaseCollectionOperation() }
        collectionGeneration = max(collectionGeneration, generation)
        _ = try await database.deleteEvents(
            scopeKind: scopeKind,
            value: value
        )
        return try await rebuild()
    }

    func enforceRetention(
        _ policy: PersonalizationRetentionPolicy,
        generation: UInt64
    ) async throws -> PersonalLanguageModel {
        await acquireCollectionOperation()
        defer { releaseCollectionOperation() }
        collectionGeneration = max(collectionGeneration, generation)
        let removed = try await database.enforceRetention(policy)
        return removed > 0 ? try await rebuild() : model
    }

    func deleteAll(generation: UInt64) async throws -> PersonalLanguageModel {
        await acquireCollectionOperation()
        defer { releaseCollectionOperation() }
        collectionGeneration = max(collectionGeneration, generation)
        try await database.deleteAll()
        model = PersonalLanguageModel()
        examples = []
        semanticExamples = []
        embeddings = [:]
        voiceTexts = []
        voiceSourceEventCount = 0
        voiceSources = []
        voiceAssessment = nil
        return model
    }

    private func acquireCollectionOperation() async {
        guard collectionOperationIsRunning else {
            collectionOperationIsRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            collectionOperationWaiters.append(continuation)
        }
    }

    private func releaseCollectionOperation() {
        guard !collectionOperationWaiters.isEmpty else {
            collectionOperationIsRunning = false
            return
        }
        collectionOperationWaiters.removeFirst().resume()
    }

    func voiceAssessmentSnapshot() -> VoiceAssessment? {
        voiceAssessment
    }

    func reassessVoice() async throws -> VoiceAssessment? {
        try await updateVoiceAssessmentIfNeeded(force: true)
        return voiceAssessment
    }

    func promptContext(
        for prefix: String,
        context: PersonalizationContext
    ) async throws -> PersonalizationPromptContext {
        let frecent = FrecentExampleRetriever.retrieve(
            from: examples,
            context: context,
            limit: 5
        )
        guard let query = embedding(for: prefix) else {
            return PersonalizationPromptContext(
                frecentExamples:
                    PersonalizationExample.promptValue(from: frecent),
                frecentSourceEventIDs: sourceEventIDs(from: frecent),
                frecentSourceContexts: sourceContexts(from: frecent),
                frecentRecordCharacterCounts:
                    frecent.map { $0.promptText.count }
            )
        }
        let candidateVectors = Dictionary(
            uniqueKeysWithValues: embeddings.compactMap {
                eventID, stored -> (UUID, [Double])? in
                guard stored.modelIdentifier == query.modelIdentifier else {
                    return nil
                }
                return (eventID, stored.vector)
            }
        )
        let frecentIDs = Set(frecent.map(\.id))
        let relevant = SemanticExampleRetriever.retrieve(
            from: semanticExamples.filter {
                !frecentIDs.contains($0.id)
            },
            vectors: candidateVectors,
            queryVector: query.vector,
            context: context,
            limit: 5,
            minimumSimilarity: 0.25
        )
        return PersonalizationPromptContext(
            frecentExamples: PersonalizationExample.promptValue(
                from: frecent
            ),
            relevantExamples: PersonalizationExample.promptValue(
                from: relevant
            ),
            voiceAssessment: voiceAssessment?.summary,
            frecentSourceEventIDs: sourceEventIDs(from: frecent),
            frecentSourceContexts: sourceContexts(from: frecent),
            frecentRecordCharacterCounts:
                frecent.map { $0.promptText.count },
            relevantSourceEventIDs: sourceEventIDs(from: relevant),
            relevantSourceContexts: sourceContexts(from: relevant),
            relevantRecordCharacterCounts:
                relevant.map { $0.promptText.count },
            voiceSourceEventIDs: voiceAssessment?.sourceEventIDs ?? [],
            voiceSourceContexts: voiceAssessment?.sourceContexts ?? []
        )
    }

    private func appendVoiceSource(
        id: UUID,
        context: PersonalizationContext
    ) {
        voiceSources.append(VoiceSource(id: id, context: context))
        let excess = max(0, voiceSources.count - 200)
        if excess > 0 {
            voiceSources.removeFirst(excess)
            voiceTexts.removeFirst(excess)
        }
    }

    private func sourceEventIDs(
        from examples: [PersonalizationExample]
    ) -> [UUID] {
        examples.map { example in
            example.sourceEventID ?? example.id
        }
    }

    private func sourceContexts(
        from examples: [PersonalizationExample]
    ) -> [PersonalizationContext] {
        examples.map(\.context)
    }

    private func rebuild() async throws -> PersonalLanguageModel {
        _ = try await rebuildLanguageModel()
        try await reloadRetrievalIndex()
        try await updateVoiceAssessmentIfNeeded(force: true)
        return model
    }

    private func rebuildLanguageModel() async throws
        -> PersonalLanguageModel
    {
        var rebuilt = PersonalLanguageModel()
        for episode in try await database.writingEpisodes() {
            rebuilt.ingest(episode)
        }
        for capture in try await database.acceptedSuggestions() {
            rebuilt.ingest(capture)
        }
        for feedback in try await database.completionFeedback() {
            rebuilt.ingest(feedback)
        }
        model = rebuilt
        try await database.saveLanguageModel(model)
        return model
    }

    private func reloadRetrievalIndex() async throws {
        let accepted = try await database.acceptedSuggestions()
        let episodes = try await database.writingEpisodes()
        semanticExamples = accepted.map(PersonalizationExample.init)
        examples = semanticExamples
            + episodes.flatMap(PersonalizationExample.directlyTyped)
        embeddings = Dictionary(
            uniqueKeysWithValues: try await database.embeddings().map {
                ($0.eventID, $0)
            }
        )
        for example in semanticExamples {
            try await embedIfNeeded(example)
        }
        let voiceInputs =
            episodes.map {
                (
                    text: $0.finalField.text,
                    id: $0.id,
                    context: $0.context
                )
            }
            + accepted.map {
                (
                    text: $0.field.text + $0.insertion,
                    id: $0.id,
                    context: $0.context
                )
            }
        let recentVoiceInputs = Array(voiceInputs.suffix(200))
        voiceTexts = recentVoiceInputs.map(\.text)
        voiceSources = recentVoiceInputs.map {
            VoiceSource(id: $0.id, context: $0.context)
        }
        voiceSourceEventCount = episodes.count + accepted.count
    }

    private func embedIfNeeded(
        _ example: PersonalizationExample
    ) async throws {
        guard embeddings[example.id] == nil else { return }
        guard let embedded = embedding(for: example.inputText) else {
            return
        }
        let stored = StoredPersonalizationEmbedding(
            eventID: example.id,
            modelIdentifier: embedded.modelIdentifier,
            vector: embedded.vector,
            createdAt: Date()
        )
        try await database.saveEmbedding(
            eventID: stored.eventID,
            modelIdentifier: stored.modelIdentifier,
            vector: stored.vector,
            at: stored.createdAt
        )
        embeddings[example.id] = stored
    }

    private func embedding(for text: String) -> EmbeddedText? {
        let source = String(text.suffix(1_500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let language =
            NLLanguageRecognizer.dominantLanguage(for: source) ?? .english
        guard
            let sentenceEmbedding =
                NLEmbedding.sentenceEmbedding(for: language)
                    ?? NLEmbedding.sentenceEmbedding(for: .english),
            let vector = sentenceEmbedding.vector(for: source),
            !vector.isEmpty
        else {
            return nil
        }
        return EmbeddedText(
            modelIdentifier:
                "apple-natural-language:\(language.rawValue):"
                + "\(sentenceEmbedding.dimension)",
            vector: vector
        )
    }

    private func updateVoiceAssessmentIfNeeded(
        force: Bool = false
    ) async throws {
        let sourceEventCount = voiceSourceEventCount
        if sourceEventCount < 10 {
            if voiceAssessment != nil {
                voiceAssessment = nil
                try await database.deleteVoiceAssessment()
            }
            return
        }
        let assessmentNeedsLineageRefresh =
            voiceAssessment.map {
                $0.sourceEventIDs.isEmpty || $0.sourceContexts.isEmpty
            } ?? false
        guard
            force
                || assessmentNeedsLineageRefresh
                || VoiceAssessmentSchedule.shouldAssess(
                    existing: voiceAssessment,
                    sourceEventCount: sourceEventCount
                )
        else {
            return
        }
        guard
            let updated = VoiceAssessmentAnalyzer.assess(
                texts: voiceTexts,
                sourceEventCount: sourceEventCount,
                sourceEventIDs: voiceSources.reduce(into: []) {
                    result, source in
                    if !result.contains(source.id) {
                        result.append(source.id)
                    }
                },
                sourceContexts: voiceSources.reduce(into: []) {
                    result, source in
                    if !result.contains(source.context) {
                        result.append(source.context)
                    }
                }
            )
        else {
            voiceAssessment = nil
            try await database.deleteVoiceAssessment()
            return
        }
        voiceAssessment = updated
        try await database.saveVoiceAssessment(updated)
    }
}
