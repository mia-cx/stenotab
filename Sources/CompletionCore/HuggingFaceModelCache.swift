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

        var profilesByArtifact: [String: LocalModelProfile] = [:]
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
                        modelFile: modelFile,
                        metadata: GGUFModelMetadata.read(from: modelURL)
                    )
                    profilesByArtifact[artifactIdentity(for: profile)] = profile
                }
            }
        }

        return profilesByArtifact.values.sorted {
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
        modelFile: String,
        metadata: GGUFModelMetadata? = nil
    ) -> LocalModelProfile {
        LocalModelProfile(
            id: "hf:\(repository):\(modelFile)",
            displayName: displayName(
                repository: repository,
                modelFile: modelFile,
                metadata: metadata
            ),
            repository: repository,
            modelFile: modelFile,
            apiStyle: .textCompletions,
            minimumUnifiedMemoryGB: 0,
            supportsImages: false,
            qualityNote: "Discovered in the shared Hugging Face cache."
        )
    }

    public static func artifactIdentity(
        for profile: LocalModelProfile
    ) -> String {
        let repository = profile.repository
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let modelFile = (profile.modelFile ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        return "\(repository)\u{0}\(modelFile)"
    }

    private static func displayName(
        repository: String,
        modelFile: String,
        metadata: GGUFModelMetadata?
    ) -> String {
        let name = metadata?.name
            .flatMap(nonempty)
            .map(normalizeModelName)
            ?? inferredModelName(repository: repository, modelFile: modelFile)
        let size = metadata?.sizeLabel.flatMap(nonempty)
        let quantization = inferredQuantization(from: modelFile)

        var components = [name]
        for component in [size, quantization].compactMap({ $0 }) {
            if !components.contains(where: {
                $0.localizedCaseInsensitiveContains(component)
            }) {
                components.append(component)
            }
        }
        return components.joined(separator: " · ")
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeModelName(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"\bIt\b"#,
                with: "IT",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\bGguf\b"#,
                with: "GGUF",
                options: .regularExpression
            )
    }

    private static func inferredModelName(
        repository: String,
        modelFile: String
    ) -> String {
        var value = URL(filePath: modelFile).deletingPathExtension()
            .lastPathComponent
        if let quantization = inferredQuantization(from: modelFile),
           value.hasSuffix(".\(quantization)") {
            value.removeLast(quantization.count + 1)
        }
        if value.isEmpty {
            value = repository.split(separator: "/").last.map(String.init)
                ?? repository
        }
        return normalizeModelName(
            value
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        )
    }

    private static func inferredQuantization(from modelFile: String) -> String? {
        let stem = URL(filePath: modelFile).deletingPathExtension()
            .lastPathComponent
        return stem.split(separator: ".").last
            .map(String.init)
            .flatMap {
                $0.range(
                    of: #"^(?:[IQF]\d|BF16)(?:_[A-Z0-9]+)*$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) == nil ? nil : $0.uppercased()
            }
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
