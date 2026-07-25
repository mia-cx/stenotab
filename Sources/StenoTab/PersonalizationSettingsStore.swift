import CompletionCore
import Foundation
import StenoTabPersistence

@MainActor
final class PersonalizationSettingsStore: ObservableObject {
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
        }
    }
    @Published var collectDirectTyping: Bool {
        didSet {
            defaults.set(
                collectDirectTyping,
                forKey: Keys.collectDirectTyping
            )
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
    @Published private(set) var operationError: String?
    @Published private(set) var languageModel = PersonalLanguageModel()

    private let defaults: UserDefaults
    private var database: PersonalizationDatabase?
    private var modelWorker: PersonalizationModelWorker?

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
        let worker = PersonalizationModelWorker(database: database)
        modelWorker = worker
        Task {
            do {
                languageModel = try await worker.prepare()
                refresh()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func refresh() {
        guard let database else { return }
        Task {
            do {
                let statistics = try await database.storageStatistics()
                storedEventCount = statistics.eventCount
                encryptedPayloadBytes =
                    statistics.encryptedPayloadBytes
                recentEpisodes = try await database.writingEpisodes(
                    limit: 20
                )
                operationError = nil
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func deleteAll() {
        guard let modelWorker else { return }
        Task {
            do {
                languageModel = try await modelWorker.deleteAll()
                storedEventCount = 0
                encryptedPayloadBytes = 0
                recentEpisodes = []
                operationError = nil
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func didRecordEvent() {
        storedEventCount += 1
    }

    func record(_ capture: AcceptedSuggestionCapture) {
        guard collectionEnabled, let modelWorker else { return }
        Task {
            do {
                languageModel = try await modelWorker.record(capture)
                didRecordEvent()
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
        Task {
            do {
                languageModel = try await modelWorker.record(
                    episode,
                    retentionPolicy: policy
                )
                refresh()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func record(_ feedback: CompletionFeedbackCapture) {
        guard collectionEnabled, let modelWorker else { return }
        Task {
            do {
                languageModel = try await modelWorker.record(feedback)
                didRecordEvent()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func deleteEvent(id: UUID) {
        guard let modelWorker else { return }
        Task {
            do {
                languageModel = try await modelWorker.deleteEvent(id: id)
                refresh()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func deleteApplicationHistory(bundleIdentifier: String) {
        guard let modelWorker else { return }
        Task {
            do {
                languageModel = try await modelWorker.deleteEvents(
                    scopeKind: "application",
                    value: bundleIdentifier
                )
                refresh()
            } catch {
                operationError = String(describing: error)
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
        let policy = retentionPolicy
        Task {
            do {
                languageModel = try await modelWorker.enforceRetention(
                    policy
                )
                refresh()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func report(error: Error) {
        operationError = String(describing: error)
    }

    func personalCompletion(
        for prefix: String,
        context: PersonalizationContext
    ) -> PersonalCompletion? {
        guard useLocalCompletions else { return nil }
        return languageModel.completion(for: prefix, context: context)
    }
}

private actor PersonalizationModelWorker {
    private let database: PersonalizationDatabase
    private var model = PersonalLanguageModel()

    init(database: PersonalizationDatabase) {
        self.database = database
    }

    func prepare() async throws -> PersonalLanguageModel {
        if let stored = try await database.loadLanguageModel() {
            model = stored
            return model
        }
        return try await rebuild()
    }

    func record(
        _ capture: AcceptedSuggestionCapture
    ) async throws -> PersonalLanguageModel {
        try await database.record(capture)
        model.ingest(capture)
        try await database.saveLanguageModel(model)
        return model
    }

    func record(
        _ episode: WritingEpisodeCapture,
        retentionPolicy: PersonalizationRetentionPolicy
    ) async throws -> PersonalLanguageModel {
        try await database.record(episode)
        model.ingest(episode)
        try await database.saveLanguageModel(model)
        let removed = try await database.enforceRetention(retentionPolicy)
        if removed > 0 {
            return try await rebuild()
        }
        return model
    }

    func record(
        _ feedback: CompletionFeedbackCapture
    ) async throws -> PersonalLanguageModel {
        try await database.record(feedback)
        model.ingest(feedback)
        try await database.saveLanguageModel(model)
        return model
    }

    func deleteEvent(id: UUID) async throws -> PersonalLanguageModel {
        try await database.deleteEvent(id: id)
        return try await rebuild()
    }

    func deleteEvents(
        scopeKind: String,
        value: String
    ) async throws -> PersonalLanguageModel {
        _ = try await database.deleteEvents(
            scopeKind: scopeKind,
            value: value
        )
        return try await rebuild()
    }

    func enforceRetention(
        _ policy: PersonalizationRetentionPolicy
    ) async throws -> PersonalLanguageModel {
        let removed = try await database.enforceRetention(policy)
        return removed > 0 ? try await rebuild() : model
    }

    func deleteAll() async throws -> PersonalLanguageModel {
        try await database.deleteAll()
        model = PersonalLanguageModel()
        return model
    }

    private func rebuild() async throws -> PersonalLanguageModel {
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
}
