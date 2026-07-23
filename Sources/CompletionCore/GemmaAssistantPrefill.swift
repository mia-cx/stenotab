public enum GemmaAssistantPrefill {
    public static func prompt(prefix: String, suffix: String) -> String {
        let instruction: String
        if suffix.isEmpty {
            instruction =
                "Continue the assistant text naturally. Return only the continuation."
        } else {
            instruction = """
            Continue the assistant text naturally. Return only the continuation.
            Existing text after the cursor: \(suffix)
            """
        }

        return """
        <bos><|turn>user
        \(instruction)<turn|>
        <|turn>model
        \(prefix)
        """
    }
}
