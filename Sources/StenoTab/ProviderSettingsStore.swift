import Combine
import CompletionCore
import Foundation

@MainActor
final class ProviderSettingsStore: ObservableObject {
    enum ConnectionTestStatus: Equatable {
        case testing
        case succeeded
        case failed(String)
    }

    @Published private(set) var configuration: ProviderSettings {
        didSet {
            persist()
            onChange?()
        }
    }

    var onChange: (() -> Void)?
    @Published private(set) var connectionTests:
        [String: ConnectionTestStatus] = [:]

    private let defaults: UserDefaults
    private let credentialVault: any ProviderCredentialVault
    private let storageKey = "provider-settings.v1"

    init(
        defaults: UserDefaults = .standard,
        credentialVault: any ProviderCredentialVault =
            KeychainProviderCredentialVault()
    ) {
        self.defaults = defaults
        self.credentialVault = credentialVault
        if
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode(
                ProviderSettings.self,
                from: data
            )
        {
            configuration = saved
        } else if let legacy = ProviderFactory.localConfiguration() {
            configuration = ProviderSettings(
                selection: .local,
                localConfiguration: legacy
            )
        } else {
            configuration = ProviderSettings()
        }
    }

    func setSelection(_ selection: ProviderSelection) {
        guard configuration.selection != selection else { return }
        configuration.selection = selection
    }

    func setLocalConfiguration(
        _ localConfiguration: LocalCompletionConfiguration
    ) {
        guard configuration.localConfiguration != localConfiguration else {
            return
        }
        configuration.localConfiguration = localConfiguration
    }

    func upsert(
        _ remoteProvider: RemoteProviderConfiguration,
        apiKey: String?
    ) throws {
        try credentialVault.setCredential(
            apiKey,
            for: remoteProvider.id
        )
        if let index = configuration.remoteProviders.firstIndex(
            where: { $0.id == remoteProvider.id }
        ) {
            configuration.remoteProviders[index] = remoteProvider
        } else {
            configuration.remoteProviders.append(remoteProvider)
        }
    }

    func removeRemoteProvider(id: String) throws {
        try credentialVault.setCredential(nil, for: id)
        configuration.remoteProviders.removeAll { $0.id == id }
        if configuration.selection == .remote(providerID: id) {
            configuration.selection = .builtInDemo
        }
    }

    func credential(for providerID: String) throws -> String? {
        try credentialVault.credential(for: providerID)
    }

    func testRemoteProvider(id: String) async {
        guard
            let provider = configuration.remoteProvider(id: id),
            let modelsURL = provider.modelsURL
        else {
            connectionTests[id] = .failed("Enter a valid HTTP(S) base URL.")
            return
        }

        connectionTests[id] = .testing
        do {
            var request = URLRequest(url: modelsURL)
            request.timeoutInterval = 5
            if let apiKey = try credentialVault.credential(for: id),
               !apiKey.isEmpty {
                request.setValue(
                    "Bearer \(apiKey)",
                    forHTTPHeaderField: "Authorization"
                )
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 7
            let session = URLSession(configuration: configuration)
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                connectionTests[id] = .failed("The endpoint returned no HTTP response.")
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                connectionTests[id] = .failed(
                    "The endpoint returned HTTP \(httpResponse.statusCode)."
                )
                return
            }
            connectionTests[id] = .succeeded
        } catch {
            connectionTests[id] = .failed(error.localizedDescription)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
