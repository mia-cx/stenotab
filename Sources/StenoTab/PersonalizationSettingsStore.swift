import Foundation
import StenoTabPersistence

@MainActor
final class PersonalizationSettingsStore: ObservableObject {
    private enum Keys {
        static let collectionEnabled =
            "personalization.collectionEnabled"
    }

    @Published var collectionEnabled: Bool {
        didSet {
            defaults.set(
                collectionEnabled,
                forKey: Keys.collectionEnabled
            )
        }
    }
    @Published private(set) var storedEventCount = 0
    @Published private(set) var operationError: String?

    private let defaults: UserDefaults
    private var database: PersonalizationDatabase?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collectionEnabled = defaults.object(
            forKey: Keys.collectionEnabled
        ) as? Bool ?? true
    }

    func attach(database: PersonalizationDatabase) {
        self.database = database
        refresh()
    }

    func refresh() {
        guard let database else { return }
        Task {
            do {
                storedEventCount = try await database.eventCount()
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
                operationError = nil
            } catch {
                operationError = String(describing: error)
            }
        }
    }

    func didRecordEvent() {
        storedEventCount += 1
    }
}
