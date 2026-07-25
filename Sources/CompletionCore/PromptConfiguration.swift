import Foundation

public struct PromptConfiguration: Codable, Sendable, Equatable {
    public struct ContextOptions: Codable, Sendable, Equatable {
        public var includeCurrentApplication: Bool
        public var includeCurrentWebsite: Bool
        public var includeInputKind: Bool
        public var includeOCR: Bool
        public var includeClipboard: Bool

        public init(
            includeCurrentApplication: Bool = true,
            includeCurrentWebsite: Bool = false,
            includeInputKind: Bool = true,
            includeOCR: Bool = false,
            includeClipboard: Bool = false
        ) {
            self.includeCurrentApplication = includeCurrentApplication
            self.includeCurrentWebsite = includeCurrentWebsite
            self.includeInputKind = includeInputKind
            self.includeOCR = includeOCR
            self.includeClipboard = includeClipboard
        }
    }

    public struct VoiceOptions: Codable, Sendable, Equatable {
        public var includeInputHistory: Bool
        public var includeRelevantInputHistory: Bool
        public var includePeriodicAssessments: Bool
        public var includeCustomVoice: Bool
        public var customVoice: String

        public init(
            includeInputHistory: Bool = true,
            includeRelevantInputHistory: Bool = false,
            includePeriodicAssessments: Bool = false,
            includeCustomVoice: Bool = true,
            customVoice: String = ""
        ) {
            self.includeInputHistory = includeInputHistory
            self.includeRelevantInputHistory = includeRelevantInputHistory
            self.includePeriodicAssessments = includePeriodicAssessments
            self.includeCustomVoice = includeCustomVoice
            self.customVoice = customVoice
        }

