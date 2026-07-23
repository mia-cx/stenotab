import Foundation

public enum CompletionAPIStyle: String, Codable, Sendable {
    case textCompletions
    case chatCompletions
}

public struct LocalModelProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let repository: String
    public let apiStyle: CompletionAPIStyle
    public let minimumUnifiedMemoryGB: Int
    public let supportsImages: Bool
    public let qualityNote: String

    public init(
        id: String,
        displayName: String,
        repository: String,
        apiStyle: CompletionAPIStyle,
        minimumUnifiedMemoryGB: Int,
        supportsImages: Bool,
        qualityNote: String
    ) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.apiStyle = apiStyle
        self.minimumUnifiedMemoryGB = minimumUnifiedMemoryGB
        self.supportsImages = supportsImages
        self.qualityNote = qualityNote
    }
}

public enum LocalModelProfiles {
    public static let all: [LocalModelProfile] = [
        LocalModelProfile(
            id: "gemma-3-270m-base",
            displayName: "Gemma 3 270M Base · Experimental",
            repository: "mlx-community/gemma-3-270m-4bit",
            apiStyle: .textCompletions,
            minimumUnifiedMemoryGB: 8,
            supportsImages: false,
            qualityNote: "Extremely fast, but prone to noisy web-text continuations."
        ),
        LocalModelProfile(
            id: "gemma-3-1b-base",
            displayName: "Gemma 3 1B Base · Fast",
            repository: "mlx-community/gemma-3-1b-pt-4bit",
            apiStyle: .textCompletions,
            minimumUnifiedMemoryGB: 8,
            supportsImages: false,
            qualityNote: "Best starting point for 8 GB Macs and raw continuation."
        ),
        LocalModelProfile(
            id: "gemma-3-1b-it",
            displayName: "Gemma 3 1B IT · Promptable",
            repository: "mlx-community/gemma-3-1b-it-4bit",
            apiStyle: .chatCompletions,
            minimumUnifiedMemoryGB: 8,
            supportsImages: false,
            qualityNote: "Follows context instructions, with less natural continuation."
        ),
        LocalModelProfile(
            id: "gemma-4-e2b-base",
            displayName: "Gemma 4 E2B Base · Quality Continuation",
            repository: "mlx-community/gemma-4-e2b-4bit",
            apiStyle: .textCompletions,
            minimumUnifiedMemoryGB: 16,
            supportsImages: true,
            qualityNote: "Higher-quality raw continuation for 16 GB or larger Macs."
        ),
        LocalModelProfile(
            id: "gemma-4-e2b-it",
            displayName: "Gemma 4 E2B IT · Context Quality",
            repository: "mlx-community/gemma-4-e2b-it-4bit",
            apiStyle: .chatCompletions,
            minimumUnifiedMemoryGB: 16,
            supportsImages: true,
            qualityNote: "Recommended for cached OCR or conversation context."
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
    public let baseURL: String
    public let maximumWords: Int

    public init(
        profileID: String,
        baseURL: String,
        maximumWords: Int
    ) {
        self.profileID = profileID
        self.baseURL = baseURL
        self.maximumWords = maximumWords
    }
}
