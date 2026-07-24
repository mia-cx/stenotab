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
    private let storageKey = "prompt-lab.overrides.v2"
    private let legacyStorageKey = "prompt-lab.configuration.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let bundledDefaults = PromptConfiguration.defaults
        if
            let data = defaults.data(forKey: storageKey),
            let overrides = try? JSONDecoder().decode(
                PromptConfiguration.Overrides.self,
                from: data
            )
        {
            configuration = overrides.applying(to: bundledDefaults)
        } else if
            let data = defaults.data(forKey: legacyStorageKey),
            let saved = try? JSONDecoder().decode(
                PromptConfiguration.self,
                from: data
            )
        {
            configuration = Self.migrateLegacyDefaultFraming(saved)
            Self.persist(
                configuration,
                relativeTo: bundledDefaults,
                in: defaults,
                forKey: storageKey
            )
            defaults.removeObject(forKey: legacyStorageKey)
        } else {
            configuration = bundledDefaults
        }
    }

    func reset() {
        configuration = .defaults
    }

    private func persist() {
        Self.persist(
            configuration,
            relativeTo: .defaults,
            in: defaults,
            forKey: storageKey
        )
    }

    private static func persist(
        _ configuration: PromptConfiguration,
        relativeTo bundledDefaults: PromptConfiguration,
        in defaults: UserDefaults,
        forKey storageKey: String
    ) {
        let overrides = PromptConfiguration.Overrides(
            configuration: configuration,
            relativeTo: bundledDefaults
        )
        if overrides.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func migrateLegacyDefaultFraming(
        _ saved: PromptConfiguration
    ) -> PromptConfiguration {
        var result = saved
        let defaults = PromptConfiguration.defaults.framing
        let replacements: [(WritableKeyPath<PromptConfiguration.Framing, String>, String)] = [
            (\.contextHeading, "Context:"),
            (\.applicationPrefix, "- Current application:"),
            (\.websitePrefix, "- Current website:"),
            (\.inputKindPrefix, "- Kind of input:"),
            (\.ocrHeading, "OCR content from snapshot:"),
            (\.clipboardHeading, "Clipboard content:"),
            (\.inputHistoryHeading, "Relevant input history:"),
            (\.assessmentHeading, "User voice assessment:"),
            (\.customVoiceHeading, "Custom voice:"),
            (\.suffixHeading, "Text after the cursor:"),
        ]
        for (keyPath, legacyDefault) in replacements
        where result.framing[keyPath: keyPath] == legacyDefault {
            result.framing[keyPath: keyPath] = defaults[keyPath: keyPath]
        }
        return result
    }
}