        private enum CodingKeys: String, CodingKey {
            case includeInputHistory
            case includeRelevantInputHistory
            case includePeriodicAssessments
            case includeCustomVoice
            case customVoice
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            includeInputHistory = try container.decodeIfPresent(
                Bool.self,
                forKey: .includeInputHistory
            ) ?? true
            includeRelevantInputHistory = try container.decodeIfPresent(
                Bool.self,
                forKey: .includeRelevantInputHistory
            ) ?? false
            includePeriodicAssessments = try container.decodeIfPresent(
                Bool.self,
                forKey: .includePeriodicAssessments
            ) ?? false
            includeCustomVoice = try container.decodeIfPresent(
                Bool.self,
                forKey: .includeCustomVoice
            ) ?? true
            customVoice = try container.decodeIfPresent(
                String.self,
                forKey: .customVoice
            ) ?? ""
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                includeInputHistory,
                forKey: .includeInputHistory
            )
            try container.encode(
                includeRelevantInputHistory,
                forKey: .includeRelevantInputHistory
            )
            try container.encode(
                includePeriodicAssessments,
                forKey: .includePeriodicAssessments
            )
            try container.encode(
                includeCustomVoice,
                forKey: .includeCustomVoice
            )
            try container.encode(customVoice, forKey: .customVoice)
        }
    }

    public struct BaseOptions: Codable, Sendable, Equatable {
        public var includeOpeningInstruction: Bool
        public var includeFocusedContext: Bool
        public var includePerspectiveFix: Bool
        public var includeFinalBoundary: Bool
        public var includeWritingHeading: Bool

        public init(
            includeOpeningInstruction: Bool = true,
            includeFocusedContext: Bool = true,
            includePerspectiveFix: Bool = true,
            includeFinalBoundary: Bool = true,
            includeWritingHeading: Bool = true
        ) {
            self.includeOpeningInstruction = includeOpeningInstruction
            self.includeFocusedContext = includeFocusedContext
            self.includePerspectiveFix = includePerspectiveFix
            self.includeFinalBoundary = includeFinalBoundary
            self.includeWritingHeading = includeWritingHeading
        }
    }

    public struct BaseFraming: Codable, Sendable, Equatable {
        public var openingInstruction: String
        public var focusedContextHeading: String
        public var focusedActivityPrefix: String
        public var focusedWebsiteConnector: String
        public var focusedApplicationConnector: String
        public var inputHistoryHeading: String
        public var seedExamplesHeading: String
        public var relevantInputHistoryHeading: String
        public var assessmentHeading: String
        public var customVoiceHeading: String
        public var perspectiveFix: String
        public var ocrHeading: String
        public var clipboardHeading: String
        public var finalBoundary: String
        public var writingHeading: String
        public var examplePrefix: String

        public init(
            openingInstruction: String? = nil,
            focusedContextHeading: String? = nil,
            focusedActivityPrefix: String? = nil,
            focusedWebsiteConnector: String? = nil,
            focusedApplicationConnector: String? = nil,
            inputHistoryHeading: String? = nil,
            seedExamplesHeading: String? = nil,
            relevantInputHistoryHeading: String? = nil,
            assessmentHeading: String? = nil,
            customVoiceHeading: String? = nil,
            perspectiveFix: String? = nil,
            ocrHeading: String? = nil,
            clipboardHeading: String? = nil,
            finalBoundary: String? = nil,
            writingHeading: String? = nil,
            examplePrefix: String? = nil
        ) {
            self.openingInstruction =
                openingInstruction ?? PromptResources.baseOpeningInstruction
            self.focusedContextHeading =
                focusedContextHeading
                    ?? PromptResources.baseFocusedContextHeading
            self.focusedActivityPrefix =
                focusedActivityPrefix ?? PromptResources.baseWritingPrefix
            self.focusedWebsiteConnector =
                focusedWebsiteConnector
                    ?? PromptResources.baseWebsiteConnector
            self.focusedApplicationConnector =
                focusedApplicationConnector
                    ?? PromptResources.baseApplicationConnector
            self.inputHistoryHeading =
                inputHistoryHeading ?? PromptResources.inputHistoryHeading
            self.seedExamplesHeading =
                seedExamplesHeading ?? PromptResources.seedExamplesHeading
            self.relevantInputHistoryHeading =
                relevantInputHistoryHeading
                    ?? PromptResources.relevantInputHistoryHeading
            self.assessmentHeading =
                assessmentHeading ?? PromptResources.assessmentHeading
            self.customVoiceHeading =
                customVoiceHeading ?? PromptResources.customVoiceHeading
            self.perspectiveFix =
                perspectiveFix ?? PromptResources.basePerspectiveFix
            self.ocrHeading = ocrHeading ?? PromptResources.ocrHeading
            self.clipboardHeading =
                clipboardHeading ?? PromptResources.clipboardHeading
            self.finalBoundary =
                finalBoundary ?? PromptResources.baseFinalBoundary
            self.writingHeading =
                writingHeading ?? PromptResources.baseWritingHeading
            self.examplePrefix =
                examplePrefix ?? PromptResources.baseExamplePrefix
        }

        private enum CodingKeys: String, CodingKey {
            case openingInstruction
            case focusedContextHeading
            case focusedActivityPrefix
            case focusedWebsiteConnector
            case focusedApplicationConnector
            case inputHistoryHeading
            case seedExamplesHeading
            case relevantInputHistoryHeading
            case assessmentHeading
            case customVoiceHeading
            case perspectiveFix
            case ocrHeading
            case clipboardHeading
            case finalBoundary
            case writingHeading
            case examplePrefix
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                openingInstruction: try container.decodeIfPresent(
                    String.self,
                    forKey: .openingInstruction
                ),
                focusedContextHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .focusedContextHeading
                ),
                focusedActivityPrefix: try container.decodeIfPresent(
                    String.self,
                    forKey: .focusedActivityPrefix
                ),
                focusedWebsiteConnector: try container.decodeIfPresent(
                    String.self,
                    forKey: .focusedWebsiteConnector
                ),
                focusedApplicationConnector: try container.decodeIfPresent(
                    String.self,
                    forKey: .focusedApplicationConnector
                ),
                inputHistoryHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .inputHistoryHeading
                ),
                seedExamplesHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .seedExamplesHeading
                ),
                relevantInputHistoryHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .relevantInputHistoryHeading
                ),
                assessmentHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .assessmentHeading
                ),
                customVoiceHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .customVoiceHeading
                ),
                perspectiveFix: try container.decodeIfPresent(
                    String.self,
                    forKey: .perspectiveFix
                ),
                ocrHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .ocrHeading
                ),
                clipboardHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .clipboardHeading
                ),
                finalBoundary: try container.decodeIfPresent(
                    String.self,
                    forKey: .finalBoundary
                ),
                writingHeading: try container.decodeIfPresent(
                    String.self,
                    forKey: .writingHeading
                ),
                examplePrefix: try container.decodeIfPresent(
                    String.self,
                    forKey: .examplePrefix
                )
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                openingInstruction,
                forKey: .openingInstruction
            )
            try container.encode(
                focusedContextHeading,
                forKey: .focusedContextHeading
            )
            try container.encode(
                focusedActivityPrefix,
                forKey: .focusedActivityPrefix
            )
            try container.encode(
                focusedWebsiteConnector,
                forKey: .focusedWebsiteConnector
            )
            try container.encode(
                focusedApplicationConnector,
                forKey: .focusedApplicationConnector
            )
            try container.encode(
                inputHistoryHeading,
                forKey: .inputHistoryHeading
            )
            try container.encode(
                seedExamplesHeading,
                forKey: .seedExamplesHeading
            )
            try container.encode(
                relevantInputHistoryHeading,
                forKey: .relevantInputHistoryHeading
            )
            try container.encode(
                assessmentHeading,
                forKey: .assessmentHeading
            )
            try container.encode(
                customVoiceHeading,
                forKey: .customVoiceHeading
            )
            try container.encode(perspectiveFix, forKey: .perspectiveFix)
            try container.encode(ocrHeading, forKey: .ocrHeading)
            try container.encode(clipboardHeading, forKey: .clipboardHeading)
            try container.encode(finalBoundary, forKey: .finalBoundary)
            try container.encode(writingHeading, forKey: .writingHeading)
            try container.encode(examplePrefix, forKey: .examplePrefix)
        }
    }

    public var context: ContextOptions
    public var voice: VoiceOptions
    public var base: BaseOptions
    public var baseFraming: BaseFraming
    public var systemInstruction: String
    public var debugMode: Bool

    public init(
        context: ContextOptions = .init(),
        voice: VoiceOptions = .init(),
        base: BaseOptions = .init(),
        baseFraming: BaseFraming = .init(),
        systemInstruction: String = Self.defaultSystemInstruction,
        debugMode: Bool = false
    ) {
        self.context = context
        self.voice = voice
        self.base = base
        self.baseFraming = baseFraming
        self.systemInstruction = systemInstruction
        self.debugMode = debugMode
    }

    public static let defaultSystemInstruction =
        PromptResources.chatSystemInstruction

    public static let defaults = PromptConfiguration()

    private enum CodingKeys: String, CodingKey {
        case context
        case voice
        case base
        case baseFraming
        case baseCompletionIntention
        case systemInstruction
        case debugMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        context = try container.decodeIfPresent(
            ContextOptions.self,
            forKey: .context
        ) ?? .init()
        voice = try container.decodeIfPresent(
            VoiceOptions.self,
            forKey: .voice
        ) ?? .init()
        base = try container.decodeIfPresent(
            BaseOptions.self,
            forKey: .base
        ) ?? .init()
        baseFraming = try container.decodeIfPresent(
            BaseFraming.self,
            forKey: .baseFraming
        ) ?? .init()
        if
            let legacyPerspectiveFix = try container.decodeIfPresent(
                String.self,
                forKey: .baseCompletionIntention
            )
        {
            baseFraming.perspectiveFix = legacyPerspectiveFix
        }
        systemInstruction = try container.decodeIfPresent(
            String.self,
            forKey: .systemInstruction
        ) ?? Self.defaultSystemInstruction
        debugMode = try container.decodeIfPresent(
            Bool.self,
            forKey: .debugMode
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context, forKey: .context)
        try container.encode(voice, forKey: .voice)
        try container.encode(base, forKey: .base)
        try container.encode(baseFraming, forKey: .baseFraming)
        try container.encode(systemInstruction, forKey: .systemInstruction)
        try container.encode(debugMode, forKey: .debugMode)
    }
}

public struct ComposedCompletionPrompt: Sendable, Equatable {
    public let systemMessage: String
    public let userMessage: String
    public let textCompletionPrompt: String

    public init(
        systemMessage: String,
        userMessage: String,
        textCompletionPrompt: String
    ) {
        self.systemMessage = systemMessage
        self.userMessage = userMessage
        self.textCompletionPrompt = textCompletionPrompt
    }
}
