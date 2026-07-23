import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: CompletionCoordinator?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let coordinator = CompletionCoordinator()
        self.coordinator = coordinator
        installStatusItem(for: coordinator)
        coordinator.start()
    }

    private func installStatusItem(for coordinator: CompletionCoordinator) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "text.cursor",
            accessibilityDescription: "Tab Completions Everywhere"
        )

        let menu = NSMenu()
        let status = NSMenuItem(
            title: "Checking permissions…",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

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
}
