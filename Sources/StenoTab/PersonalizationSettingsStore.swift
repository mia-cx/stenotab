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

    private let defaults: UserDefaults
    private var database: PersonalizationDatabase?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collectionEnabled = defaults.object(
            forKey: Keys.collectionEnabled
        ) as? Bool ?? true
        collectDirectTyping = defaults.object(
            forKey: Keys.collectDirectTyping
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
        refresh()
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
        guard let database else { return }
        Task {
            do {
                try await database.deleteAll()
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

    func deleteEvent(id: UUID) {
        guard let database else { return }
        Task {
            do {
                try await database.deleteEvent(id: id)
                refresh()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func deleteApplicationHistory(bundleIdentifier: String) {
        guard let database else { return }
        Task {
            do {
                _ = try await database.deleteEvents(
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
        guard let database else { return }
        let policy = retentionPolicy
        Task {
            do {
                _ = try await database.enforceRetention(policy)
                refresh()
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func report(error: Error) {
        operationError = String(describing: error)
    }
}
