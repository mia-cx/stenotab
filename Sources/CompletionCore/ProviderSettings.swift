import Foundation

public enum ProviderSelection: Codable, Equatable, Hashable, Sendable {
    case builtInDemo
    case local
    case remote(providerID: String)
}

public struct RemoteProviderConfiguration:
    Codable, Equatable, Identifiable, Sendable
{
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var model: String
    public var apiStyle: CompletionAPIStyle
    public var maximumWords: Int

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        baseURL: String,
        model: String,
        apiStyle: CompletionAPIStyle,
        maximumWords: Int = 8
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.apiStyle = apiStyle
        self.maximumWords = min(max(maximumWords, 1), 32)
    }

    public var validatedBaseURL: URL? {
        guard
            let components = URLComponents(string: baseURL),
            components.scheme == "http" || components.scheme == "https",
            components.host?.isEmpty == false
        else {
            return nil
        }
        return components.url
    }

    public var modelsURL: URL? {
        guard let baseURL = validatedBaseURL else { return nil }
        let path = baseURL.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return path == "v1"
            ? baseURL.appending(path: "models")
            : baseURL.appending(path: "v1/models")
    }
}

public struct ProviderSettings: Codable, Equatable, Sendable {
    public var selection: ProviderSelection
    public var localConfiguration: LocalCompletionConfiguration
    public var remoteProviders: [RemoteProviderConfiguration]

    public init(
        selection: ProviderSelection = .builtInDemo,
        localConfiguration: LocalCompletionConfiguration = .init(
            profileID: "gemma-4-e2b-base",
            baseURL: "http://127.0.0.1:18473/v1",
            maximumWords: 8
        ),
        remoteProviders: [RemoteProviderConfiguration] = []
    ) {
        self.selection = selection
        self.localConfiguration = localConfiguration
        self.remoteProviders = remoteProviders
    }

    public func remoteProvider(
        id: String
    ) -> RemoteProviderConfiguration? {
        remoteProviders.first { $0.id == id }
    }
}
