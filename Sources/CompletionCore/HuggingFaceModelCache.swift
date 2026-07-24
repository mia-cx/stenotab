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

    public static func cachedProfiles(
        cacheRoot: URL = defaultRoot(),
        fileManager: FileManager = .default
    ) -> [LocalModelProfile] {
        guard
            let repositories = try? fileManager.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var profilesByID: [String: LocalModelProfile] = [:]
        for repositoryRoot in repositories {
            guard
                let repository = repositoryID(
                    fromCacheDirectory: repositoryRoot.lastPathComponent
                )
            else {
                continue
            }
            let snapshotsRoot = repositoryRoot.appending(
                path: "snapshots",
                directoryHint: .isDirectory
            )
            guard
                let snapshots = try? fileManager.contentsOfDirectory(
                    at: snapshotsRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }

            for snapshot in snapshots {
                guard
                    let enumerator = fileManager.enumerator(
                        at: snapshot,
                        includingPropertiesForKeys: [
                            .isRegularFileKey,
                            .isSymbolicLinkKey,
                        ],
                        options: [.skipsHiddenFiles]
                    )
                else {
                    continue
                }
                for case let modelURL as URL in enumerator
                where modelURL.pathExtension.lowercased() == "gguf" {
                    let relativeComponents = modelURL.pathComponents.dropFirst(
                        snapshot.pathComponents.count
                    )
                    let modelFile = relativeComponents.joined(separator: "/")
                    guard
                        !modelFile.isEmpty,
                        fileManager.fileExists(atPath: modelURL.path)
                    else {
                        continue
                    }
                    let profile = cachedProfile(
                        repository: repository,
                        modelFile: modelFile
                    )
                    profilesByID[profile.id] = profile
                }
            }
        }

        return profilesByID.values.sorted {
            if $0.repository != $1.repository {
                return $0.repository.localizedStandardCompare($1.repository)
                    == .orderedAscending
            }
            return ($0.modelFile ?? "").localizedStandardCompare(
                $1.modelFile ?? ""
            ) == .orderedAscending
        }
    }

    public static func cachedProfile(
        repository: String,
        modelFile: String
    ) -> LocalModelProfile {
        LocalModelProfile(
            id: "hf:\(repository):\(modelFile)",
            displayName: "\(repository) · \(modelFile)",
            repository: repository,
            modelFile: modelFile,
            apiStyle: .textCompletions,
            minimumUnifiedMemoryGB: 0,
            supportsImages: false,
            qualityNote: "Discovered in the shared Hugging Face cache."
        )
    }

    private static func repositoryID(
        fromCacheDirectory directory: String
    ) -> String? {
        let prefix = "models--"
        guard directory.hasPrefix(prefix) else { return nil }
        let encoded = String(directory.dropFirst(prefix.count))
        let components = encoded.components(separatedBy: "--")
        guard components.count >= 2 else { return nil }
        return components[0] + "/" + components.dropFirst().joined(
            separator: "--"
        )
    }
}
