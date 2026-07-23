import CompletionCore
import XCTest

final class LocalModelProfileTests: XCTestCase {
    func testRecommendedProfilesUseSharedHuggingFaceRepositories() {
        XCTAssertEqual(
            LocalModelProfiles.profile(id: "gemma-3-1b-base")?.repository,
            "mlx-community/gemma-3-1b-pt-4bit"
        )
        XCTAssertEqual(
            LocalModelProfiles.profile(id: "gemma-4-e2b-it")?.repository,
            "mlx-community/gemma-4-e2b-it-4bit"
        )
        XCTAssertEqual(
            LocalModelProfiles.profile(id: "gemma-4-e2b-it")?.apiStyle,
            .chatCompletions
        )
        XCTAssertTrue(
            LocalModelProfiles.profile(id: "gemma-4-e2b-it")?
                .supportsImages == true
        )
    }

    func testProviderConfigurationRoundTripsSelectedProfile() throws {
        let configuration = LocalCompletionConfiguration(
            profileID: "gemma-4-e2b-it",
            baseURL: "http://127.0.0.1:8080/v1",
            maximumWords: 8
        )

        let data = try JSONEncoder().encode(configuration)

        XCTAssertEqual(
            try JSONDecoder().decode(
                LocalCompletionConfiguration.self,
                from: data
            ),
            configuration
        )
    }
}
