import CompletionCore
import XCTest

final class CompletionPromptTests: XCTestCase {
    func testUnavailableContextSourcesDefaultOff() {
        let defaults = PromptConfiguration.defaults

        XCTAssertFalse(defaults.context.includeCurrentWebsite)
        XCTAssertFalse(defaults.context.includeOCR)
        XCTAssertFalse(defaults.voice.includeInputHistory)
        XCTAssertFalse(defaults.voice.includePeriodicAssessments)
    }

    func testDefaultChatPromptKeepsContextSeparateFromLiteralUserText() {
        let context = CompletionContext(
            applicationName: "Discord",
            website: nil,
            inputKind: "message box",
            clipboardContent: "private clipboard"
        )

        let composed = CompletionPrompt.compose(
            prefix: "Do anyt",
            suffix: "",
            context: context,
            configuration: .defaults
        )

        XCTAssertEqual(
            composed.systemMessage,
            "Continue the user's current text at the cursor. Match their voice. "
                + "Produce only text that should be inserted."
        )
        XCTAssertTrue(
            composed.userMessage.contains("Application I am typing in: Discord")
        )
        XCTAssertTrue(
            composed.userMessage.contains("Kind of input I am typing in: message box")
        )
        XCTAssertTrue(composed.userMessage.hasSuffix("Text to continue:\nDo anyt"))
        XCTAssertFalse(composed.userMessage.contains("private clipboard"))
    }

    func testBasePromptUsesFirstPersonContinuationFraming() {
        var configuration = PromptConfiguration.defaults
        configuration.context.includeCurrentWebsite = true
        configuration.context.includeClipboard = true
        configuration.voice.customVoice = "Use concise sentences."
        let context = CompletionContext(
            applicationName: "ChatGPT",
            website: "chatgpt.com",
            inputKind: "message box",
            clipboardContent: "Relevant copied text"
        )

        let prompt = CompletionPrompt.base(
            prefix: "this sounds like me",
            suffix: "after the caret",
            context: context,
            configuration: configuration
        )

        XCTAssertTrue(prompt.hasPrefix(
            "I am typing the text at the end on my Mac. "
                + "Additional context; some of it could be irrelevant:"
        ))
        XCTAssertTrue(prompt.contains(
            "I'm writing a message on chatgpt.com in ChatGPT."
        ))
        XCTAssertFalse(prompt.contains("Application I am typing in:"))
        XCTAssertFalse(prompt.contains("Kind of input I am typing in:"))
        XCTAssertTrue(prompt.contains("Relevant copied text"))
        XCTAssertTrue(prompt.contains("My writing style:\nUse concise sentences."))
        XCTAssertTrue(prompt.contains(
            "What comes right after the part I am currently typing:\n"
                + "after the caret"
        ))
        XCTAssertTrue(prompt.hasSuffix(
            "The part of my writing I am currently typing:\n"
                + "this sounds like me"
        ))
        XCTAssertFalse(prompt.contains("Text to continue:"))
        XCTAssertFalse(prompt.contains("Task:"))
        XCTAssertFalse(prompt.contains("Insertion:"))
        XCTAssertFalse(prompt.contains(configuration.completionInstruction))
    }

    func testEveryPromptComponentCanBeDisabledIndependently() {
        var configuration = PromptConfiguration.defaults
        configuration.context.includeCurrentApplication = false
        configuration.context.includeCurrentWebsite = false
        configuration.context.includeInputKind = false
        configuration.context.includeOCR = false
        configuration.context.includeClipboard = false
        configuration.voice.includeInputHistory = false
        configuration.voice.includePeriodicAssessments = false

        let composed = CompletionPrompt.compose(
            prefix: "hello",
            suffix: "",
            context: CompletionContext(
                applicationName: "Discord",
                website: "discord.com",
                inputKind: "message box",
                ocrContent: "OCR",
                clipboardContent: "Clipboard",
                inputHistory: "History",
                voiceAssessment: "Assessment"
            ),
            configuration: configuration
        )

        for excluded in [
            "Discord",
            "discord.com",
            "message box",
            "OCR",
            "Clipboard",
            "History",
            "Assessment",
        ] {
            XCTAssertFalse(composed.userMessage.contains(excluded))
            XCTAssertFalse(composed.textCompletionPrompt.contains(excluded))
        }
    }

    func testStructuredFramingChangesChatWhileBaseUsesFirstPersonContext() {
        var configuration = PromptConfiguration.defaults
        configuration.framing.applicationPrefix = "Working inside:"
        configuration.framing.textHeading = "Literal user text:"

        let composed = CompletionPrompt.compose(
            prefix: "ship it",
            suffix: "",
            context: CompletionContext(applicationName: "Xcode"),
            configuration: configuration
        )

        XCTAssertTrue(composed.userMessage.contains("Working inside: Xcode"))
        XCTAssertTrue(composed.userMessage.contains("Literal user text:\nship it"))
        XCTAssertTrue(
            composed.textCompletionPrompt.contains("I'm writing in Xcode.")
        )
        XCTAssertFalse(
            composed.textCompletionPrompt.contains("Working inside: Xcode")
        )
        XCTAssertTrue(
            composed.textCompletionPrompt.hasSuffix("My writing:\nship it")
        )
    }

    func testBasePromptPreservesTrailingWhitespaceInLiteralUserText() {
        let prompt = CompletionPrompt.base(
            prefix: "hello  ",
            suffix: "",
            context: CompletionContext(),
            configuration: .defaults
        )

        XCTAssertTrue(
            prompt.hasSuffix("My writing:\nhello  ")
        )
    }

