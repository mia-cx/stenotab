import AppKit
import ApplicationServices
import CompletionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: CompletionCoordinator?
    private var statusItem: NSStatusItem?
    private var modelStatusItem: NSMenuItem?
    private var localServer: LocalLlamaServer?
    private var localModelTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let environment = ProcessInfo.processInfo.environment
        let usesExplicitProvider =
            environment["STENOTAB_BASE_URL"] != nil &&
            environment["STENOTAB_MODEL"] != nil
        let initialProvider: any CompletionProvider = usesExplicitProvider
            ? ProviderFactory.make(environment: environment)
            : HeuristicCompletionProvider()
        let router = SwitchingCompletionProvider(initialProvider)
        let coordinator = CompletionCoordinator(provider: router)
        self.coordinator = coordinator
        installStatusItem(for: coordinator)
        coordinator.start()

        if usesExplicitProvider {
            modelStatusItem?.title = "Model: External API"
        } else {
            startConfiguredLocalModel(using: router)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localModelTask?.cancel()
        localServer?.stop()
    }

    private func installStatusItem(for coordinator: CompletionCoordinator) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarIcon()

        let menu = NSMenu()
        let status = NSMenuItem(
            title: "Checking permissions…",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        let modelStatus = NSMenuItem(
            title: "Model: Checking local runtime…",
            action: nil,
            keyEquivalent: ""
        )
        modelStatus.isEnabled = false
        menu.addItem(modelStatus)
        modelStatusItem = modelStatus

        let enabled = NSMenuItem(
            title: "Completions Enabled",
            action: #selector(CompletionCoordinator.toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enabled.target = coordinator
        enabled.state = .on
        menu.addItem(enabled)

        menu.addItem(.separator())

        let fixPermissions = NSMenuItem(
            title: "Fix Missing Permission…",
            action: #selector(CompletionCoordinator.openNextMissingPermission),
            keyEquivalent: ""
        )
        fixPermissions.target = coordinator
        menu.addItem(fixPermissions)

        let accessibilitySettings = NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(CompletionCoordinator.openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilitySettings.target = coordinator
        menu.addItem(accessibilitySettings)

        coordinator.observePermissionState { [weak status, weak fixPermissions] state in
            status?.title = state.menuTitle
            let ready = state.nextSettingsPane == nil
            fixPermissions?.title = ready
                ? "Permissions Granted"
                : "Fix Missing Permission…"
            fixPermissions?.isEnabled = !ready
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.menu = menu
        statusItem = item
    }

    private func menuBarIcon() -> NSImage? {
        if
            let url = Bundle.main.url(
                forResource: "StenoTabMenuBar",
                withExtension: "svg"
            ),
            let image = NSImage(contentsOf: url)
        {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            image.accessibilityDescription = "StenoTab"
            return image
        }

        return NSImage(
            systemSymbolName: "text.cursor",
            accessibilityDescription: "StenoTab"
        )
    }

    private func startConfiguredLocalModel(
        using router: SwitchingCompletionProvider
    ) {
        guard
            let configuration = ProviderFactory.localConfiguration(),
            let profile = LocalModelProfiles.profile(
                id: configuration.profileID
            )
        else {
            modelStatusItem?.title = "Model: Built-in demo"
            return
        }

        modelStatusItem?.title = "Model: Loading \(profile.displayName)…"
        let server = LocalLlamaServer(
            profile: profile,
            configuration: configuration
        )
        localServer = server
        localModelTask = Task { [weak self] in
            do {
                let connection = try await server.connectOrStart()
                guard
                    let provider = ProviderFactory.makeLocal(
                        configuration: configuration,
                        baseURL: connection.baseURL,
                        modelID: connection.modelID
                    )
                else {
                    self?.modelStatusItem?.title =
                        "Model: Invalid configuration"
                    return
                }
                await router.use(provider)
                self?.modelStatusItem?.title = switch connection.ownership {
                case .external:
                    "Model: Reusing compatible llama-server"
                case .stenotab:
                    "Model: Local llama.cpp ready"
                }
            } catch is CancellationError {
                return
            } catch {
                self?.modelStatusItem?.title =
                    "Model unavailable: \(error.localizedDescription)"
            }
        }
    }
}
