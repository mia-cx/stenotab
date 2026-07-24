import Combine
import CompletionCore
import Foundation

@MainActor
final class PromptSettingsStore: ObservableObject {
    @Published var configuration: PromptConfiguration {
        didSet {
            persist()
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "prompt-lab.configuration.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode(
                PromptConfiguration.self,
                from: data
            )
        {
            configuration = saved
        } else {
            configuration = .defaults
        }
    }

    func reset() {
        configuration = .defaults
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
