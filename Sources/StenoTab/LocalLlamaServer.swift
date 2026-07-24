import CompletionCore
import Foundation

@MainActor
final class LocalLlamaServer {
    enum Ownership: Sendable {
        case external
        case stenotab
    }

    struct Connection: Sendable {
        let baseURL: URL
        let modelID: String
        let ownership: Ownership
    }

    enum StartupError: LocalizedError {
        case invalidBaseURL(String)
        case missingModel(String)
        case missingServerBinary
        case noAvailablePort
        case serverExited(Int32)
        case startupTimedOut

        var errorDescription: String? {
            switch self {
            case let .invalidBaseURL(value):
                "Invalid local model URL: \(value)"
            case let .missingModel(file):
                "The selected model is not in the Hugging Face cache: \(file)"
            case .missingServerBinary:
                "llama-server was not found in StenoTab or on this Mac."
            case .noAvailablePort:
                "No free localhost port was available for llama-server."
            case let .serverExited(status):
                "llama-server exited during startup with status \(status)."
            case .startupTimedOut:
                "llama-server did not become ready in time."
            }
        }
    }

    private enum ServerState {
        case unavailable
        case starting
        case incompatible
        case compatible(modelID: String)
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    private let profile: LocalModelProfile
    private let configuration: LocalCompletionConfiguration
    private let environment: [String: String]
    private let session: URLSession
    private var process: Process?
    private var logHandle: FileHandle?

    init(
        profile: LocalModelProfile,
        configuration: LocalCompletionConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.profile = profile
        self.configuration = configuration
        self.environment = environment

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 0.4
        sessionConfiguration.timeoutIntervalForResource = 0.6
        session = URLSession(configuration: sessionConfiguration)
    }

    func connectOrStart() async throws -> Connection {
        guard let configuredURL = URL(string: configuration.baseURL) else {
            throw StartupError.invalidBaseURL(configuration.baseURL)
        }
        let preferredURL = normalizedAPIBaseURL(configuredURL)
        var preferredState = await state(of: preferredURL)
        if case .starting = preferredState {
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(100))
                preferredState = await state(of: preferredURL)
                if case .starting = preferredState {
                    continue
                }
                break
            }
        }
        switch preferredState {
        case let .compatible(modelID):
            return Connection(
                baseURL: preferredURL,
                modelID: modelID,
                ownership: .external
            )
        case .unavailable:
            return try await startOwnedServer(at: preferredURL)
        case .starting, .incompatible:
            guard let fallback = await firstAvailableURL(after: preferredURL) else {
                throw StartupError.noAvailablePort
            }
            return try await startOwnedServer(at: fallback)
        }
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        try? logHandle?.close()
        logHandle = nil
    }

    private func startOwnedServer(at baseURL: URL) async throws -> Connection {
        guard let modelURL = HuggingFaceModelCache.modelURL(for: profile) else {
            throw StartupError.missingModel(profile.modelFile ?? profile.repository)
        }
        guard let executableURL = serverExecutableURL() else {
            throw StartupError.missingServerBinary
        }
        guard let port = baseURL.port else {
            throw StartupError.invalidBaseURL(baseURL.absoluteString)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--model", modelURL.path,
            "--alias", profile.serverModelID,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", "4096",
            "--parallel", "1",
            "--flash-attn", "on",
            "--cache-prompt",
            "--cors-origins", "localhost",
            "--no-webui",
            "--no-mmproj",
            "--n-predict", "64",
            "--log-verbosity", "2",
        ]

        let logHandle = try makeLogHandle()
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        self.process = process
        self.logHandle = logHandle

        for _ in 0..<600 {
            if !process.isRunning {
                throw StartupError.serverExited(process.terminationStatus)
            }
            if case .compatible = await state(of: baseURL) {
                return Connection(
                    baseURL: baseURL,
                    modelID: profile.serverModelID,
                    ownership: .stenotab
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw StartupError.startupTimedOut
    }

    private func state(of baseURL: URL) async -> ServerState {
        let modelsURL = baseURL.appending(path: "models")
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 0.4
        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            if statusCode == 503 {
                return .starting
            }
            guard statusCode == 200 else {
                return .incompatible
            }
            let models = try JSONDecoder().decode(ModelList.self, from: data)
            guard let modelID = LocalServerCompatibility.matchingModelID(
                for: profile,
                advertisedModelIDs: models.data.map(\.id)
            ) else {
                return .incompatible
            }
            return .compatible(modelID: modelID)
        } catch {
            return .unavailable
        }
    }

    private func firstAvailableURL(after baseURL: URL) async -> URL? {
        guard let currentPort = baseURL.port else { return nil }
        for port in (currentPort + 1)...(currentPort + 20) {
            guard let candidate = replacingPort(of: baseURL, with: port) else {
                continue
            }
            if case .unavailable = await state(of: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func normalizedAPIBaseURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = path == "v1" ? "/v1" : "/v1"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }

    private func replacingPort(of url: URL, with port: Int) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.port = port
        return components?.url
    }

    private func serverExecutableURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = environment["STENOTAB_LLAMA_SERVER_PATH"],
           !override.isEmpty {
            candidates.append(URL(filePath: override))
        }
        if let bundled = Bundle.main.url(
            forAuxiliaryExecutable: "llama-server"
        ) {
            candidates.append(bundled)
        }
        candidates.append(
            Bundle.main.bundleURL.appending(path: "Contents/Resources/llama-server")
        )
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(
                URL(filePath: String(directory), directoryHint: .isDirectory)
                    .appending(path: "llama-server")
            )
        }
        candidates.append(URL(filePath: "/opt/homebrew/bin/llama-server"))
        candidates.append(URL(filePath: "/usr/local/bin/llama-server"))

        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    private func makeLogHandle() throws -> FileHandle {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: "StenoTab",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        let logURL = support.appending(path: "llama-server.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            try Data().write(to: logURL)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        return handle
    }
}
