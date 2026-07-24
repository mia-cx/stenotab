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
            let migrated = Self.migrateLegacyDefaultFraming(saved)
            configuration = migrated
            if migrated != saved,
               let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: storageKey)
            }
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
