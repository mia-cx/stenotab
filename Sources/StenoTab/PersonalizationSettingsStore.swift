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
    @Published private(set) var recentAcceptedSuggestions:
        [AcceptedSuggestionCapture] = []
    @Published private(set) var recentCompletionEpisodes:
        [CompletionEpisodeCapture] = []
    @Published private(set) var operationError: String?
    @Published private(set) var languageModel = PersonalLanguageModel()
    @Published private(set) var voiceAssessment: VoiceAssessment?

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
                voiceAssessment = await worker.voiceAssessmentSnapshot()
                refreshStatistics()
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
                recentAcceptedSuggestions =
                    try await database.acceptedSuggestions(limit: 20)
                recentCompletionEpisodes =
                    try await database.completionEpisodes(limit: 20)
                operationError = nil
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    private func refreshStatistics() {
        guard let database else { return }
        Task {
            do {
                let statistics = try await database.storageStatistics()
                storedEventCount = statistics.eventCount
                encryptedPayloadBytes =
                    statistics.encryptedPayloadBytes
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
                voiceAssessment = nil
                storedEventCount = 0
                encryptedPayloadBytes = 0
                recentEpisodes = []
                recentAcceptedSuggestions = []
                recentCompletionEpisodes = []
                operationError = nil
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func record(_ capture: AcceptedSuggestionCapture) {
        guard collectionEnabled, let modelWorker else { return }
        let policy = retentionPolicy
        Task {
            do {
                languageModel = try await modelWorker.record(
                    capture,
                    retentionPolicy: policy
                )
                voiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
                refreshStatistics()
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
                voiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
                refreshStatistics()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func record(_ feedback: CompletionFeedbackCapture) {
        guard collectionEnabled, let modelWorker else { return }
        let policy = retentionPolicy
        Task {
            do {
                languageModel = try await modelWorker.record(
                    feedback,
                    retentionPolicy: policy
                )
                refreshStatistics()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func record(_ episode: CompletionEpisodeCapture) {
        guard collectionEnabled, let modelWorker else { return }
        let policy = retentionPolicy
        Task {
            do {
                languageModel = try await modelWorker.record(
                    episode,
                    retentionPolicy: policy
                )
                refreshStatistics()
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
                voiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
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
                voiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
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
                voiceAssessment =
                    await modelWorker.voiceAssessmentSnapshot()
                refresh()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func report(error: Error) {
        operationError = String(describing: error)
    }

    func reassessVoice() {
        guard let modelWorker else { return }
        Task {
            do {
                voiceAssessment = try await modelWorker.reassessVoice()
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
        guard useLocalCompletions else { return nil }
        return languageModel.completion(for: prefix, context: context)
    }

    var vocabularyEntries: [PersonalVocabularyEntry] {
        languageModel.vocabularyEntries(limit: 30)
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
    private var voiceAssessment: VoiceAssessment?
    private var voiceTexts: [String] = []
    private var voiceSourceEventCount = 0

    init(database: PersonalizationDatabase) {
        self.database = database
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

    func record(
        _ capture: AcceptedSuggestionCapture,
        retentionPolicy: PersonalizationRetentionPolicy
    ) async throws -> PersonalLanguageModel {
        try await database.record(capture)
        model.ingest(capture)
        try await database.saveLanguageModel(model)
        let example = PersonalizationExample(capture)
        examples.append(example)
        semanticExamples.append(example)
        try await embedIfNeeded(example)
        voiceTexts.append(capture.field.text + capture.insertion)
        voiceSourceEventCount += 1
        try await updateVoiceAssessmentIfNeeded()
        let removed = try await database.enforceRetention(retentionPolicy)
        if removed > 0 {
            return try await rebuild()
        }
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
        voiceTexts.append(episode.finalField.text)
        voiceSourceEventCount += 1
        try await updateVoiceAssessmentIfNeeded()
        return model
    }

    func record(
        _ feedback: CompletionFeedbackCapture,
        retentionPolicy: PersonalizationRetentionPolicy
    ) async throws -> PersonalLanguageModel {
        try await database.record(feedback)
        model.ingest(feedback)
        try await database.saveLanguageModel(model)
        let removed = try await database.enforceRetention(retentionPolicy)
        if removed > 0 {
            return try await rebuild()
        }
        return model
    }

    func record(
        _ episode: CompletionEpisodeCapture,
        retentionPolicy: PersonalizationRetentionPolicy
    ) async throws -> PersonalLanguageModel {
        try await database.record(episode)
        let removed = try await database.enforceRetention(retentionPolicy)
        if removed > 0 {
            return try await rebuild()
        }
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
        voiceTexts = []
        voiceSourceEventCount = 0
        voiceAssessment = nil
        return model
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
            ),
            voiceAssessment: voiceAssessment?.summary
        )
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
        voiceTexts = Array(
            (
                episodes.map(\.finalField.text)
                    + accepted.map { $0.field.text + $0.insertion }
            ).suffix(200)
        )
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
            if force, voiceAssessment != nil {
                voiceAssessment = nil
                try await database.deleteVoiceAssessment()
            }
            return
        }
        guard
            force
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
                sourceEventCount: sourceEventCount
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
