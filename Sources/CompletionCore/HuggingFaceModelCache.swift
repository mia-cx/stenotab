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
            let snapshot = modelRoot.appending(
                path: "snapshots/\(revision)",
                directoryHint: .isDirectory
            )
            if let candidate = modelArtifactURL(
                in: snapshot,
                profile: profile,
                fileManager: fileManager
            ) {
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
                guard let candidate = modelArtifactURL(
                    in: revision,
                    profile: profile,
                    fileManager: fileManager
                ) else {
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
                if isCompleteMLXSnapshot(
                    snapshot,
                    repository: repository,
                    fileManager: fileManager
                ) {
                    let profile = cachedMLXProfile(repository: repository)
                    profilesByArtifact[artifactIdentity(for: profile)] = profile
                }

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
            return ($0.modelFile ?? "mlx").localizedStandardCompare(
                $1.modelFile ?? "mlx"
            ) == .orderedAscending
        }
    }

    public static func cachedMLXProfile(
        repository: String
    ) -> LocalModelProfile {
        LocalModelProfile(
            id: "hf:\(repository):mlx",
            displayName: displayName(repository: repository),
            repository: repository,
            apiStyle: .textCompletions,
            minimumUnifiedMemoryGB: 0,
            supportsImages: false,
            qualityNote: "Available in the shared Hugging Face cache."
        )
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

    private static func modelArtifactURL(
        in snapshot: URL,
        profile: LocalModelProfile,
        fileManager: FileManager
    ) -> URL? {
        if let modelFile = profile.modelFile {
            let candidate = snapshot.appending(path: modelFile)
            return fileManager.fileExists(atPath: candidate.path)
                ? candidate
                : nil
        }
        return isCompleteMLXSnapshot(
            snapshot,
            repository: profile.repository,
            fileManager: fileManager
        )
            ? snapshot
            : nil
    }

    private static func isCompleteMLXSnapshot(
        _ snapshot: URL,
        repository: String,
        fileManager: FileManager
    ) -> Bool {
        let configURL = snapshot.appending(path: "config.json")
        guard
            let configData = try? Data(contentsOf: configURL),
            isMLXConfiguration(configData, repository: repository)
        else {
            return false
        }
        guard let files = fileManager.enumerator(
            at: snapshot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return files.contains { item in
            guard let url = item as? URL else { return false }
            return url.pathExtension.lowercased() == "safetensors"
                && fileManager.fileExists(atPath: url.path)
        }
    }

    private static func isMLXConfiguration(
        _ data: Data,
        repository: String
    ) -> Bool {
        if repository.lowercased().hasPrefix("mlx-community/") {
            return true
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return false
        }
        let quantization = object["quantization"] as? [String: Any]
            ?? object["quantization_config"] as? [String: Any]
        return (quantization?["mode"] as? String)?.lowercased() == "affine"
            && quantization?["bits"] != nil
    }

    private static func displayName(repository: String) -> String {
        let slug = repository.split(separator: "/").last.map(String.init)
            ?? repository
        var words = slug
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(String.init)
        words = words.map { word in
            switch word.lowercased() {
            case "mlx":
                "MLX"
            case "it":
                "IT"
            case "e2b":
                "E2B"
            case "4bit":
                "4-bit"
            default:
                word.capitalized
            }
        }
        return words.joined(separator: " ")
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
