import Foundation

public struct CompletionContext: Sendable, Equatable {
    public let applicationName: String?
    public let website: String?
    public let inputKind: String?
    public let ocrContent: String?
    public let clipboardContent: String?
    public let inputHistory: String?
    public let voiceAssessment: String?

    public init(
        applicationName: String? = nil,
        website: String? = nil,
        inputKind: String? = nil,
        ocrContent: String? = nil,
        clipboardContent: String? = nil,
        inputHistory: String? = nil,
        voiceAssessment: String? = nil
    ) {
        self.applicationName = applicationName
        self.website = website
        self.inputKind = inputKind
        self.ocrContent = ocrContent
        self.clipboardContent = clipboardContent
        self.inputHistory = inputHistory
        self.voiceAssessment = voiceAssessment
    }
}

public enum CompletionPrompt {
    private static let basePromptPrefix = PromptResources.basePreamble
    private static let baseWritingHeading = PromptResources.baseWritingHeading
    private static let baseBeforeCursorHeading =
        PromptResources.baseBeforeCursorHeading
    private static let baseCurrentPartHeading =
        PromptResources.baseCurrentPartHeading
    private static let seedExamplesHeading =
        PromptResources.seedExamplesHeading
    private static let seedWritingExamples =
        PromptResources.seedWritingExamples
    private static let baseWritingPrefix =
        PromptResources.baseWritingPrefix
    private static let baseApplicationConnector =
        PromptResources.baseApplicationConnector
    private static let baseWebsiteConnector =
        PromptResources.baseWebsiteConnector

    public static let systemInstruction =
        PromptConfiguration.defaultSystemInstruction

    public static func compose(
        prefix: String,
        suffix: String,
        context: CompletionContext,
        configuration: PromptConfiguration
    ) -> ComposedCompletionPrompt {
        let chatSections = contextSections(
            context,
            configuration: configuration,
            useFirstPersonApplicationContext: false
        )
        let baseSections = contextSections(
            context,
            configuration: configuration,
            useFirstPersonApplicationContext: true
        )
        let userMessage = chatUser(
            prefix: prefix,
            suffix: suffix,
            contextSections: chatSections,
            configuration: configuration
        )
        return ComposedCompletionPrompt(
            systemMessage: nonempty(configuration.systemInstruction)
                ?? PromptConfiguration.defaultSystemInstruction,
            userMessage: userMessage,
            textCompletionPrompt: base(
                prefix: prefix,
                suffix: suffix,
                contextSections: baseSections,
                configuration: configuration,
                includeSeedExamples: shouldIncludeSeedExamples(
                    context,
                    configuration: configuration
                )
            )
        )
    }

    public static func chatUser(
        prefix: String,
        suffix: String,
        context: CompletionContext,
        configuration: PromptConfiguration = .defaults
    ) -> String {
        chatUser(
            prefix: prefix,
            suffix: suffix,
            contextSections: contextSections(
                context,
                configuration: configuration,
                useFirstPersonApplicationContext: false
            ),
            configuration: configuration
        )
    }

    private static func chatUser(
        prefix: String,
        suffix: String,
        contextSections: [String],
        configuration: PromptConfiguration
    ) -> String {
        var sections = contextSections
        if !suffix.isEmpty {
            sections.append(
                "\(configuration.framing.suffixHeading)\n\(suffix)"
            )
        }
        sections.append(
            [
                normalizedInstruction(configuration.completionInstruction),
                configuration.framing.textHeading,
                prefix,
            ].joined(separator: "\n")
        )
        return sections.joined(separator: "\n\n")
    }

    /// A base causal model is treated as the person doing the writing. The
    /// prompt describes the writer's state in first person, then ends on the
    /// literal text so ordinary next-token prediction produces the insertion.
    public static func base(
        prefix: String,
        suffix: String,
        context: CompletionContext,
        configuration: PromptConfiguration = .defaults
    ) -> String {
        base(
            prefix: prefix,
            suffix: suffix,
            contextSections: contextSections(
                context,
                configuration: configuration,
                useFirstPersonApplicationContext: true
            ),
            configuration: configuration,
            includeSeedExamples: shouldIncludeSeedExamples(
                context,
                configuration: configuration
            )
        )
    }

    private static func base(
        prefix: String,
        suffix: String,
        contextSections: [String],
        configuration: PromptConfiguration,
        includeSeedExamples: Bool
    ) -> String {
        var sections = [basePromptPrefix]
        sections.append(contentsOf: contextSections)
        if includeSeedExamples {
            sections.append(seedExamplesSection)
        }

        if suffix.isEmpty {
            sections.append("\(baseWritingHeading)\n\(prefix)")
        } else {
            sections.append(
                "\(baseBeforeCursorHeading)\n\(prefix)"
            )
            sections.append(
                "\(configuration.framing.suffixHeading)\n\(suffix)"
            )
            sections.append(
                "\(baseCurrentPartHeading)\n\(currentPart(of: prefix))"
            )
        }
        return sections.joined(separator: "\n\n")
    }

    private static var seedExamplesSection: String {
        let examples = seedWritingExamples.map {
            "\(baseWritingHeading)\n\($0)"
        }
        return ([seedExamplesHeading] + examples)
            .joined(separator: "\n\n")
    }

