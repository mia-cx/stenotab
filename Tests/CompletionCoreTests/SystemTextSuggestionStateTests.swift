import CompletionCore
import XCTest

final class SystemTextSuggestionStateTests: XCTestCase {
    func testConfiguredStateRequiresBothSuggestionsToBeDisabled() {
        XCTAssertTrue(
            SystemTextSuggestionState(
                inlinePredictiveTextEnabled: false,
                suggestedRepliesEnabled: false
            ).isConfiguredForStenoTab
        )
        XCTAssertFalse(
            SystemTextSuggestionState(
                inlinePredictiveTextEnabled: true,
                suggestedRepliesEnabled: false
            ).isConfiguredForStenoTab
        )
        XCTAssertFalse(
            SystemTextSuggestionState(
                inlinePredictiveTextEnabled: false,
                suggestedRepliesEnabled: true
            ).isConfiguredForStenoTab
        )
    }

    func testReportsOnlySettingsThatStillNeedToBeDisabled() {
        XCTAssertEqual(
            SystemTextSuggestionState(
                inlinePredictiveTextEnabled: true,
                suggestedRepliesEnabled: false
            ).enabledSettingNames,
            ["inline predictive text"]
        )
        XCTAssertEqual(
            SystemTextSuggestionState(
                inlinePredictiveTextEnabled: true,
                suggestedRepliesEnabled: true
            ).enabledSettingNames,
            ["inline predictive text", "suggested replies"]
        )
    }
}
