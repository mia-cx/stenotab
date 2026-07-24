import Combine
import CompletionCore
import Foundation

enum CompletionRuntimeStatus: Equatable {
    case checking
    case builtInDemo
    case externalAPI
    case loading(modelName: String)
    case ready(modelName: String, detail: String)
    case unavailable(message: String)

    var title: String {
        switch self {
        case .checking:
            "Checking local runtime…"
        case .builtInDemo:
            "Built-in demo"
        case .externalAPI:
            "External API"
        case let .loading(modelName):
            "Loading \(modelName)…"
        case let .ready(modelName, _):
            modelName
        case .unavailable:
            "Model unavailable"
        }
    }

    var detail: String? {
        switch self {
        case .checking:
            "Inspecting configured provider and local server state."
        case .builtInDemo:
            "No local model is configured; only deterministic demo phrases are active."
        case .externalAPI:
            "Configured from the current StenoTab environment."
        case .loading:
            "Connecting to or starting StenoTab's llama.cpp server."
        case let .ready(_, detail):
            detail
        case let .unavailable(message):
            message
        }
    }

    var menuTitle: String {
        switch self {
        case let .unavailable(message):
            "Model unavailable: \(message)"
        default:
            "Model: \(title)"
        }
    }

    var isReady: Bool {
        switch self {
        case .builtInDemo, .externalAPI, .ready:
            true
        case .checking, .loading, .unavailable:
            false
        }
    }
}

@MainActor
final class RuntimeStatusStore: ObservableObject {
    @Published private(set) var permissionState = PermissionState(
        accessibilityGranted: false,
        screenRecordingGranted: false
    )
    @Published private(set) var modelStatus: CompletionRuntimeStatus = .checking

    func update(permissionState: PermissionState) {
        self.permissionState = permissionState
    }

    func update(modelStatus: CompletionRuntimeStatus) {
        self.modelStatus = modelStatus
    }
}
