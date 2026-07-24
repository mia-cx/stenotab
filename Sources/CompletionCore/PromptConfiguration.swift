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
            includeCurrentWebsite: Bool = true,
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
        public var includePeriodicAssessments: Bool
        public var customVoice: String

        public init(
            includeInputHistory: Bool = false,
            includePeriodicAssessments: Bool = false,
            customVoice: String = ""
        ) {
            self.includeInputHistory = includeInputHistory
            self.includePeriodicAssessments = includePeriodicAssessments
            self.customVoice = customVoice
        }
    }

    public struct Framing: Codable, Sendable, Equatable {
        public var contextHeading: String
        public var applicationPrefix: String
        public var websitePrefix: String
        public var inputKindPrefix: String
        public var ocrHeading: String
        public var clipboardHeading: String
        public var inputHistoryHeading: String
        public var assessmentHeading: String
        public var customVoiceHeading: String
        public var suffixHeading: String
        public var textHeading: String

        public init(
            contextHeading: String = "Context:",
            applicationPrefix: String = "- Current application:",
            websitePrefix: String = "- Current website:",
            inputKindPrefix: String = "- Kind of input:",
            ocrHeading: String = "OCR content from snapshot:",
            clipboardHeading: String = "Clipboard content:",
            inputHistoryHeading: String = "Relevant input history:",
            assessmentHeading: String = "User voice assessment:",
            customVoiceHeading: String = "Custom voice:",
            suffixHeading: String = "Text after the cursor:",
            textHeading: String = "Text to continue:"
        ) {
            self.contextHeading = contextHeading
            self.applicationPrefix = applicationPrefix
            self.websitePrefix = websitePrefix
            self.inputKindPrefix = inputKindPrefix
            self.ocrHeading = ocrHeading
            self.clipboardHeading = clipboardHeading
            self.inputHistoryHeading = inputHistoryHeading
            self.assessmentHeading = assessmentHeading
            self.customVoiceHeading = customVoiceHeading
            self.suffixHeading = suffixHeading
            self.textHeading = textHeading
        }
    }

    public var context: ContextOptions
    public var voice: VoiceOptions
    public var systemInstruction: String
    public var completionInstruction: String
    public var framing: Framing
    public var debugMode: Bool

    public init(
        context: ContextOptions = .init(),
        voice: VoiceOptions = .init(),
        systemInstruction: String = Self.defaultSystemInstruction,
        completionInstruction: String = Self.defaultCompletionInstruction,
        framing: Framing = .init(),
        debugMode: Bool = false
    ) {
        self.context = context
        self.voice = voice
        self.systemInstruction = systemInstruction
        self.completionInstruction = completionInstruction
        self.framing = framing
        self.debugMode = debugMode
    }

    public static let defaultSystemInstruction =
        "Continue the user's current text at the cursor. Match their voice. "
        + "Produce only text that should be inserted."

    public static let defaultCompletionInstruction =
        "Continue the following text from the cursor. Match the user's voice. "
        + "Produce only what should be inserted."

    public static let defaults = PromptConfiguration()
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