    func testBasePromptEndsDirectlyOnLiteralInputWithoutACue() {
        let prompt = CompletionPrompt.base(
            prefix: "Do anyt",
            suffix: "",
            context: CompletionContext(),
            configuration: .defaults
        )

        XCTAssertTrue(prompt.hasSuffix("My writing:\nDo anyt"))
        XCTAssertFalse(prompt.contains("What comes next:"))
        XCTAssertFalse(prompt.contains("Continue the"))
    }

    func testBasePromptUsesBundledSeedWritingUntilHistoryIsAvailable() {
        let seeded = CompletionPrompt.base(
            prefix: "yo what's up",
            suffix: "",
            context: CompletionContext(),
            configuration: .defaults
        )

        XCTAssertTrue(seeded.contains("Some examples of my writing:"))
        XCTAssertTrue(seeded.contains("My writing:\nhey, are you around later?"))
        XCTAssertTrue(seeded.contains(
            "My writing:\nI'm not sure why it's doing that."
        ))
        XCTAssertTrue(seeded.hasSuffix("My writing:\nyo what's up"))

        var withHistory = PromptConfiguration.defaults
        withHistory.voice.includeInputHistory = true
        let personalized = CompletionPrompt.base(
            prefix: "yo what's up",
            suffix: "",
            context: CompletionContext(
                inputHistory: "yo, did you see the update?"
            ),
            configuration: withHistory
        )

        XCTAssertFalse(personalized.contains("Some examples of my writing:"))
        XCTAssertFalse(personalized.contains("hey, are you around later?"))
        XCTAssertTrue(personalized.contains(
            "Recent examples of my writing:\nyo, did you see the update?"
        ))
    }

    func testChatPromptDoesNotReceiveLocalBaseModelSeeds() {
        let userMessage = CompletionPrompt.chatUser(
            prefix: "yo what's up",
            suffix: "",
            context: CompletionContext(),
            configuration: .defaults
        )

        XCTAssertFalse(userMessage.contains("Some examples of my writing:"))
        XCTAssertFalse(userMessage.contains("hey, are you around later?"))
    }

    func testBundledMarkdownProvidesEveryPromptDefault() {
        let configuration = PromptConfiguration.defaults

        XCTAssertEqual(
            configuration.systemInstruction,
            "Continue the user's current text at the cursor. Match their voice. "
                + "Produce only text that should be inserted."
        )
        XCTAssertEqual(
            configuration.completionInstruction,
            "Continue the following text from the cursor. Match the user's voice. "
                + "Produce only what should be inserted."
        )
        XCTAssertEqual(
            configuration.framing.applicationPrefix,
            "- Application I am typing in:"
        )
        XCTAssertEqual(
            configuration.framing.suffixHeading,
            "What comes right after the part I am currently typing:"
        )
        XCTAssertFalse(configuration.framing.textHeading.hasSuffix("\n"))

        let prompt = CompletionPrompt.base(
            prefix: "hello",
            suffix: "",
            context: CompletionContext(),
            configuration: configuration
        )
        XCTAssertTrue(prompt.hasPrefix(
            "I am typing the text at the end on my Mac. "
                + "Additional context; some of it could be irrelevant:"
        ))
        XCTAssertTrue(prompt.hasSuffix("My writing:\nhello"))
    }

    func testPromptOverridesFollowNewDefaultsForUntouchedComponents() throws {
        let originalDefaults = PromptConfiguration.defaults
        var customized = originalDefaults
        customized.framing.clipboardHeading = "Copied reference:"

        let overrides = PromptConfiguration.Overrides(
            configuration: customized,
            relativeTo: originalDefaults
        )
        let data = try JSONEncoder().encode(overrides)
        let restored = try JSONDecoder().decode(
            PromptConfiguration.Overrides.self,
            from: data
        )

        var newerDefaults = originalDefaults
        newerDefaults.framing.applicationPrefix = "I am working in:"
        newerDefaults.systemInstruction = "A newer chat instruction."
        let resolved = restored.applying(to: newerDefaults)

        XCTAssertEqual(resolved.framing.clipboardHeading, "Copied reference:")
        XCTAssertEqual(resolved.framing.applicationPrefix, "I am working in:")
        XCTAssertEqual(resolved.systemInstruction, "A newer chat instruction.")
    }

    func testDefaultPromptConfigurationProducesNoStoredOverrides() {
        let defaults = PromptConfiguration.defaults
        let overrides = PromptConfiguration.Overrides(
            configuration: defaults,
            relativeTo: defaults
        )

        XCTAssertTrue(overrides.isEmpty)
    }

    func testPromptConfigurationPersistsEveryUserEditableSetting() throws {
        var configuration = PromptConfiguration.defaults
        configuration.context.includeCurrentApplication = false
        configuration.context.includeOCR = true
        configuration.context.includeClipboard = true
        configuration.voice.includeInputHistory = true
        configuration.voice.includePeriodicAssessments = true
        configuration.voice.customVoice = "Use my punctuation."
        configuration.systemInstruction = "System"
        configuration.completionInstruction = "Complete"
        configuration.framing.clipboardHeading = "Copied reference:"
        configuration.debugMode = true

        let data = try JSONEncoder().encode(configuration)
        let restored = try JSONDecoder().decode(
            PromptConfiguration.self,
            from: data
        )

        XCTAssertEqual(restored, configuration)
    }

}
