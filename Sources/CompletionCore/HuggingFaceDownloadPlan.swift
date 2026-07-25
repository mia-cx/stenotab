import Foundation

public struct HuggingFaceDownloadPlan: Equatable, Sendable {
    public struct Installation: Equatable, Sendable {
        public let revision: String
        public let blobIdentifier: String
        public let blobURL: URL
        public let snapshotFileURL: URL
        public let mainReferenceURL: URL
        public let snapshotSymlinkDestination: String
    }

    public let sourceURL: URL
    public let revisionMetadataURL: URL
    public let repositoryRoot: URL
    public let incompleteURL: URL
    public let modelFile: String

    public init?(
        profile: LocalModelProfile,
        cacheRoot: URL = HuggingFaceModelCache.defaultRoot()
    ) {
        guard
            let modelFile = profile.modelFile,
            !modelFile.isEmpty,
            Self.isSafeModelPath(modelFile),
            !profile.repository.isEmpty,
            let encodedRepository = profile.repository.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ),
            let encodedFile = modelFile.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ),
            let sourceURL = URL(
                string:
                    "https://huggingface.co/\(encodedRepository)"
                    + "/resolve/main/\(encodedFile)?download=true"
            ),
            let revisionMetadataURL = URL(
                string:
                    "https://huggingface.co/api/models/"
                    + "\(encodedRepository)/revision/main"
            )
        else {
            return nil
        }

        let repositoryDirectory = "models--"
            + profile.repository.replacingOccurrences(of: "/", with: "--")
        let repositoryRoot = cacheRoot.appending(
            path: repositoryDirectory,
            directoryHint: .isDirectory
        )
        self.sourceURL = sourceURL
        self.revisionMetadataURL = revisionMetadataURL
        self.repositoryRoot = repositoryRoot
        self.incompleteURL = repositoryRoot
            .appending(path: "downloads", directoryHint: .isDirectory)
            .appending(path: "\(modelFile).incomplete")
        self.modelFile = modelFile
    }

    public func installation(
        revision: String,
        blobIdentifier: String
    ) -> Installation? {
        guard
            Self.isSafeCacheComponent(revision),
            Self.isSafeCacheComponent(blobIdentifier)
        else {
            return nil
        }
        let nestedDirectoryCount = max(
            modelFile.split(separator: "/").count - 1,
            0
        )
        let snapshotSymlinkDestination =
            Array(repeating: "..", count: 2 + nestedDirectoryCount)
                .joined(separator: "/")
                + "/blobs/\(blobIdentifier)"
        return Installation(
            revision: revision,
            blobIdentifier: blobIdentifier,
            blobURL: repositoryRoot
                .appending(path: "blobs", directoryHint: .isDirectory)
                .appending(path: blobIdentifier),
            snapshotFileURL: repositoryRoot
                .appending(
                    path: "snapshots/\(revision)",
                    directoryHint: .isDirectory
                )
                .appending(path: modelFile),
            mainReferenceURL: repositoryRoot.appending(path: "refs/main"),
            snapshotSymlinkDestination: snapshotSymlinkDestination
        )
    }

    public static func blobIdentifier(
        revision: String,
        modelFile: String
    ) -> String? {
        guard isSafeCacheComponent(revision) else { return nil }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in modelFile.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return revision + "-" + String(format: "%016llx", hash)
    }

    private static func isSafeCacheComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "-"
                || $0 == "_"
                || $0 == "."
        } && !value.contains("..")
    }

    private static func isSafeModelPath(_ value: String) -> Bool {
        guard
            !value.hasPrefix("/"),
            !value.contains("\\")
        else {
            return false
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
