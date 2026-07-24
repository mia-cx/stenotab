import Foundation

enum PromptResources {
    static let basePreamble = load("Base/preamble")
    static let baseWritingHeading = load("Base/writing-heading")
    static let baseBeforeCursorHeading = load("Base/before-cursor-heading")
    static let baseCurrentPartHeading = load("Base/current-part-heading")

    static let contextHeading = load("Context/context-heading")
    static let applicationPrefix = load("Context/application-prefix")
    static let websitePrefix = load("Context/website-prefix")
    static let inputKindPrefix = load("Context/input-kind-prefix")
    static let ocrHeading = load("Context/ocr-heading")
    static let clipboardHeading = load("Context/clipboard-heading")
    static let inputHistoryHeading = load("Context/input-history-heading")
    static let assessmentHeading = load("Context/assessment-heading")
    static let customVoiceHeading = load("Context/custom-voice-heading")
    static let suffixHeading = load("Context/suffix-heading")

    static let chatSystemInstruction = load("Chat/system-instruction")
    static let chatCompletionInstruction = load("Chat/completion-instruction")
    static let chatTextHeading = load("Chat/text-heading")

    private static func load(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        precondition(parts.count == 2, "Invalid prompt resource path: \(path)")
        let subdirectory = "Prompts/\(parts[0])"
        let name = String(parts[1])
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: "md",
                subdirectory: subdirectory
            ),
            var contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            preconditionFailure("Missing prompt resource: \(path).md")
        }

        // Editors conventionally add one EOF newline. Composition owns the
        // separators between components, so remove only that single newline
        // while preserving every other character in the resource.
        if contents.hasSuffix("\n") {
            contents.removeLast()
            if contents.hasSuffix("\r") {
                contents.removeLast()
            }
        }
        return contents
    }
}
