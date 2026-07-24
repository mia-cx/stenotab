import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginSettingsStore: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        status = service.status
    }

    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    var statusDetail: String? {
        if let errorMessage {
            return errorMessage
        }
        switch status {
        case .requiresApproval:
            return "Approval is required in System Settings > General > Login Items."
        case .notFound:
            return "Install StenoTab in Applications before enabling launch at login."
        case .enabled, .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        status = service.status
    }
}
