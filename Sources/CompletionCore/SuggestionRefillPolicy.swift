public enum SuggestionRefillPolicy {
    public static func shouldPrefetch(
        remainingSuggestion: String,
        threshold: Int = 2
    ) -> Bool {
        let words = remainingSuggestion.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.count <= threshold
    }
}
