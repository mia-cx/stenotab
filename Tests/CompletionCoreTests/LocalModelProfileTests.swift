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

    func testProviderConfigurationResolvesAPersistedCustomProfile() throws {
        let profile = LocalModelProfile(
            id: "hf:example/model:model.Q4_K_M.gguf",
            displayName: "example/model",
            repository: "example/model",
            modelFile: "model.Q4_K_M.gguf",
            apiStyle: .textCompletions,
            minimumUnifiedMemoryGB: 0,
            supportsImages: false,
            qualityNote: "Discovered in the Hugging Face cache."
        )
        let configuration = LocalCompletionConfiguration(
            profileID: profile.id,
            customProfile: profile,
            baseURL: "http://127.0.0.1:18473/v1",
            maximumWords: 8
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(
            LocalCompletionConfiguration.self,
            from: data
        )

        XCTAssertEqual(decoded.selectedProfile, profile)
    }

    func testProviderConfigurationDecodesLegacyPayloadWithoutCustomProfile()
        throws
    {
        let data = Data(
            """
            {
              "profileID": "gemma-4-e2b-base",
              "baseURL": "http://127.0.0.1:18473/v1",
              "maximumWords": 8
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(
            LocalCompletionConfiguration.self,
            from: data
        )

        XCTAssertNil(decoded.customProfile)
        XCTAssertEqual(
            decoded.selectedProfile,
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")
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

    func testHuggingFaceCacheDiscoversGGUFsAcrossRepositories() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSnapshot = root.appending(
            path: "models--example--first/snapshots/revision-a",
            directoryHint: .isDirectory
        )
        let secondSnapshot = root.appending(
            path: "models--example--second/snapshots/revision-b",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: firstSnapshot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondSnapshot.appending(
                path: "quantized",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )
        try Data("gguf".utf8).write(
            to: firstSnapshot.appending(path: "first.Q4_K_M.gguf")
        )
        try Data("ignore".utf8).write(
            to: firstSnapshot.appending(path: "README.md")
        )
        try Data("gguf".utf8).write(
            to: secondSnapshot.appending(
                path: "quantized/second.Q5_K_M.GGUF"
            )
        )

        let profiles = HuggingFaceModelCache.cachedProfiles(cacheRoot: root)

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].repository, "example/first")
        XCTAssertEqual(profiles[0].modelFile, "first.Q4_K_M.gguf")
        XCTAssertEqual(profiles[1].repository, "example/second")
        XCTAssertEqual(
            profiles[1].modelFile,
            "quantized/second.Q5_K_M.GGUF"
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
