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

    enum LocalModelDownloadStatus: Equatable {
        case idle
        case downloading(
            receivedBytes: Int64,
            totalBytes: Int64?
        )
        case ready(URL)
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
    @Published private(set) var localModelDownloadStatus:
        LocalModelDownloadStatus = .idle
    @Published private(set) var cachedLocalProfiles: [LocalModelProfile] = []

    private let defaults: UserDefaults
    private let credentialVault: any ProviderCredentialVault
    private let modelDownloader = HuggingFaceModelDownloader()
    private let storageKey = "provider-settings.v1"
    private var modelDownloadTask: Task<Void, Never>?
    private var cacheRefreshTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        credentialVault: any ProviderCredentialVault =
            KeychainProviderCredentialVault()
    ) {
        self.defaults = defaults
        self.credentialVault = credentialVault
        var loadedConfiguration: ProviderSettings
        if
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode(
                ProviderSettings.self,
                from: data
            )
        {
            loadedConfiguration = saved
        } else if let legacy = ProviderFactory.localConfiguration() {
            loadedConfiguration = ProviderSettings(
                selection: .local,
                localConfiguration: legacy
            )
        } else {
            loadedConfiguration = ProviderSettings()
        }
        loadedConfiguration.selection = .local
        configuration = loadedConfiguration
        refreshCachedLocalProfiles()
        refreshLocalModelDownloadStatus()
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

    func selectLocalProfile(_ profile: LocalModelProfile) {
        var next = configuration
        next.selection = .local
        next.localConfiguration = LocalCompletionConfiguration(
            profileID: profile.id,
            customProfile:
                LocalModelProfiles.profile(id: profile.id) == nil
                    ? profile
                    : nil,
            baseURL: configuration.localConfiguration.baseURL,
            maximumWords: configuration.localConfiguration.maximumWords
        )
        guard next != configuration else {
            refreshLocalModelDownloadStatus()
            return
        }
        configuration = next
        refreshLocalModelDownloadStatus()
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
            configuration.selection = .local
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

    func downloadSelectedLocalModel() {
        guard
            modelDownloadTask == nil,
            let profile = configuration.localConfiguration.selectedProfile
        else {
            return
        }
        if let modelURL = HuggingFaceModelCache.modelURL(for: profile) {
            localModelDownloadStatus = .ready(modelURL)
            setSelection(.local)
            return
        }

        localModelDownloadStatus = .downloading(
            receivedBytes: 0,
            totalBytes: nil
        )
        modelDownloadTask = Task { [weak self, modelDownloader] in
            do {
                let modelURL = try await modelDownloader.download(
                    profile: profile
                ) { progress in
                    await MainActor.run {
                        self?.localModelDownloadStatus = .downloading(
                            receivedBytes: progress.receivedBytes,
                            totalBytes: progress.totalBytes
                        )
                    }
                }
                guard let self else { return }
                localModelDownloadStatus = .ready(modelURL)
                modelDownloadTask = nil
                refreshCachedLocalProfiles()
                if configuration.selection == .local {
                    onChange?()
                } else {
                    setSelection(.local)
                }
            } catch is CancellationError {
                guard let self else { return }
                localModelDownloadStatus = .idle
                modelDownloadTask = nil
            } catch {
                guard let self else { return }
                localModelDownloadStatus = .failed(
                    error.localizedDescription
                )
                modelDownloadTask = nil
            }
        }
    }

    func downloadCustomLocalModel(repository: String) {
        guard modelDownloadTask == nil else { return }
        localModelDownloadStatus = .downloading(
            receivedBytes: 0,
            totalBytes: nil
        )
        modelDownloadTask = Task { [weak self, modelDownloader] in
            do {
                let profile = try await modelDownloader.resolveProfile(
                    repository: repository
                )
                let modelURL: URL
                if let cachedURL = HuggingFaceModelCache.modelURL(for: profile) {
                    modelURL = cachedURL
                } else {
                    modelURL = try await modelDownloader.download(
                        profile: profile
                    ) { progress in
                        await MainActor.run {
                            self?.localModelDownloadStatus = .downloading(
                                receivedBytes: progress.receivedBytes,
                                totalBytes: progress.totalBytes
                            )
                        }
                    }
                }
                guard let self else { return }
                modelDownloadTask = nil
                refreshCachedLocalProfiles()
                selectLocalProfile(profile)
                localModelDownloadStatus = .ready(modelURL)
            } catch is CancellationError {
                guard let self else { return }
                localModelDownloadStatus = .idle
                modelDownloadTask = nil
            } catch {
                guard let self else { return }
                localModelDownloadStatus = .failed(
                    error.localizedDescription
                )
                modelDownloadTask = nil
            }
        }
    }

    func cancelLocalModelDownload() {
        modelDownloadTask?.cancel()
    }

    func refreshLocalModelDownloadStatus() {
        guard
            let profile = configuration.localConfiguration.selectedProfile,
            let modelURL = HuggingFaceModelCache.modelURL(for: profile)
        else {
            if case .downloading = localModelDownloadStatus {
                return
            }
            localModelDownloadStatus = .idle
            return
        }
        localModelDownloadStatus = .ready(modelURL)
    }

    func refreshCachedLocalProfiles() {
        cacheRefreshTask?.cancel()
        cacheRefreshTask = Task { [weak self] in
            let profiles = await Task.detached(priority: .utility) {
                HuggingFaceModelCache.cachedProfiles()
            }.value
            guard !Task.isCancelled else { return }
            self?.cachedLocalProfiles = profiles
            self?.cacheRefreshTask = nil
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
