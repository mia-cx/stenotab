import Foundation

enum PromptResources {
    static let basePreamble = load("Base/preamble")
    static let baseWritingHeading = load("Base/writing-heading")
    static let baseBeforeCursorHeading = load("Base/before-cursor-heading")
    static let baseCurrentPartHeading = load("Base/current-part-heading")
    static let seedExamplesHeading = load("Seed/heading")
    static let seedWritingExamples = loadDirectory("Seed/Examples")

    static let contextHeading = load("Context/context-heading")
    static let applicationPrefix = load("Context/application-prefix")
    static let websitePrefix = load("Context/website-prefix")
    static let inputKindPrefix = load("Context/input-kind-prefix")
    static let baseWritingPrefix = load("Context/base-writing-prefix")
    static let baseApplicationConnector =
        load("Context/base-application-connector")
    static let baseWebsiteConnector =
        load("Context/base-website-connector")
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
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            preconditionFailure("Missing prompt resource: \(path).md")
        }
        return removingConventionalEOFNewline(from: contents)
    }

    private static func loadDirectory(_ path: String) -> [String] {
        guard let resourceURL = Bundle.module.resourceURL else {
            preconditionFailure("Prompt resource bundle has no resource URL")
        }
        let directory = resourceURL
            .appending(path: "Prompts", directoryHint: .isDirectory)
            .appending(path: path, directoryHint: .isDirectory)
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            preconditionFailure("Missing prompt resource directory: \(path)")
        }
        let markdownURLs = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        precondition(
            !markdownURLs.isEmpty,
            "Prompt resource directory is empty: \(path)"
        )
        return markdownURLs.map { url in
            guard let contents = try? String(contentsOf: url, encoding: .utf8)
            else {
                preconditionFailure(
                    "Unreadable prompt resource: \(url.lastPathComponent)"
                )
            }
            return removingConventionalEOFNewline(from: contents)
        }
    }

    private static func removingConventionalEOFNewline(
        from value: String
    ) -> String {
        var contents = value
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
