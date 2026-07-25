import Foundation

enum PromptResources {
    static let baseOpeningInstruction = load("Base/00-opening-instruction")
    static let baseFocusedContextHeading =
        load("Base/01-focused-context-heading")
    static let baseWritingPrefix = load("Base/01a-focused-activity-prefix")
    static let baseWebsiteConnector =
        load("Base/01b-focused-website-connector")
    static let baseApplicationConnector =
        load("Base/01c-focused-application-connector")
    static let inputHistoryHeading =
        load("Base/02-frecent-examples-heading")
    static let seedExamplesHeading = load("Base/02a-seed-fallback-heading")
    static let relevantInputHistoryHeading =
        load("Base/03-relevant-examples-heading")
    static let assessmentHeading = load("Base/04-assessment-heading")
    static let customVoiceHeading =
        load("Base/05-custom-personalization-heading")
    static let basePerspectiveFix = load("Base/06-perspective-fix")
    static let ocrHeading = load("Base/07-ocr-heading")
    static let clipboardHeading = load("Base/08-clipboard-heading")
    static let baseFinalBoundary = load("Base/09-final-boundary")
    static let baseWritingHeading = load("Base/10-writing-heading")
    static let baseExamplePrefix = load("Base/10a-writing-marker")
    static let seedWritingExamples = loadDirectory("Seed/Examples")

    static let chatSystemInstruction = load("Chat/00-system-instruction")

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
