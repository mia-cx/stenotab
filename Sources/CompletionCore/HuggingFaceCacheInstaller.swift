import Foundation

public enum HuggingFaceCacheInstaller {
    public static func install(
        incompleteURL: URL,
        installation: HuggingFaceDownloadPlan.Installation,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: installation.blobURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: installation.snapshotFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: installation.mainReferenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if itemExists(at: installation.blobURL, fileManager: fileManager) {
            try fileManager.removeItem(at: installation.blobURL)
        }
        try fileManager.moveItem(
            at: incompleteURL,
            to: installation.blobURL
        )

        if itemExists(
            at: installation.snapshotFileURL,
            fileManager: fileManager
        ) {
            try fileManager.removeItem(at: installation.snapshotFileURL)
        }
        try fileManager.createSymbolicLink(
            atPath: installation.snapshotFileURL.path,
            withDestinationPath:
                installation.snapshotSymlinkDestination
        )
        try Data("\(installation.revision)\n".utf8).write(
            to: installation.mainReferenceURL,
            options: .atomic
        )
        return installation.snapshotFileURL
    }

    private static func itemExists(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(
                atPath: url.path
            )) != nil
    }
}
