import Combine
import CompletionCore
import Foundation

@MainActor
final class ApplicationPolicyStore: ObservableObject {
    @Published private(set) var state: ApplicationPolicyState {
        didSet {
            persist()
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "application-policy.v1"
    private let observationRefreshInterval: TimeInterval = 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode(
                ApplicationPolicyState.self,
                from: data
            )
        {
            state = saved
        } else {
            state = ApplicationPolicyState()
        }
    }

    var seenApplications: [SeenApplication] {
        state.seenApplications.values.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            ) == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            ) == .orderedAscending
        }
    }

    func completionsAreEnabled(for bundleIdentifier: String?) -> Bool {
        state.completionsAreEnabled(for: bundleIdentifier)
    }

    func policyOverride(
        for bundleIdentifier: String
    ) -> ApplicationPolicyOverride {
        state.policyOverride(for: bundleIdentifier)
    }

    func togglePolicy(for bundleIdentifier: String) {
        setPolicyOverride(
            state.toggledOverride(for: bundleIdentifier),
            for: bundleIdentifier
        )
    }

    func setGlobalCompletionsEnabled(_ isEnabled: Bool) {
        guard state.globalCompletionsEnabled != isEnabled else { return }
        state.globalCompletionsEnabled = isEnabled
    }

    func setPolicyOverride(
        _ policyOverride: ApplicationPolicyOverride,
        for bundleIdentifier: String
    ) {
        guard
            state.policyOverride(for: bundleIdentifier) != policyOverride
        else {
            return
        }
        state.setPolicyOverride(
            policyOverride,
            for: bundleIdentifier
        )
    }

    func record(_ observation: ApplicationObservation) {
        if
            let existing = state.seenApplications[
                observation.bundleIdentifier
            ],
            existing.displayName == observation.displayName,
            existing.bundleURL == observation.bundleURL,
            observation.observedAt.timeIntervalSince(existing.lastSeenAt)
                < observationRefreshInterval
        {
            return
        }

        _ = state.record(observation)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
