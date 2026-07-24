import Foundation

public enum HuggingFaceModelCache {
    public static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            return URL(filePath: hubCache, directoryHint: .isDirectory)
        }
        if let huggingFaceHome = environment["HF_HOME"],
           !huggingFaceHome.isEmpty {
            return URL(filePath: huggingFaceHome, directoryHint: .isDirectory)
                .appending(path: "hub", directoryHint: .isDirectory)
        }
        return homeDirectory
            .appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory)
    }

    public static func modelURL(
        for profile: LocalModelProfile,
        cacheRoot: URL = defaultRoot(),
        fileManager: FileManager = .default
    ) -> URL? {
        guard let modelFile = profile.modelFile else { return nil }
        let repositoryDirectory = "models--" +
            profile.repository.replacingOccurrences(of: "/", with: "--")
        let modelRoot = cacheRoot.appending(
            path: repositoryDirectory,
            directoryHint: .isDirectory
        )

        if let revision = try? String(
            contentsOf: modelRoot.appending(path: "refs/main"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty {
            let candidate = modelRoot
                .appending(
                    path: "snapshots/\(revision)",
                    directoryHint: .isDirectory
                )
                .appending(path: modelFile)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let snapshots = modelRoot.appending(
            path: "snapshots",
            directoryHint: .isDirectory
        )
        guard let revisions = try? fileManager.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return revisions
            .compactMap { revision -> (URL, Date)? in
                let candidate = revision.appending(path: modelFile)
                guard fileManager.fileExists(atPath: candidate.path) else {
                    return nil
                }
                let date = try? revision.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                return (candidate, date ?? .distantPast)
            }
            .max { $0.1 < $1.1 }?
            .0
    }
}
