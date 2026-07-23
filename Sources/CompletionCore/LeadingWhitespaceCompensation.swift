public enum LeadingWhitespaceCompensation {
    /// Chromium-backed editors expose caret geometry but commonly omit the
    /// actual web font. The fallback system font's space advance is narrower
    /// by roughly one eighth of the exposed caret height.
    public static func points(
        for suggestion: String,
        caretHeight: Double,
        isWebBacked: Bool
    ) -> Double {
        guard isWebBacked, caretHeight > 0 else { return 0 }

        let leadingSpaceCount = suggestion.prefix { $0 == " " }.count
        guard leadingSpaceCount > 0 else { return 0 }

        return caretHeight * 0.125 * Double(leadingSpaceCount)
    }
}
