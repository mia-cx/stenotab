import Foundation

public struct CompletionContext: Sendable, Equatable {
    public let applicationName: String?
    public let website: String?
    public let inputKind: String?
    public let ocrContent: String?
    public let clipboardContent: String?
    public let userVoice: String?

    public init(
        applicationName: String? = nil,
        website: String? = nil,
        inputKind: String? = nil,
        ocrContent: String? = nil,
        clipboardContent: String? = nil,
        userVoice: String? = nil
    ) {
        self.applicationName = applicationName
        self.website = website
        self.inputKind = inputKind
        self.ocrContent = ocrContent
        self.clipboardContent = clipboardContent
        self.userVoice = userVoice
    }
}

public enum CompletionPrompt {
    public static let systemInstruction =
        "Continue the user's current text at the cursor. Match their voice. "
        + "Produce only text that should be inserted."

    public static func chatUser(
        prefix: String,
        suffix: String,
        context: CompletionContext
    ) -> String {
        var sections = ["Context:\n" + contextLines(context).joined(separator: "\n")]
        appendOptionalSection(
            title: "OCR content from snapshot:",
            value: context.ocrContent,
            to: &sections
        )
        appendOptionalSection(
            title: "Clipboard content:",
            value: context.clipboardContent,
            to: &sections
        )
        appendOptionalSection(
            title: "User Voice:",
            value: context.userVoice,
            to: &sections
        )
        if !suffix.isEmpty {
            sections.append("Text after the cursor:\n\(suffix)")
        }
        sections.append(
            "Continue the following text, continuing from the cursor. "
                + "Match the user's voice. Produce only what should be inserted.\n"
                + prefix
        )
        return sections.joined(separator: "\n\n")
    }

    /// Base models do not assign higher priority to chat roles. Demonstrations
    /// teach the Text-to-Insertion relationship in-context, while the stable
    /// prefix remains friendly to prompt-cache reuse.
    public static func base(
        prefix: String,
        suffix: String,
        context: CompletionContext
    ) -> String {
        """
        Task: Continue the final Text value. Output only the characters to insert.

        Text: The package should arrive
        Insertion: tomorrow

        Text: lol that was so
        Insertion: weird

        Text: Would you mind
        Insertion: checking this?

        Text: \(prefix)
        Insertion:
        """
    }

    /// A compact lexical task for a word that the system spell checker says is
    /// unfinished. Keeping this separate prevents ordinary continuation from
    /// deciding that `anyt` is a complete token.
    public static func wordSuffix(prefix: String) -> String {
        """
        Text: I will see you tom
        Continuation: orrow

        Text: I am currently ty
        Continuation: ping

        Text: This is incred
        Continuation: ible

        Text: We can do anyth
        Continuation: ing

        Text: \(prefix)
        Continuation:
        """
    }

    private static func contextLines(
        _ context: CompletionContext
    ) -> [String] {
        var lines: [String] = []
        if let applicationName = nonempty(context.applicationName) {
            if let website = nonempty(context.website) {
                lines.append(
                    "- The user is typing in: \(applicationName), on \(website)"
                )
            } else {
                lines.append("- The user is typing in: \(applicationName)")
            }
        } else if let website = nonempty(context.website) {
            lines.append("- The user is typing on: \(website)")
        }
        if let inputKind = nonempty(context.inputKind) {
            lines.append("- Kind of input: \(inputKind)")
        }
        if lines.isEmpty {
            lines.append("- No application metadata is available.")
        }
        return lines
    }

    private static func appendOptionalSection(
        title: String,
        value: String?,
        to sections: inout [String]
    ) {
        guard let value = nonempty(value) else { return }
        sections.append("\(title)\n\(value)")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
