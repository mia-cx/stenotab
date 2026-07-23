import CompletionCore
import XCTest

final class CompletionRefreshPolicyTests: XCTestCase {
    func testDoesNotRequestCompletionForAnEmptyInput() {
        XCTAssertFalse(CompletionRequestPolicy.shouldRequest(prefix: ""))
        XCTAssertFalse(CompletionRequestPolicy.shouldRequest(prefix: " \n\t"))
        XCTAssertTrue(CompletionRequestPolicy.shouldRequest(prefix: "thank"))
    }

    func testSchedulesWhenAccessibilityFindsUnobservedText() {
        var buffer = ShadowTextBuffer(prefix: "than")

        let contentChanged = buffer.reconcile(
            prefix: "thank",
            suffix: ""
        )

        XCTAssertTrue(contentChanged)
        XCTAssertTrue(
            CompletionRefreshPolicy.shouldScheduleAfterReconciliation(
                contentChanged: contentChanged,
                recoveringFromSnapshotFailure: false,
                hasVisibleSuggestion: false,
                isTrackingSuggestionConsumption: false
            )
        )
    }

    func testDoesNotDuplicateRequestForUnchangedSnapshot() {
        var buffer = ShadowTextBuffer(prefix: "thank")

        let contentChanged = buffer.reconcile(
            prefix: "thank",
            suffix: ""
        )

        XCTAssertFalse(contentChanged)
        XCTAssertFalse(
            CompletionRefreshPolicy.shouldScheduleAfterReconciliation(
                contentChanged: contentChanged,
                recoveringFromSnapshotFailure: false,
                hasVisibleSuggestion: false,
                isTrackingSuggestionConsumption: false
            )
        )
    }

    func testDoesNotInterruptExactMatchConsumption() {
        XCTAssertFalse(
            CompletionRefreshPolicy.shouldScheduleAfterReconciliation(
                contentChanged: true,
                recoveringFromSnapshotFailure: false,
                hasVisibleSuggestion: false,
                isTrackingSuggestionConsumption: true
            )
        )
    }

    func testRecoveryRetriggersSuggestionClearedByPersistentFailure() {
        XCTAssertTrue(
            CompletionRefreshPolicy.shouldScheduleAfterReconciliation(
                contentChanged: false,
                recoveringFromSnapshotFailure: true,
                hasVisibleSuggestion: false,
                isTrackingSuggestionConsumption: false
            )
        )
    }

    func testTransientSnapshotFailurePreservesSuggestion() {
        XCTAssertFalse(
            SnapshotFailurePolicy.shouldClearSuggestion(
                consecutiveFailures: 1,
                frontmostProcessMatchesLastSnapshot: true
            )
        )
        XCTAssertFalse(
            SnapshotFailurePolicy.shouldClearSuggestion(
                consecutiveFailures: 2,
                frontmostProcessMatchesLastSnapshot: true
            )
        )
    }

    func testPersistentFailureOrAppSwitchClearsSuggestion() {
        XCTAssertTrue(
            SnapshotFailurePolicy.shouldClearSuggestion(
                consecutiveFailures: 3,
                frontmostProcessMatchesLastSnapshot: true
            )
        )
        XCTAssertTrue(
            SnapshotFailurePolicy.shouldClearSuggestion(
                consecutiveFailures: 1,
                frontmostProcessMatchesLastSnapshot: false
            )
        )
    }
}
