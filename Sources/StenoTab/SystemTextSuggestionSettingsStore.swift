import Combine
import CompletionCore
import Foundation

@MainActor
final class SystemTextSuggestionSettingsStore: ObservableObject {
    private enum PreferenceKey {
        static let inlinePredictiveText =
            "NSAutomaticInlinePredictionEnabled"
        static let suggestedReplies = "NSSmartReplyEnabled"
    }

    @Published private(set) var state = SystemTextSuggestionState(
        inlinePredictiveTextEnabled: true,
        suggestedRepliesEnabled: true
    )
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        UserDefaults.standard.synchronize()
        state = SystemTextSuggestionState(
            inlinePredictiveTextEnabled: preferenceIsEnabled(
                PreferenceKey.inlinePredictiveText
            ),
            suggestedRepliesEnabled: preferenceIsEnabled(
                PreferenceKey.suggestedReplies
            )
        )
    }

    func disableAll() {
        errorMessage = nil
        do {
            try writeDisabled(PreferenceKey.inlinePredictiveText)
            try writeDisabled(PreferenceKey.suggestedReplies)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    private func preferenceIsEnabled(_ key: String) -> Bool {
        guard
            let value = UserDefaults.standard.persistentDomain(
                forName: UserDefaults.globalDomain
            )?[key] as? NSNumber
        else {
            // macOS enables these suggestions by default. An absent key must
            // not be reported as a completed setup step.
            return true
        }
        return value.boolValue
    }

    private func writeDisabled(_ key: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/defaults")
        process.arguments = [
            "write",
            "NSGlobalDomain",
            key,
            "-bool",
            "false",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WriteError.failed(key: key, status: process.terminationStatus)
        }
    }

    private enum WriteError: LocalizedError {
        case failed(key: String, status: Int32)

        var errorDescription: String? {
            switch self {
            case let .failed(key, status):
                "Could not update \(key) (defaults exited with \(status))."
            }
        }
    }
}
