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
            var resolved = overrides.applying(to: bundledDefaults)
            if let legacy = try? JSONDecoder().decode(
                LegacyOverrides.self,
                from: data
            ) {
                legacy.applyCanonicalFraming(to: &resolved)
            }
            configuration = resolved
            Self.persist(
                resolved,
                relativeTo: bundledDefaults,
                in: defaults,
                forKey: storageKey
            )
        } else if
            let data = defaults.data(forKey: legacyStorageKey),
            let saved = try? JSONDecoder().decode(
                PromptConfiguration.self,
                from: data
            )
        {
            var resolved = saved
            if let legacy = try? JSONDecoder().decode(
                LegacyOverrides.self,
                from: data
            ) {
                legacy.applyCanonicalFraming(to: &resolved)
            }
            configuration = resolved
            Self.persist(
                resolved,
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

    private struct LegacyOverrides: Decodable {
        struct Framing: Decodable {
            var ocrHeading: String?
            var clipboardHeading: String?
            var inputHistoryHeading: String?
            var assessmentHeading: String?
            var customVoiceHeading: String?
        }

        var framing: Framing?

        func applyCanonicalFraming(
            to configuration: inout PromptConfiguration
        ) {
            guard let framing else { return }
            if let value = framing.ocrHeading {
                configuration.baseFraming.ocrHeading = value
            }
            if let value = framing.clipboardHeading {
                configuration.baseFraming.clipboardHeading = value
            }
            if let value = framing.inputHistoryHeading {
                configuration.baseFraming.inputHistoryHeading = value
            }
            if let value = framing.assessmentHeading {
                configuration.baseFraming.assessmentHeading = value
            }
            if let value = framing.customVoiceHeading {
                configuration.baseFraming.customVoiceHeading = value
            }
        }
    }
}
