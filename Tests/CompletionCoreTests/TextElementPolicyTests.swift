import CompletionCore
import XCTest

final class TextElementPolicyTests: XCTestCase {
    func testElectronEditableRolesAreSupported() {
        XCTAssertTrue(TextElementPolicy.isSupported(role: "AXEditableText"))
        XCTAssertTrue(TextElementPolicy.isSupported(role: "AXDocument"))
        XCTAssertTrue(TextElementPolicy.isSupported(role: "AXTextArea"))
        XCTAssertFalse(TextElementPolicy.isSupported(role: "AXButton"))
    }

    func testWebBackedContainersSearchForEditableDescendants() {
        XCTAssertTrue(
            TextElementPolicy.shouldSearchDescendants(
                rootIsUsable: false,
                rootIsWebContainer: false,
                appIsWebBacked: true
            )
        )
        XCTAssertTrue(
            TextElementPolicy.shouldSearchDescendants(
                rootIsUsable: true,
                rootIsWebContainer: true,
                appIsWebBacked: true
            )
        )
        XCTAssertFalse(
            TextElementPolicy.shouldSearchDescendants(
                rootIsUsable: true,
                rootIsWebContainer: false,
                appIsWebBacked: true
            )
        )
    }

    func testOnlyTheFocusedRootOrExplicitlyFocusedDescendantIsEligible() {
        XCTAssertTrue(
            TextElementPolicy.isEligibleFocusedCandidate(
                isFocusedRoot: true,
                focusedAttribute: nil
            )
        )
        XCTAssertTrue(
            TextElementPolicy.isEligibleFocusedCandidate(
                isFocusedRoot: false,
                focusedAttribute: true
            )
        )
        XCTAssertFalse(
            TextElementPolicy.isEligibleFocusedCandidate(
                isFocusedRoot: false,
                focusedAttribute: false
            )
        )
        XCTAssertFalse(
            TextElementPolicy.isEligibleFocusedCandidate(
                isFocusedRoot: false,
                focusedAttribute: nil
            )
        )
    }
}
