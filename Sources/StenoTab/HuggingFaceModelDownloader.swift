import CompletionCore
import Foundation

actor HuggingFaceModelDownloader {
    struct DownloadProgress: Equatable, Sendable {
        let receivedBytes: Int64
        let totalBytes: Int64?

        var fractionCompleted: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
        }
    }

    enum DownloadError: LocalizedError {
        case invalidProfile
        case invalidRepository
        case invalidRevision
        case noMLXCheckpoint
        case unexpectedResponse
        case httpStatus(Int)
        case incomplete(expected: Int64, received: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidProfile:
                "The selected profile has no downloadable model file."
            case .invalidRepository:
                "Enter a Hugging Face model ID like owner/model."
            case .invalidRevision:
                "Hugging Face returned an invalid repository revision."
            case .noMLXCheckpoint:
                "That repository does not contain a complete MLX checkpoint."
            case .unexpectedResponse:
                "Hugging Face returned an unexpected response."
            case let .httpStatus(status):
                "Hugging Face returned HTTP \(status)."
            case let .incomplete(expected, received):
                "The download stopped at \(received) of \(expected) bytes."
            }
        }
    }

    private struct ModelInfo: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }

        let sha: String
        let siblings: [Sibling]?
        let libraryName: String?
        let tags: [String]?

        enum CodingKeys: String, CodingKey {
            case sha
            case siblings
            case libraryName = "library_name"
            case tags
        }
    }

    private let fileManager: FileManager
    private let session: URLSession

    init(
        fileManager: FileManager = .default,
        session: URLSession? = nil
    ) {
        self.fileManager = fileManager
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60 * 8
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func download(
        profile: LocalModelProfile,
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        if profile.isMLXCheckpoint {
            return try await downloadMLXCheckpoint(
                profile: profile,
                progress: progress
            )
        }
        guard let plan = HuggingFaceDownloadPlan(profile: profile) else {
            throw DownloadError.invalidProfile
        }
        let revision = try await fetchRevision(using: plan)
        return try await downloadFile(
            using: plan,
            revision: revision,
            progress: progress
        )
    }

    private func downloadFile(
        using plan: HuggingFaceDownloadPlan,
        revision: String,
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        guard
            let blobIdentifier = HuggingFaceDownloadPlan.blobIdentifier(
                revision: revision,
                modelFile: plan.modelFile
            ),
            let installation = plan.installation(
                revision: revision,
                blobIdentifier: blobIdentifier
            )
        else {
            throw DownloadError.invalidRevision
        }
        if fileManager.fileExists(atPath: installation.snapshotFileURL.path) {
            let existingBytes = Self.fileSize(
                at: installation.snapshotFileURL,
                fileManager: fileManager
            )
            await progress(
                DownloadProgress(
                    receivedBytes: existingBytes,
                    totalBytes: existingBytes
                )
            )
            return installation.snapshotFileURL
        }

        try fileManager.createDirectory(
            at: plan.incompleteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingBytes = Self.fileSize(
            at: plan.incompleteURL,
            fileManager: fileManager
        )
        var request = URLRequest(url: plan.sourceURL)
        request.timeoutInterval = 60
        request.setValue("StenoTab/1", forHTTPHeaderField: "User-Agent")
        if existingBytes > 0 {
            request.setValue(
                "bytes=\(existingBytes)-",
                forHTTPHeaderField: "Range"
            )
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.unexpectedResponse
        }
        guard
            httpResponse.statusCode == 200
                || httpResponse.statusCode == 206
        else {
            throw DownloadError.httpStatus(httpResponse.statusCode)
        }

        let resumes = httpResponse.statusCode == 206 && existingBytes > 0
        let startingBytes = resumes ? existingBytes : 0
        let expectedRemaining = response.expectedContentLength
        let totalBytes = expectedRemaining > 0
            ? startingBytes + expectedRemaining
            : nil

        let handle = try prepareIncompleteFile(
            at: plan.incompleteURL,
            append: resumes
        )
        defer { try? handle.close() }

        var receivedBytes = startingBytes
        var buffer = Data()
        buffer.reserveCapacity(4 * 1_024 * 1_024)
        try Task.checkCancellation()
        await progress(
            DownloadProgress(
                receivedBytes: receivedBytes,
                totalBytes: totalBytes
            )
        )

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 4 * 1_024 * 1_024 {
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await progress(
                    DownloadProgress(
                        receivedBytes: receivedBytes,
                        totalBytes: totalBytes
                    )
                )
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            receivedBytes += Int64(buffer.count)
        }
        try handle.synchronize()

        if let totalBytes, receivedBytes != totalBytes {
            throw DownloadError.incomplete(
                expected: totalBytes,
                received: receivedBytes
            )
        }
        await progress(
            DownloadProgress(
                receivedBytes: receivedBytes,
                totalBytes: totalBytes ?? receivedBytes
            )
        )
        return try HuggingFaceCacheInstaller.install(
            incompleteURL: plan.incompleteURL,
            installation: installation,
            fileManager: fileManager
        )
    }

    private func downloadMLXCheckpoint(
        profile: LocalModelProfile,
        progress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        let info = try await fetchModelInfo(
            repository: profile.repository
        )
        let siblings = info.siblings ?? []
        let files = siblings
            .filter { Self.isMLXCheckpointFile($0.rfilename) }
            .sorted {
                if $0.rfilename == "config.json" { return false }
                if $1.rfilename == "config.json" { return true }
                return $0.rfilename.localizedStandardCompare($1.rfilename)
                    == .orderedAscending
            }
        guard
            files.contains(where: { $0.rfilename == "config.json" }),
            files.contains(where: {
                $0.rfilename.lowercased().hasSuffix(".safetensors")
            })
        else {
            throw DownloadError.noMLXCheckpoint
        }

        let knownTotal = files.allSatisfy { $0.size != nil }
            ? files.compactMap(\.size).reduce(0, +)
            : nil
        var completedBytes: Int64 = 0
        for sibling in files {
            try Task.checkCancellation()
            let fileProfile = LocalModelProfile(
                id: profile.id,
                displayName: profile.displayName,
                repository: profile.repository,
                modelFile: sibling.rfilename,
                apiStyle: profile.apiStyle,
                minimumUnifiedMemoryGB: profile.minimumUnifiedMemoryGB,
                supportsImages: profile.supportsImages,
                qualityNote: profile.qualityNote
            )
            guard let plan = HuggingFaceDownloadPlan(profile: fileProfile) else {
                throw DownloadError.invalidProfile
            }
            let completedBeforeFile = completedBytes
            let installedFile = try await downloadFile(
                using: plan,
                revision: info.sha
            ) { fileProgress in
                await progress(
                    DownloadProgress(
                        receivedBytes:
                            completedBeforeFile + fileProgress.receivedBytes,
                        totalBytes: knownTotal
                    )
                )
            }
            completedBytes += sibling.size
                ?? Self.fileSize(
                    at: installedFile,
                    fileManager: fileManager
                )
        }

        guard let checkpoint = HuggingFaceModelCache.modelURL(for: profile) else {
            throw DownloadError.noMLXCheckpoint
        }
        await progress(
            DownloadProgress(
                receivedBytes: completedBytes,
                totalBytes: knownTotal ?? completedBytes
            )
        )
        return checkpoint
    }

    func resolveProfile(repository input: String) async throws
        -> LocalModelProfile
    {
        guard
            let repository =
                HuggingFaceRepositorySelection.normalizedRepositoryID(
                    from: input
                ),
            let encodedRepository = repository.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ),
            let url = URL(
                string:
                    "https://huggingface.co/api/models/"
                    + "\(encodedRepository)/revision/main"
            )
        else {
            throw DownloadError.invalidRepository
        }
        let info = try await fetchModelInfo(at: url)
        let siblings = info.siblings?.map(\.rfilename) ?? []
        if Self.isMLXCheckpointRepository(
            siblings,
            repository: repository,
            libraryName: info.libraryName,
            tags: info.tags ?? []
        ) {
            return HuggingFaceModelCache.cachedMLXProfile(
                repository: repository
            )
        }
        throw DownloadError.noMLXCheckpoint
    }

    private func fetchRevision(
        using plan: HuggingFaceDownloadPlan
    ) async throws -> String {
        try await fetchModelInfo(at: plan.revisionMetadataURL).sha
    }

    private func fetchModelInfo(repository: String) async throws -> ModelInfo {
        guard
            let encodedRepository = repository.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ),
            let url = URL(
                string:
                    "https://huggingface.co/api/models/"
                    + "\(encodedRepository)/revision/main"
            )
        else {
            throw DownloadError.invalidRepository
        }
        return try await fetchModelInfo(at: url)
    }

    private func fetchModelInfo(at url: URL) async throws -> ModelInfo {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("StenoTab/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.unexpectedResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DownloadError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(ModelInfo.self, from: data)
    }

    private func prepareIncompleteFile(
        at url: URL,
        append: Bool
    ) throws -> FileHandle {
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        if append {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }
        return handle
    }

    private static func fileSize(
        at url: URL,
        fileManager: FileManager
    ) -> Int64 {
        guard
            let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
            ),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    private static func isMLXCheckpointRepository(
        _ files: [String],
        repository: String,
        libraryName: String?,
        tags: [String]
    ) -> Bool {
        let identifiesMLX =
            repository.lowercased().hasPrefix("mlx-community/")
                || libraryName?.lowercased() == "mlx"
                || tags.contains { $0.lowercased() == "mlx" }
        return identifiesMLX
            && files.contains("config.json")
            && files.contains {
                $0.lowercased().hasSuffix(".safetensors")
            }
    }

    private static func isMLXCheckpointFile(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix(".json")
            || lowercased.hasSuffix(".safetensors")
            || lowercased.hasSuffix(".model")
            || lowercased.hasSuffix(".txt")
            || lowercased.hasSuffix(".tiktoken")
    }
}
