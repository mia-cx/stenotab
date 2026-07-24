import CompletionCore
import XCTest

final class ApplicationPolicyTests: XCTestCase {
    func testExplicitOverridesWinOverTheGlobalDefault() {
        var state = ApplicationPolicyState(globalCompletionsEnabled: true)
        state.setPolicyOverride(.disabled, for: "com.example.private")
        state.setPolicyOverride(.enabled, for: "com.example.always")

        XCTAssertFalse(
            state.completionsAreEnabled(for: "com.example.private")
        )
        XCTAssertTrue(
            state.completionsAreEnabled(for: "com.example.always")
        )
        XCTAssertTrue(
            state.completionsAreEnabled(for: "com.example.inherited")
        )

        state.globalCompletionsEnabled = false

        XCTAssertFalse(
            state.completionsAreEnabled(for: "com.example.inherited")
        )
        XCTAssertTrue(
            state.completionsAreEnabled(for: "com.example.always")
        )
    }

    func testInheritRemovesTheStoredOverride() {
        var state = ApplicationPolicyState()
        state.setPolicyOverride(.disabled, for: "com.example.editor")
        state.setPolicyOverride(.inherit, for: "com.example.editor")

        XCTAssertEqual(
            state.policyOverride(for: "com.example.editor"),
            .inherit
        )
        XCTAssertNil(state.overrides["com.example.editor"])
    }

    func testSecureObservationsAreNeverRecorded() {
        var state = ApplicationPolicyState()

        XCTAssertFalse(
            state.record(
                ApplicationObservation(
                    bundleIdentifier: "com.example.passwords",
                    displayName: "Passwords",
                    observedAt: Date(timeIntervalSince1970: 100),
                    isSecureField: true
                )
            )
        )
        XCTAssertTrue(state.seenApplications.isEmpty)
    }

    func testRepeatedObservationRefreshesMetadataWithoutMovingTimeBackward() {
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let bundleURL = URL(fileURLWithPath: "/Applications/Example.app")
        var state = ApplicationPolicyState()

        XCTAssertTrue(
            state.record(
                ApplicationObservation(
                    bundleIdentifier: "com.example.editor",
                    displayName: "Example",
                    observedAt: later,
                    isSecureField: false
                )
            )
        )
        XCTAssertTrue(
            state.record(
                ApplicationObservation(
                    bundleIdentifier: "com.example.editor",
                    displayName: "Example Editor",
                    bundleURL: bundleURL,
                    observedAt: earlier,
                    isSecureField: false
                )
            )
        )

        XCTAssertEqual(
            state.seenApplications["com.example.editor"],
            SeenApplication(
                bundleIdentifier: "com.example.editor",
                displayName: "Example Editor",
                bundleURL: bundleURL,
                lastSeenAt: later
            )
        )
    }

    func testPolicyStateRoundTripsThroughCodable() throws {
        let now = Date(timeIntervalSince1970: 42)
        var state = ApplicationPolicyState(globalCompletionsEnabled: false)
        state.setPolicyOverride(.enabled, for: "com.example.editor")
        _ = state.record(
            ApplicationObservation(
                bundleIdentifier: "com.example.editor",
                displayName: "Editor",
                observedAt: now,
                isSecureField: false
            )
        )

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(
            ApplicationPolicyState.self,
            from: data
        )

        XCTAssertEqual(restored, state)
    }
}
