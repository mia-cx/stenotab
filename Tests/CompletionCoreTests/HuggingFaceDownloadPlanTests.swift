import CompletionCore
import Foundation
import XCTest

final class HuggingFaceDownloadPlanTests: XCTestCase {
    func testPlansTheStandardHuggingFaceRepositoryLayout() throws {
        let root = URL(filePath: "/tmp/hf", directoryHint: .isDirectory)
        let profile = try XCTUnwrap(
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")
        )
        let plan = try XCTUnwrap(
            HuggingFaceDownloadPlan(profile: profile, cacheRoot: root)
        )
        let installation = try XCTUnwrap(
            plan.installation(
                revision: "abc123",
                blobIdentifier: "deadbeef"
            )
        )

        XCTAssertEqual(
            plan.sourceURL.absoluteString,
            "https://huggingface.co/mradermacher/gemma-4-E2B-GGUF/"
                + "resolve/main/gemma-4-E2B.Q4_K_M.gguf?download=true"
        )
        XCTAssertEqual(
            installation.blobURL.path,
            "/tmp/hf/models--mradermacher--gemma-4-E2B-GGUF/"
                + "blobs/deadbeef"
        )
        XCTAssertEqual(
            installation.snapshotFileURL.path,
            "/tmp/hf/models--mradermacher--gemma-4-E2B-GGUF/"
                + "snapshots/abc123/gemma-4-E2B.Q4_K_M.gguf"
        )
        XCTAssertEqual(
            installation.mainReferenceURL.path,
            "/tmp/hf/models--mradermacher--gemma-4-E2B-GGUF/refs/main"
        )
        XCTAssertEqual(
            installation.snapshotSymlinkDestination,
            "../../blobs/deadbeef"
        )
    }

    func testRejectsTraversalInServerSuppliedCacheIdentifiers() throws {
        let profile = try XCTUnwrap(
            LocalModelProfiles.profile(id: "gemma-4-e2b-base")
        )
        let plan = try XCTUnwrap(HuggingFaceDownloadPlan(profile: profile))

        XCTAssertNil(
            plan.installation(
                revision: "../../escape",
                blobIdentifier: "deadbeef"
            )
        )
        XCTAssertNil(
            plan.installation(
                revision: "abc123",
                blobIdentifier: "../blob"
            )
        )
    }
}
