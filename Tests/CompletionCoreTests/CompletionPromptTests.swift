import CompletionCore
import XCTest

final class CompletionPromptTests: XCTestCase {
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
        XCTAssertTrue(prompt.contains("Application I am typing in: ChatGPT"))
        XCTAssertTrue(prompt.contains("Website I am typing on: chatgpt.com"))
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

    func testDebugFramingChangesBothRequestStyles() {
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
