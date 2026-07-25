import CompletionCore
import Foundation
import NaturalLanguage
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

    func promptContext(
        for prefix: String,
        context: PersonalizationContext
    ) async -> PersonalizationPromptContext {
        guard collectionEnabled, let modelWorker else { return .empty }
        do {
            return try await modelWorker.promptContext(
                for: prefix,
                context: context
            )
        } catch {
            operationError = String(describing: error)
            return .empty
        }
    }
}

private actor PersonalizationModelWorker {
    private struct EmbeddedText {
        let modelIdentifier: String
        let vector: [Double]
    }

    private let database: PersonalizationDatabase
    private var model = PersonalLanguageModel()
    private var examples: [PersonalizationExample] = []
    private var semanticExamples: [PersonalizationExample] = []
    private var embeddings: [UUID: StoredPersonalizationEmbedding] = [:]

    init(database: PersonalizationDatabase) {
        self.database = database
    }

    func prepare() async throws -> PersonalLanguageModel {
        if let stored = try await database.loadLanguageModel() {
            model = stored
        } else {
            _ = try await rebuildLanguageModel()
        }
        try await reloadRetrievalIndex()
        return model
    }

    func record(
        _ capture: AcceptedSuggestionCapture
    ) async throws -> PersonalLanguageModel {
        try await database.record(capture)
        model.ingest(capture)
        try await database.saveLanguageModel(model)
        let example = PersonalizationExample(capture)
        examples.append(example)
        semanticExamples.append(example)
        try await embedIfNeeded(example)
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
        examples.append(
            contentsOf: PersonalizationExample.directlyTyped(from: episode)
        )
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
        examples = []
        semanticExamples = []
        embeddings = [:]
        return model
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
                    PersonalizationExample.promptValue(from: frecent)
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
            )
        )
    }

    private func rebuild() async throws -> PersonalLanguageModel {
        _ = try await rebuildLanguageModel()
        try await reloadRetrievalIndex()
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
}
