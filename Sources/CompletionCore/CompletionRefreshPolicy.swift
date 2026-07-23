public enum CompletionRefreshPolicy {
    public static func shouldScheduleAfterReconciliation(
        contentChanged: Bool,
        recoveringFromSnapshotFailure: Bool,
        hasVisibleSuggestion: Bool,
        isTrackingSuggestionConsumption: Bool
    ) -> Bool {
        (contentChanged || recoveringFromSnapshotFailure)
            && !hasVisibleSuggestion
            && !isTrackingSuggestionConsumption
    }
}

public enum SnapshotFailurePolicy {
    public static func shouldClearSuggestion(
        consecutiveFailures: Int,
        frontmostProcessMatchesLastSnapshot: Bool
    ) -> Bool {
        !frontmostProcessMatchesLastSnapshot || consecutiveFailures >= 3
    }
}
