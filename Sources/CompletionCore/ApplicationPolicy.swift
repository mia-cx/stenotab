import Foundation

public enum ApplicationPolicyOverride: String, Codable, CaseIterable, Sendable {
    case inherit
    case enabled
    case disabled
}

public struct SeenApplication: Codable, Equatable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public var displayName: String
    public var bundleURL: URL?
    public var lastSeenAt: Date

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        displayName: String,
        bundleURL: URL? = nil,
        lastSeenAt: Date
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.lastSeenAt = lastSeenAt
    }
}

public struct ApplicationObservation: Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let bundleURL: URL?
    public let observedAt: Date
    public let isSecureField: Bool

    public init(
        bundleIdentifier: String,
        displayName: String,
        bundleURL: URL? = nil,
        observedAt: Date,
        isSecureField: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.observedAt = observedAt
        self.isSecureField = isSecureField
    }
}

public struct ApplicationPolicyState: Codable, Equatable, Sendable {
    public var globalCompletionsEnabled: Bool
    public private(set) var overrides: [String: ApplicationPolicyOverride]
    public private(set) var seenApplications: [String: SeenApplication]

    public init(
        globalCompletionsEnabled: Bool = true,
        overrides: [String: ApplicationPolicyOverride] = [:],
        seenApplications: [String: SeenApplication] = [:]
    ) {
        self.globalCompletionsEnabled = globalCompletionsEnabled
        self.overrides = overrides.filter { $0.value != .inherit }
        self.seenApplications = seenApplications
    }

    public func policyOverride(
        for bundleIdentifier: String
    ) -> ApplicationPolicyOverride {
        overrides[bundleIdentifier] ?? .inherit
    }

    public func completionsAreEnabled(
        for bundleIdentifier: String
    ) -> Bool {
        switch policyOverride(for: bundleIdentifier) {
        case .inherit:
            globalCompletionsEnabled
        case .enabled:
            true
        case .disabled:
            false
        }
    }

    public mutating func setPolicyOverride(
        _ policyOverride: ApplicationPolicyOverride,
        for bundleIdentifier: String
    ) {
        let normalizedIdentifier = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedIdentifier.isEmpty else { return }

        if policyOverride == .inherit {
            overrides.removeValue(forKey: normalizedIdentifier)
        } else {
            overrides[normalizedIdentifier] = policyOverride
        }
    }

    @discardableResult
    public mutating func record(
        _ observation: ApplicationObservation
    ) -> Bool {
        guard !observation.isSecureField else { return false }

        let bundleIdentifier = observation.bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !bundleIdentifier.isEmpty else { return false }

        let displayName = observation.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let resolvedDisplayName = displayName.isEmpty
            ? bundleIdentifier
            : displayName
        let existing = seenApplications[bundleIdentifier]
        let updated = SeenApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: resolvedDisplayName,
            bundleURL: observation.bundleURL ?? existing?.bundleURL,
            lastSeenAt: max(
                observation.observedAt,
                existing?.lastSeenAt ?? .distantPast
            )
        )
        guard updated != existing else { return false }
        seenApplications[bundleIdentifier] = updated
        return true
    }
}
