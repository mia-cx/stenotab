import CompletionCore
import XCTest

final class ProviderSettingsTests: XCTestCase {
    func testSettingsRoundTripWithoutAnyCredentialField() throws {
        let remote = RemoteProviderConfiguration(
            id: "work-api",
            displayName: "Work API",
            baseURL: "https://models.example.com/v1",
            model: "autocomplete",
            apiStyle: .textCompletions,
            maximumWords: 12
        )
        let settings = ProviderSettings(
            selection: .remote(providerID: remote.id),
            remoteProviders: [remote]
        )

        let data = try JSONEncoder().encode(settings)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertEqual(
            try JSONDecoder().decode(ProviderSettings.self, from: data),
            settings
        )
    }

    func testRemoteEndpointRequiresHTTPOrHTTPSWithAHost() {
        XCTAssertNotNil(
            RemoteProviderConfiguration(
                displayName: "Local",
                baseURL: "http://127.0.0.1:8080/v1",
                model: "model",
                apiStyle: .chatCompletions
            ).validatedBaseURL
        )
        XCTAssertNil(
            RemoteProviderConfiguration(
                displayName: "File",
                baseURL: "file:///tmp/model",
                model: "model",
                apiStyle: .chatCompletions
            ).validatedBaseURL
        )
        XCTAssertNil(
            RemoteProviderConfiguration(
                displayName: "Broken",
                baseURL: "not a URL",
                model: "model",
                apiStyle: .chatCompletions
            ).validatedBaseURL
        )
    }

    func testMaximumWordsIsBoundedForInlineCompletions() {
        XCTAssertEqual(
            RemoteProviderConfiguration(
                displayName: "Tiny",
                baseURL: "https://example.com/v1",
                model: "model",
                apiStyle: .chatCompletions,
                maximumWords: 0
            ).maximumWords,
            1
        )
        XCTAssertEqual(
            RemoteProviderConfiguration(
                displayName: "Huge",
                baseURL: "https://example.com/v1",
                model: "model",
                apiStyle: .chatCompletions,
                maximumWords: 100
            ).maximumWords,
            32
        )
    }

    func testRemoteSelectionResolvesByStableIdentifier() {
        let remote = RemoteProviderConfiguration(
            id: "personal",
            displayName: "Personal",
            baseURL: "https://example.com/v1",
            model: "model",
            apiStyle: .chatCompletions
        )
        let settings = ProviderSettings(
            selection: .remote(providerID: "personal"),
            remoteProviders: [remote]
        )

        XCTAssertEqual(settings.remoteProvider(id: "personal"), remote)
        XCTAssertNil(settings.remoteProvider(id: "missing"))
    }
}
