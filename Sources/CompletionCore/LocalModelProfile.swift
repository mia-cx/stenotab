import Foundation

public enum CompletionAPIStyle:
    String, CaseIterable, Codable, Hashable, Sendable
{
    case textCompletions
    case chatCompletions
    case gemmaChatPrefill
}

public struct LocalModelProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let repository: String
    public let modelFile: String?
    public let apiStyle: CompletionAPIStyle
    public let minimumUnifiedMemoryGB: Int
    public let supportsImages: Bool
    public let qualityNote: String

    public init(
        id: String,
        displayName: String,
        repository: String,
        modelFile: String? = nil,
        apiStyle: CompletionAPIStyle,
        minimumUnifiedMemoryGB: Int,
        supportsImages: Bool,
        qualityNote: String
    ) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.modelFile = modelFile
        self.apiStyle = apiStyle
        self.minimumUnifiedMemoryGB = minimumUnifiedMemoryGB
        self.supportsImages = supportsImages
        self.qualityNote = qualityNote
    }

    public var serverModelID: String {
        "stenotab/\(id)"
    }

    public var compatibleServerModelIDs: Set<String> {
        Set(
            [serverModelID, repository, modelFile]
                .compactMap { $0 }
        )
    }
}

public enum LocalModelProfiles {
    public static let all: [LocalModelProfile] = [
        LocalModelProfile(
            id: "gemma-4-e2b-base",
            displayName: "Gemma 4 E2B Base · Recommended",
            repository: "mradermacher/gemma-4-E2B-GGUF",
            modelFile: "gemma-4-E2B.Q4_K_M.gguf",
            apiStyle: .textCompletions,
            minimumUnifiedMemoryGB: 16,
            supportsImages: false,
            qualityNote: "Recommended Q4_K_M model for user-voice continuation."
        ),
    ]

    public static func profile(id: String) -> LocalModelProfile? {
        all.first { $0.id == id }
    }
}

public struct LocalCompletionConfiguration:
    Codable, Sendable, Equatable
{
    public let profileID: String
    public let customProfile: LocalModelProfile?
    public let baseURL: String
    public let maximumWords: Int

    public init(
        profileID: String,
        customProfile: LocalModelProfile? = nil,
        baseURL: String,
        maximumWords: Int
    ) {
        self.profileID = profileID
        self.customProfile = customProfile
        self.baseURL = baseURL
        self.maximumWords = maximumWords
    }

    public var selectedProfile: LocalModelProfile? {
        if let customProfile, customProfile.id == profileID {
            return customProfile
        }
        return LocalModelProfiles.profile(id: profileID)
    }
}
