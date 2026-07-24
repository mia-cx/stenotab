import AppKit
import ApplicationServices
import CompletionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum DailyCountDefaults {
        static let count = "dailyAcceptedSuggestionCount"
        static let referenceDate = "dailyAcceptedSuggestionReferenceDate"
    }

    private var coordinator: CompletionCoordinator?
    private var statusItem: NSStatusItem?
    private var modelStatusItem: NSMenuItem?
    private var localServer: LocalLlamaServer?
    private var localModelTask: Task<Void, Never>?
    private let promptSettings = PromptSettingsStore()
    private var promptLabWindowController: PromptLabWindowController?
    private var dailyAcceptanceCounter = DailyAcceptanceCounter(
        count: 0,
        referenceDate: Date()
    )
    private var calendarDayObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        let environment = ProcessInfo.processInfo.environment
        let usesExplicitProvider =
            environment["STENOTAB_BASE_URL"] != nil &&
            environment["STENOTAB_MODEL"] != nil
        let initialProvider: any CompletionProvider = usesExplicitProvider
            ? ProviderFactory.make(environment: environment)
            : HeuristicCompletionProvider()
        let router = SwitchingCompletionProvider(initialProvider)
        let coordinator = CompletionCoordinator(
            provider: router,
            promptConfiguration: { [promptSettings] in
                promptSettings.configuration
            },
            onSuggestionAccepted: { [weak self] _ in
                self?.recordSuggestionAcceptance()
            }
        )
        self.coordinator = coordinator
        installStatusItem(for: coordinator)
        loadDailyAcceptanceCount()
        observeCalendarDayChanges()
        coordinator.start()

        if usesExplicitProvider {
            modelStatusItem?.title = "Model: External API"
        } else {
            startConfiguredLocalModel(using: router)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let calendarDayObserver {
            NotificationCenter.default.removeObserver(calendarDayObserver)
        }
        localModelTask?.cancel()
        localServer?.stop()
    }

    private func installStatusItem(for coordinator: CompletionCoordinator) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = menuBarIcon()
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.font = .menuBarFont(ofSize: 0)
        }

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

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsWindow),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.menu = menu
        statusItem = item
    }

    private func loadDailyAcceptanceCount() {
        let defaults = UserDefaults.standard
        let now = Date()
        let referenceDate = defaults.object(
            forKey: DailyCountDefaults.referenceDate
        ) as? Date ?? now
        dailyAcceptanceCounter = DailyAcceptanceCounter(
            count: defaults.integer(forKey: DailyCountDefaults.count),
            referenceDate: referenceDate
        )
        _ = dailyAcceptanceCounter.refresh(for: now)
        persistDailyAcceptanceCount()
        updateDailyAcceptanceCountDisplay()
    }

    private func recordSuggestionAcceptance() {
        dailyAcceptanceCounter.recordAcceptance(at: Date())
        persistDailyAcceptanceCount()
        updateDailyAcceptanceCountDisplay()
    }

    private func observeCalendarDayChanges() {
        calendarDayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.dailyAcceptanceCounter.refresh(for: Date()) {
                    self.persistDailyAcceptanceCount()
                    self.updateDailyAcceptanceCountDisplay()
                }
            }
        }
    }

    private func persistDailyAcceptanceCount() {
        let defaults = UserDefaults.standard
        defaults.set(
            dailyAcceptanceCounter.count,
            forKey: DailyCountDefaults.count
        )
        defaults.set(
            dailyAcceptanceCounter.referenceDate,
            forKey: DailyCountDefaults.referenceDate
        )
    }

    private func updateDailyAcceptanceCountDisplay() {
        guard
            let statusItem,
            let button = statusItem.button
        else {
            return
        }
        let counterTitle = NSAttributedString(
            string: "\u{2002}\(dailyAcceptanceCounter.count)",
            attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .baselineOffset: -0.5,
            ]
        )
        button.attributedTitle = counterTitle
        let imageWidth = button.image?.size.width ?? 0
        let imageTitleSpacing: CGFloat = 2
        let totalOuterPadding: CGFloat = 4
        statusItem.length = ceil(
            imageWidth
                + counterTitle.size().width
                + imageTitleSpacing
                + totalOuterPadding
        )
        button.setAccessibilityLabel(
            "StenoTab, \(dailyAcceptanceCounter.count) suggestions accepted today"
        )
    }

    @objc private func openSettingsWindow() {
        if promptLabWindowController == nil {
            promptLabWindowController = PromptLabWindowController(
                store: promptSettings
            )
            promptLabWindowController?.window?.delegate = self
        }

        NSApp.setActivationPolicy(.regular)
        promptLabWindowController?.showWindow(nil)
        promptLabWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === promptLabWindowController?.window
        else {
            return
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(title: "StenoTab", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "StenoTab")

        let aboutItem = NSMenuItem(
            title: "About StenoTab",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "Hide StenoTab",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        applicationMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        applicationMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        applicationMenu.addItem(showAllItem)
        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit StenoTab",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)

        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
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
            let targetHeight: CGFloat = 18
            let aspectRatio = image.size.width / image.size.height
            image.size = NSSize(
                width: targetHeight * aspectRatio,
                height: targetHeight
            )
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