    public static func previewExample(
        configuration: PromptConfiguration
    ) -> ComposedCompletionPrompt {
        compose(
            prefix: "I think the best next step is",
            suffix: "",
            context: CompletionContext(
                applicationName: "Messages",
                website: "example.com",
                inputKind: "message box",
                ocrContent: "Alex: Are you free to look at this tomorrow?",
                clipboardContent: "Draft review at 14:00",
                inputHistory: "that makes sense\nyeah, I can take a look",
                voiceAssessment:
                    "Casual and concise; uses lowercase acknowledgements."
            ),
            configuration: configuration
        )
    }

    private static func contextSections(
        _ context: CompletionContext,
        configuration: PromptConfiguration,
        useFirstPersonApplicationContext: Bool
    ) -> [String] {
        var lines: [String] = []
        let options = configuration.context
        let framing = configuration.framing
        if options.includeCurrentApplication,
           let applicationName = bounded(context.applicationName, limit: 200) {
            lines.append("\(framing.applicationPrefix) \(applicationName)")
        }
        if options.includeCurrentWebsite,
           let website = bounded(context.website, limit: 500) {
            lines.append("\(framing.websitePrefix) \(website)")
        }
        if options.includeInputKind,
           let inputKind = bounded(context.inputKind, limit: 120) {
            lines.append("\(framing.inputKindPrefix) \(inputKind)")
        }
        var sections: [String] = []
        if useFirstPersonApplicationContext,
           let sentence = firstPersonApplicationContext(
               context,
               configuration: configuration
           ) {
            sections.append(sentence)
        } else if !lines.isEmpty {
            sections.append(
                "\(framing.contextHeading)\n"
                    + lines.joined(separator: "\n")
            )
        }
        if options.includeOCR {
            appendOptionalSection(
                title: framing.ocrHeading,
                value: context.ocrContent,
                limit: 4_000,
                to: &sections
            )
        }
        if options.includeClipboard {
            appendOptionalSection(
                title: framing.clipboardHeading,
                value: context.clipboardContent,
                limit: 2_000,
                to: &sections
            )
        }
        if configuration.voice.includeInputHistory {
            appendOptionalSection(
                title: framing.inputHistoryHeading,
                value: context.inputHistory,
                limit: 3_000,
                to: &sections
            )
        }
        if configuration.voice.includePeriodicAssessments {
            appendOptionalSection(
                title: framing.assessmentHeading,
                value: context.voiceAssessment,
                limit: 1_500,
                to: &sections
            )
        }
        appendOptionalSection(
            title: framing.customVoiceHeading,
            value: configuration.voice.customVoice,
            limit: 2_000,
            to: &sections
        )
        return sections
    }

    private static func firstPersonApplicationContext(
        _ context: CompletionContext,
        configuration: PromptConfiguration
    ) -> String? {
        let options = configuration.context
        let applicationName = options.includeCurrentApplication
            ? bounded(context.applicationName, limit: 200)
            : nil
        let website = options.includeCurrentWebsite
            ? bounded(context.website, limit: 500)
            : nil
        let inputKind = options.includeInputKind
            ? inputNounPhrase(context.inputKind)
            : nil
        guard applicationName != nil || website != nil || inputKind != nil else {
            return nil
        }

        var sentence = baseWritingPrefix
        if let inputKind {
            sentence += " \(inputKind)"
        }
        if let website {
            sentence += " \(baseWebsiteConnector) \(website)"
        }
        if let applicationName {
            sentence += " \(baseApplicationConnector) \(applicationName)"
        }
        return sentence + "."
    }

    private static func inputNounPhrase(_ value: String?) -> String? {
        guard let value = nonempty(value)?.lowercased() else { return nil }
        if value.contains("comment") {
            return "a comment"
        }
        if value.contains("reply") {
            return "a reply"
        }
        if value.contains("message")
            || value.contains("chat")
            || value.contains("rich-text") {
            return "a message"
        }
        if value.contains("search") {
            return "a search query"
        }
        if value.contains("email") || value.contains("mail") {
            return "an email"
        }
        if value.contains("document")
            || value.contains("multi-line")
            || value.contains("text area") {
            return "a document"
        }
        if value.contains("code") {
            return "code"
        }
        if value.contains("post") {
            return "a post"
        }
        return "some text"
    }

    private static func appendOptionalSection(
        title: String,
        value: String?,
        limit: Int,
        to sections: inout [String]
    ) {
        guard let value = bounded(value, limit: limit) else { return }
        sections.append("\(title)\n\(value)")
    }

    private static func normalizedInstruction(
        _ value: String,
        fallback: String = PromptConfiguration.defaultCompletionInstruction
    ) -> String {
        nonempty(value) ?? fallback
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        nonempty(value).map { String($0.prefix(limit)) }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shouldIncludeSeedExamples(
        _ context: CompletionContext,
        configuration: PromptConfiguration
    ) -> Bool {
        !configuration.voice.includeInputHistory
            || nonempty(context.inputHistory) == nil
    }

    private static func currentPart(of prefix: String) -> String {
        let limit = 500
        guard prefix.count > limit else { return prefix }
        return String(prefix.suffix(limit))
    }
}
