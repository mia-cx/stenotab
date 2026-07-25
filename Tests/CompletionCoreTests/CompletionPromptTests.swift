import CompletionCore
import XCTest

final class CompletionPromptTests: XCTestCase {
    func testUnavailableContextSourcesUseOnlyTheSeedFallbackByDefault() {
        let defaults = PromptConfiguration.defaults

        XCTAssertFalse(defaults.context.includeCurrentWebsite)
        XCTAssertFalse(defaults.context.includeOCR)
        XCTAssertTrue(defaults.voice.includeInputHistory)
        XCTAssertFalse(defaults.voice.includeRelevantInputHistory)
        XCTAssertFalse(defaults.voice.includePeriodicAssessments)
    }

    func testChatAndLocalModelsReceiveTheSameCanonicalUserPrompt() {
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
        XCTAssertEqual(composed.userMessage, composed.textCompletionPrompt)
        XCTAssertTrue(composed.userMessage.contains(
            "I am writing a message in Discord."
        ))
        XCTAssertTrue(composed.userMessage.hasSuffix("My writing:\n§Do anyt"))
        XCTAssertFalse(composed.userMessage.contains("private clipboard"))
        XCTAssertFalse(composed.userMessage.contains("Application I am typing in:"))
        XCTAssertFalse(composed.userMessage.contains("Text to continue:"))
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
            "I am typing the text at the end of this document on my computer."
                + "\n\nSome additional context that may or may not be "
                + "relevant to my writing:"
        ))
        XCTAssertTrue(prompt.contains(
            "I am writing a message on chatgpt.com in ChatGPT."
        ))
        XCTAssertFalse(prompt.contains("Application I am typing in:"))
        XCTAssertFalse(prompt.contains("Kind of input I am typing in:"))
        XCTAssertTrue(prompt.contains("Relevant copied text"))
        XCTAssertTrue(prompt.contains(
            "I describe myself like this:\n\nUse concise sentences."
        ))
        XCTAssertFalse(prompt.contains("after the caret"))
        XCTAssertFalse(prompt.contains("part I am currently typing"))
        XCTAssertTrue(prompt.hasSuffix(
            "My writing:\n§this sounds like me"
        ))
        XCTAssertFalse(prompt.contains("Text to continue:"))
        XCTAssertFalse(prompt.contains("Task:"))
        XCTAssertFalse(prompt.contains("Insertion:"))
    }

    func testBasePromptMatchesWorkshoppedFullSample() {
        var configuration = PromptConfiguration.defaults
        configuration.context.includeCurrentWebsite = true
        configuration.context.includeOCR = true
        configuration.context.includeClipboard = true
        configuration.voice.includeInputHistory = true
        configuration.voice.includePeriodicAssessments = true

        let prompt = CompletionPrompt.base(
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
                voiceAssessment:
                    "I usually write concise, conversational replies. I use "
                    + "lowercase for casual messages, contractions, direct "
                    + "questions, and technical terminology when it is relevant."
            ),
            configuration: configuration
        )

        XCTAssertEqual(
            prompt,
            """
            I am typing the text at the end of this document on my computer.

            Some additional context that may or may not be relevant to my writing:

            I am writing a comment on youtube.com in Safari.

            I have recently written text like:

            §yeah, deleting the stale permission entry fixed it for me too

            §I think the signature changed between those two builds.

            I have noticed that my writing typically looks like this:

            I usually write concise, conversational replies. I use lowercase for casual messages, contractions, direct questions, and technical terminology when it is relevant.

            I am not an assistant and won't explain more than what the conversation requires.

            Some text that is visible on the screen around where I am typing:

            Alex: This shortcut stopped working after the latest macOS update. Has anyone found a fix?

            Robin: Removing the old Accessibility entry and adding the newly signed app fixed it for me.

            I have this saved to my clipboard:

            The app needs a stable signing identity so macOS can preserve Accessibility consent between builds.

            From this point forward I will only write real text.

            My writing:
            §oh nice, I didn't realise
            """
        )
    }

    func testEveryPromptComponentCanBeDisabledIndependently() {
        var configuration = PromptConfiguration.defaults
        configuration.context.includeCurrentApplication = false
        configuration.context.includeCurrentWebsite = false
        configuration.context.includeInputKind = false
        configuration.context.includeOCR = false
        configuration.context.includeClipboard = false
        configuration.voice.includeInputHistory = false
        configuration.voice.includeRelevantInputHistory = false
        configuration.voice.includePeriodicAssessments = false
        configuration.voice.includeCustomVoice = false
        configuration.voice.customVoice = "Custom preference"
        configuration.base.includeOpeningInstruction = false
        configuration.base.includeFocusedContext = false
        configuration.base.includePerspectiveFix = false
        configuration.base.includeFinalBoundary = false
        configuration.base.includeWritingHeading = false

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
                relevantInputHistory: "Relevant history",
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
            "Relevant history",
            "Assessment",
            "Custom preference",
            "I am typing the text at the end",
            "From this point forward",
            "I am not an assistant",
            "My writing:",
        ] {
            XCTAssertFalse(composed.userMessage.contains(excluded))
            XCTAssertFalse(composed.textCompletionPrompt.contains(excluded))
        }
    }

    func testFrecentAndSemanticExamplesAreSeparateOrderedComponents() {
        var configuration = PromptConfiguration.defaults
        configuration.voice.includeInputHistory = true
        configuration.voice.includeRelevantInputHistory = true
        configuration.voice.includePeriodicAssessments = true

        let prompt = CompletionPrompt.base(
            prefix: "that fixed it",
            suffix: "",
            context: CompletionContext(
                inputHistory: "recent one\n\nrecent two",
                relevantInputHistory: "similar one\n\nsimilar two",
                voiceAssessment: "I usually write short replies."
            ),
            configuration: configuration
        )

        let frecent = """
        I have recently written text like:

        §recent one

        §recent two
        """
        let relevant = """
        Other relevant examples of my writing are:

        §similar one

        §similar two
        """
        XCTAssertTrue(prompt.contains(frecent))
        XCTAssertTrue(prompt.contains(relevant))
        XCTAssertLessThan(
            try XCTUnwrap(prompt.range(of: frecent)?.lowerBound),
            try XCTUnwrap(prompt.range(of: relevant)?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(prompt.range(of: relevant)?.lowerBound),
            try XCTUnwrap(
                prompt.range(
                    of: "I have noticed that my writing typically looks like this:"
                )?.lowerBound
            )
        )
    }

    func testRetrievedTextInsertionPairsAreNotPrefixedOrSplitAgain() {
        var configuration = PromptConfiguration.defaults
        configuration.voice.includeInputHistory = true
        let example = PersonalizationExample(
            id: UUID(),
            inputText: "can you open a pull req",
            insertion: "uest for this",
            context: PersonalizationContext(editorIdentifier: "editor"),
            capturedAt: Date(),
            source: .acceptedSuggestion
        )

        let prompt = CompletionPrompt.base(
            prefix: "sure",
            suffix: "",
            context: CompletionContext(
                inputHistory: PersonalizationExample.promptValue(
                    from: [example]
                )
            ),
            configuration: configuration
        )

        XCTAssertTrue(prompt.contains(example.promptText))
        XCTAssertFalse(prompt.contains("§Text:"))
        XCTAssertEqual(
            prompt.components(separatedBy: example.promptText).count,
            2
        )
    }

    func testEveryBaseFramingToggleControlsOnlyItsOwnComponent() {
        let context = CompletionContext(
            applicationName: "Safari",
            website: "youtube.com",
            inputKind: "comment"
        )

        var noOpening = PromptConfiguration.defaults
        noOpening.base.includeOpeningInstruction = false
        let openingPrompt = CompletionPrompt.base(
            prefix: "hello",
            suffix: "",
            context: context,
            configuration: noOpening
        )
        XCTAssertFalse(openingPrompt.contains(
            noOpening.baseFraming.openingInstruction
        ))
        XCTAssertTrue(openingPrompt.contains(
            noOpening.baseFraming.focusedContextHeading
        ))

        var noFocusedContext = PromptConfiguration.defaults
        noFocusedContext.base.includeFocusedContext = false
        let focusedPrompt = CompletionPrompt.base(
            prefix: "hello",
            suffix: "",
            context: context,
            configuration: noFocusedContext
        )
        XCTAssertFalse(focusedPrompt.contains(
            noFocusedContext.baseFraming.focusedContextHeading
        ))
        XCTAssertTrue(focusedPrompt.contains(
            noFocusedContext.baseFraming.perspectiveFix
        ))

        var noPerspective = PromptConfiguration.defaults
        noPerspective.base.includePerspectiveFix = false
        let perspectivePrompt = CompletionPrompt.base(
            prefix: "hello",
            suffix: "",
            context: context,
            configuration: noPerspective
        )
        XCTAssertFalse(perspectivePrompt.contains(
            noPerspective.baseFraming.perspectiveFix
        ))
        XCTAssertTrue(perspectivePrompt.contains(
            noPerspective.baseFraming.finalBoundary
        ))

        var noBoundary = PromptConfiguration.defaults
        noBoundary.base.includeFinalBoundary = false
        let boundaryPrompt = CompletionPrompt.base(
            prefix: "hello",
            suffix: "",
            context: context,
            configuration: noBoundary
        )
        XCTAssertFalse(boundaryPrompt.contains(
            noBoundary.baseFraming.finalBoundary
        ))
        XCTAssertTrue(boundaryPrompt.hasSuffix("My writing:\n§hello"))

        var noWritingMarker = PromptConfiguration.defaults
        noWritingMarker.base.includeWritingHeading = false
        let markerPrompt = CompletionPrompt.base(
            prefix: "hello",
            suffix: "",
            context: context,
            configuration: noWritingMarker
        )
        XCTAssertFalse(markerPrompt.contains("My writing:"))
        XCTAssertTrue(markerPrompt.hasSuffix("\n\nhello"))
    }

    func testOCRContextIsIncludedOnlyWhenEnabled() {
        let context = CompletionContext(
            applicationName: "Discord",
            inputKind: "message box",
            ocrContent: "Alex: Are you still free tomorrow?"
        )
        let disabled = CompletionPrompt.compose(
            prefix: "yeah I can",
            suffix: "",
            context: context,
            configuration: .defaults
        )
        var enabledConfiguration = PromptConfiguration.defaults
        enabledConfiguration.context.includeOCR = true
        let enabled = CompletionPrompt.compose(
            prefix: "yeah I can",
            suffix: "",
            context: context,
            configuration: enabledConfiguration
        )

        XCTAssertFalse(
            disabled.textCompletionPrompt.contains(
                "Alex: Are you still free tomorrow?"
            )
        )
        XCTAssertTrue(
            enabled.textCompletionPrompt.contains(
                "Alex: Are you still free tomorrow?"
            )
        )
        XCTAssertTrue(
            enabled.userMessage.contains(
                "Alex: Are you still free tomorrow?"
            )
        )
    }

    func testCanonicalFramingChangesChatAndBaseTogether() {
        var configuration = PromptConfiguration.defaults
        configuration.baseFraming.focusedActivityPrefix = "I am working"
        configuration.baseFraming.focusedApplicationConnector = "inside"
        configuration.baseFraming.writingHeading = "My literal writing:"

        let composed = CompletionPrompt.compose(
            prefix: "ship it",
            suffix: "",
            context: CompletionContext(applicationName: "Xcode"),
            configuration: configuration
        )

        XCTAssertEqual(composed.userMessage, composed.textCompletionPrompt)
        XCTAssertTrue(composed.userMessage.contains(
            "I am working inside Xcode."
        ))
        XCTAssertTrue(
            composed.textCompletionPrompt.hasSuffix(
                "My literal writing:\n§ship it"
            )
        )
    }

    func testAdvancedFocusedContextProseChangesTheBasePrompt() {
        var configuration = PromptConfiguration.defaults
        configuration.context.includeCurrentWebsite = true
        configuration.baseFraming.focusedActivityPrefix = "I am composing"
        configuration.baseFraming.focusedWebsiteConnector = "at"
        configuration.baseFraming.focusedApplicationConnector = "using"

        let prompt = CompletionPrompt.base(
            prefix: "ship it",
            suffix: "",
            context: CompletionContext(
                applicationName: "Safari",
                website: "example.com",
                inputKind: "comment"
            ),
            configuration: configuration
        )

        XCTAssertTrue(prompt.contains(
            "I am composing a comment at example.com using Safari."
        ))
    }

    func testBasePromptPreservesTrailingWhitespaceInLiteralUserText() {
        let prompt = CompletionPrompt.base(
            prefix: "hello  ",
            suffix: "",
            context: CompletionContext(),
            configuration: .defaults
        )

        XCTAssertTrue(
            prompt.hasSuffix("My writing:\n§hello  ")
        )
    }

    func testBasePromptEndsDirectlyOnLiteralInputWithoutACue() {
        let prompt = CompletionPrompt.base(
            prefix: "Do anyt",
            suffix: "",
            context: CompletionContext(),
            configuration: .defaults
        )

        XCTAssertTrue(prompt.hasSuffix("My writing:\n§Do anyt"))
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
        XCTAssertTrue(seeded.contains("§hey, are you around later?"))
        XCTAssertFalse(seeded.contains("I'm not sure why"))
        XCTAssertTrue(seeded.contains("§no worries, that works for me"))
        XCTAssertTrue(seeded.hasSuffix("My writing:\n§yo what's up"))

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
            "I have recently written text like:\n\n"
                + "§yo, did you see the update?"
        ))
    }

    func testChatPromptUsesTheSameSeedFallbackAsTheCanonicalPrompt() {
        let userMessage = CompletionPrompt.chatUser(
            prefix: "yo what's up",
            suffix: "",
            context: CompletionContext(),
            configuration: .defaults
        )

        XCTAssertTrue(userMessage.contains("Some examples of my writing:"))
        XCTAssertTrue(userMessage.contains("§hey, are you around later?"))
    }

    func testBundledMarkdownProvidesEveryPromptDefault() {
        let configuration = PromptConfiguration.defaults

        XCTAssertEqual(
            configuration.systemInstruction,
            "Continue the user's current text at the cursor. Match their voice. "
                + "Produce only text that should be inserted."
        )
        XCTAssertEqual(
            configuration.baseFraming.focusedActivityPrefix,
            "I am writing"
        )
        XCTAssertEqual(configuration.baseFraming.examplePrefix, "§")

        let prompt = CompletionPrompt.base(
            prefix: "hello",
            suffix: "",
            context: CompletionContext(),
            configuration: configuration
        )
        XCTAssertTrue(prompt.hasPrefix(
            "I am typing the text at the end of this document on my computer."
        ))
        XCTAssertTrue(prompt.hasSuffix("My writing:\n§hello"))
    }

    func testPromptOverridesFollowNewDefaultsForUntouchedComponents() throws {
        let originalDefaults = PromptConfiguration.defaults
        var customized = originalDefaults
        customized.baseFraming.clipboardHeading = "Copied reference:"

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
        newerDefaults.baseFraming.focusedActivityPrefix = "I am composing"
        newerDefaults.systemInstruction = "A newer chat instruction."
        let resolved = restored.applying(to: newerDefaults)

        XCTAssertEqual(
            resolved.baseFraming.clipboardHeading,
            "Copied reference:"
        )
        XCTAssertEqual(
            resolved.baseFraming.focusedActivityPrefix,
            "I am composing"
        )
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
        configuration.voice.includeRelevantInputHistory = true
        configuration.voice.includePeriodicAssessments = true
        configuration.voice.includeCustomVoice = false
        configuration.voice.customVoice = "Use my punctuation."
        configuration.base.includeOpeningInstruction = false
        configuration.base.includeFocusedContext = false
        configuration.base.includePerspectiveFix = false
        configuration.base.includeFinalBoundary = false
        configuration.base.includeWritingHeading = false
        configuration.baseFraming.openingInstruction = "Open"
        configuration.baseFraming.focusedContextHeading = "Focus"
        configuration.baseFraming.focusedActivityPrefix = "I compose"
        configuration.baseFraming.focusedWebsiteConnector = "at"
        configuration.baseFraming.focusedApplicationConnector = "using"
        configuration.baseFraming.inputHistoryHeading = "Recent"
        configuration.baseFraming.seedExamplesHeading = "Seeds"
        configuration.baseFraming.relevantInputHistoryHeading = "Similar"
        configuration.baseFraming.assessmentHeading = "Assessment"
        configuration.baseFraming.customVoiceHeading = "About me"
        configuration.baseFraming.perspectiveFix =
            "I will continue as myself."
        configuration.baseFraming.ocrHeading = "Visible"
        configuration.baseFraming.clipboardHeading = "Copied reference:"
        configuration.baseFraming.finalBoundary = "Boundary"
        configuration.baseFraming.writingHeading = "Mine:"
        configuration.baseFraming.examplePrefix = "¶"
        configuration.systemInstruction = "System"
        configuration.debugMode = true

        let data = try JSONEncoder().encode(configuration)
        let restored = try JSONDecoder().decode(
            PromptConfiguration.self,
            from: data
        )

        XCTAssertEqual(restored, configuration)
    }

    func testBasePerspectiveFixPersistsAsAnOverride() throws {
        let defaults = PromptConfiguration.defaults
        var customized = defaults
        customized.baseFraming.perspectiveFix =
            "I will keep writing naturally."

        let overrides = PromptConfiguration.Overrides(
            configuration: customized,
            relativeTo: defaults
        )
        let data = try JSONEncoder().encode(overrides)
        let restored = try JSONDecoder().decode(
            PromptConfiguration.Overrides.self,
            from: data
        )

        XCTAssertEqual(
            restored.applying(to: defaults).baseFraming.perspectiveFix,
            "I will keep writing naturally."
        )
    }

    func testLegacyConfigurationUsesBundledBasePerspectiveFix() throws {
        let restored = try JSONDecoder().decode(
            PromptConfiguration.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(
            restored.baseFraming.perspectiveFix,
            PromptConfiguration.defaults.baseFraming.perspectiveFix
        )
    }

}
