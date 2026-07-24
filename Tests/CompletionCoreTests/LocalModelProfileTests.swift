import CompletionCore
import XCTest

final class LocalModelProfileTests: XCTestCase {
    func testRecommendedProfilesUseSharedHuggingFaceRepositories() {
        XCTAssertEqual(
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")?.repository,
            "mradermacher/gemma-4-E2B-GGUF"
        )
        XCTAssertEqual(
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")?.modelFile,
            "gemma-4-E2B.Q4_K_M.gguf"
        )
        XCTAssertEqual(
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")?.apiStyle,
            .textCompletions
        )
        XCTAssertTrue(
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")?
                .supportsImages == false
        )
    }

    func testProviderConfigurationRoundTripsSelectedProfile() throws {
        let configuration = LocalCompletionConfiguration(
            profileID: "gemma-4-e2b-base",
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

    func testHuggingFaceCacheResolvesConfiguredGGUFFromMainSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelRoot = root
            .appending(
                path: "models--mradermacher--gemma-4-E2B-GGUF",
                directoryHint: .isDirectory
            )
        let snapshot = modelRoot
            .appending(path: "snapshots/revision-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: snapshot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelRoot.appending(path: "refs", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data("revision-1\n".utf8).write(
            to: modelRoot.appending(path: "refs/main")
        )
        let expected = snapshot.appending(path: "gemma-4-E2B.Q4_K_M.gguf")
        try Data("gguf".utf8).write(to: expected)

        let profile = try XCTUnwrap(
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")
        )
        XCTAssertEqual(
            HuggingFaceModelCache.modelURL(for: profile, cacheRoot: root),
            expected
        )
    }

    func testExistingServerIsReusableOnlyWhenItAdvertisesSelectedModel() throws {
        let profile = try XCTUnwrap(
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")
        )

        XCTAssertFalse(
            LocalServerCompatibility.canServe(
                profile,
                advertisedModelIDs: ["some-other-model"]
            )
        )
        XCTAssertTrue(
            LocalServerCompatibility.canServe(
                profile,
                advertisedModelIDs: [
                    "some-other-model",
                    "stenotab/gemma-4-e2b-base",
                ]
            )
        )
        XCTAssertEqual(
            LocalServerCompatibility.matchingModelID(
                for: profile,
                advertisedModelIDs: [
                    "some-other-model",
                    "gemma-4-E2B.Q4_K_M.gguf",
                ]
            ),
            "gemma-4-E2B.Q4_K_M.gguf"
        )
    }
}
