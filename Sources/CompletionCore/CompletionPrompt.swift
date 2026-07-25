import Foundation

public struct CompletionContext: Sendable, Equatable {
    public let applicationName: String?
    public let website: String?
    public let inputKind: String?
    public let ocrContent: String?
    public let clipboardContent: String?
    public let inputHistory: String?
    public let relevantInputHistory: String?
    public let voiceAssessment: String?

    public init(
        applicationName: String? = nil,
        website: String? = nil,
        inputKind: String? = nil,
        ocrContent: String? = nil,
        clipboardContent: String? = nil,
        inputHistory: String? = nil,
        relevantInputHistory: String? = nil,
        voiceAssessment: String? = nil
    ) {
        self.applicationName = applicationName
        self.website = website
        self.inputKind = inputKind
        self.ocrContent = ocrContent
        self.clipboardContent = clipboardContent
        self.inputHistory = inputHistory
        self.relevantInputHistory = relevantInputHistory
        self.voiceAssessment = voiceAssessment
    }
}

public enum CompletionPrompt {
    private static let baseBeforeCursorHeading =
        PromptResources.baseBeforeCursorHeading
    private static let baseCurrentPartHeading =
        PromptResources.baseCurrentPartHeading
    private static let seedExamplesHeading =
        PromptResources.seedExamplesHeading
    private static let seedWritingExamples =
        PromptResources.seedWritingExamples
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
            useFirstPersonApplicationContext: false,
            includeSeedExamples: false
        )
        let baseSections = contextSections(
            context,
            configuration: configuration,
            useFirstPersonApplicationContext: true,
            includeSeedExamples: shouldIncludeSeedExamples(
                context,
                configuration: configuration
            )
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
                configuration: configuration
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
                useFirstPersonApplicationContext: false,
                includeSeedExamples: false
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
                useFirstPersonApplicationContext: true,
                includeSeedExamples: shouldIncludeSeedExamples(
                    context,
                    configuration: configuration
                )
            ),
            configuration: configuration
        )
    }

    private static func base(
        prefix: String,
        suffix: String,
        contextSections: [String],
        configuration: PromptConfiguration
    ) -> String {
        var sections: [String] = []
        if
            configuration.base.includeOpeningInstruction,
            let opening = nonempty(
                configuration.baseFraming.openingInstruction
            )
        {
            sections.append(opening)
        }
        sections.append(contentsOf: contextSections)
        if
            configuration.base.includeFinalBoundary,
            let finalBoundary = nonempty(
                configuration.baseFraming.finalBoundary
            )
        {
            sections.append(finalBoundary)
        }

        if suffix.isEmpty {
            sections.append(
                writingSection(
                    prefix,
                    heading: configuration.baseFraming.writingHeading,
                    examplePrefix: configuration.baseFraming.examplePrefix,
                    includeFraming:
                        configuration.base.includeWritingHeading
                )
            )
        } else {
            sections.append(
                framedLiteralText(
                    prefix,
                    heading: baseBeforeCursorHeading,
                    examplePrefix: configuration.baseFraming.examplePrefix
                )
            )
            sections.append(
                "\(configuration.framing.suffixHeading)\n\(suffix)"
            )
            sections.append(
                framedLiteralText(
                    currentPart(of: prefix),
                    heading: baseCurrentPartHeading,
                    examplePrefix: configuration.baseFraming.examplePrefix
                )
            )
        }
        return sections.joined(separator: "\n\n")
    }

    private static func seedExamplesSection(
        configuration: PromptConfiguration
    ) -> String {
        let examples = seedWritingExamples.map {
            configuration.baseFraming.examplePrefix + $0
        }
        return seedExamplesHeading + "\n\n"
            + examples.joined(separator: "\n\n")
    }

    public static func previewExample(
        configuration: PromptConfiguration
    ) -> ComposedCompletionPrompt {
        compose(
            prefix: "oh nice, I didn't realise",
            suffix: "",
            context: CompletionContext(
                applicationName: "Safari",
                website: "youtube.com",
                inputKind: "comment",
                ocrContent:
                    "Alex: This shortcut stopped working after the latest "
                    + "macOS update. Has anyone found a fix?\n\n"
                    + "Robin: Removing the old Accessibility entry and adding "
                    + "the newly signed app fixed it for me.",
                clipboardContent:
                    "The app needs a stable signing identity so macOS can "
                    + "preserve Accessibility consent between builds.",
                inputHistory:
                    "yeah, deleting the stale permission entry fixed it for "
                    + "me too\n\n"
                    + "I think the signature changed between those two builds.",
                relevantInputHistory:
                    "yeah, re-adding the signed build fixed Accessibility "
                    + "permissions here too",
                voiceAssessment:
                    "I usually write concise, conversational replies. I use "
                    + "lowercase for casual messages, contractions, direct "
                    + "questions, and technical terminology when it is relevant."
            ),
            configuration: configuration
        )
    }

    private static func contextSections(
        _ context: CompletionContext,
        configuration: PromptConfiguration,
        useFirstPersonApplicationContext: Bool,
        includeSeedExamples: Bool
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
        if useFirstPersonApplicationContext {
            if
                configuration.base.includeFocusedContext,
                let sentence = firstPersonApplicationContext(
                    context,
                    configuration: configuration
                )
            {
                sections.append(
                    configuration.baseFraming.focusedContextHeading
                        + "\n\n"
                        + sentence
                )
            }
        } else if !lines.isEmpty {
            sections.append(
                "\(framing.contextHeading)\n"
                    + lines.joined(separator: "\n")
            )
        }
        if includeSeedExamples {
            sections.append(seedExamplesSection(configuration: configuration))
        }
        if configuration.voice.includeInputHistory {
            appendExamplesSection(
                title: framing.inputHistoryHeading,
                value: context.inputHistory,
                limit: 3_000,
                examplePrefix: useFirstPersonApplicationContext
                    ? configuration.baseFraming.examplePrefix
                    : "",
                to: &sections
            )
        }
        if configuration.voice.includeRelevantInputHistory {
            appendExamplesSection(
                title:
                    configuration.baseFraming.relevantInputHistoryHeading,
                value: context.relevantInputHistory,
                limit: 3_000,
                examplePrefix: useFirstPersonApplicationContext
                    ? configuration.baseFraming.examplePrefix
                    : "",
                to: &sections
            )
        }
        if configuration.voice.includePeriodicAssessments {
            appendOptionalSection(
                title: framing.assessmentHeading,
                value: context.voiceAssessment,
                limit: 1_500,
                valueOnNewParagraph: useFirstPersonApplicationContext,
                to: &sections
            )
        }
        if configuration.voice.includeCustomVoice {
            appendOptionalSection(
                title: framing.customVoiceHeading,
                value: configuration.voice.customVoice,
                limit: 2_000,
                valueOnNewParagraph: useFirstPersonApplicationContext,
                to: &sections
            )
        }
        if
            useFirstPersonApplicationContext,
            configuration.base.includePerspectiveFix,
            let perspectiveFix = nonempty(
                configuration.baseFraming.perspectiveFix
            )
        {
            sections.append(perspectiveFix)
        }
        if options.includeOCR {
            appendOptionalSection(
                title: framing.ocrHeading,
                value: context.ocrContent,
                limit: 4_000,
                valueOnNewParagraph: useFirstPersonApplicationContext,
                to: &sections
            )
        }
        if options.includeClipboard {
            appendOptionalSection(
                title: framing.clipboardHeading,
                value: context.clipboardContent,
                limit: 2_000,
                valueOnNewParagraph: useFirstPersonApplicationContext,
                to: &sections
            )
        }
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

        var sentence = configuration.baseFraming.focusedActivityPrefix
        if let inputKind {
            sentence += " \(inputKind)"
        }
        if let website {
            sentence += " \(configuration.baseFraming.focusedWebsiteConnector)"
                + " \(website)"
        }
        if let applicationName {
            sentence +=
                " \(configuration.baseFraming.focusedApplicationConnector)"
                + " \(applicationName)"
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
        valueOnNewParagraph: Bool = false,
        to sections: inout [String]
    ) {
        guard let value = bounded(value, limit: limit) else { return }
        if let title = nonempty(title) {
            let separator = valueOnNewParagraph ? "\n\n" : "\n"
            sections.append("\(title)\(separator)\(value)")
        } else {
            sections.append(value)
        }
    }

    private static func appendExamplesSection(
        title: String,
        value: String?,
        limit: Int,
        examplePrefix: String,
        to sections: inout [String]
    ) {
        guard let value = bounded(value, limit: limit) else { return }
        let examples = value
            .components(separatedBy: "\n\n")
            .compactMap(nonempty)
            .map { examplePrefix + $0 }
        guard !examples.isEmpty else { return }
        sections.append(
            title + "\n\n" + examples.joined(separator: "\n\n")
        )
    }

    private static func writingSection(
        _ prefix: String,
        heading: String,
        examplePrefix: String,
        includeFraming: Bool
    ) -> String {
        guard includeFraming else { return prefix }
        return heading + "\n" + examplePrefix + prefix
    }

    private static func framedLiteralText(
        _ value: String,
        heading: String,
        examplePrefix: String
    ) -> String {
        heading + "\n" + examplePrefix + value
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
        configuration.voice.includeInputHistory
            && nonempty(context.inputHistory) == nil
    }

    private static func currentPart(of prefix: String) -> String {
        let limit = 500
        guard prefix.count > limit else { return prefix }
        return String(prefix.suffix(limit))
    }
}
