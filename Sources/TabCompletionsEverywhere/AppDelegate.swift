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
        coordinator.start()
        installStatusItem(for: coordinator)
    }

    private func installStatusItem(for coordinator: CompletionCoordinator) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "text.cursor",
            accessibilityDescription: "Tab Completions Everywhere"
        )

        let menu = NSMenu()
        let status = NSMenuItem(
            title: "Ready — type “thank” anywhere",
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

        let permissions = NSMenuItem(
            title: "Request Permissions",
            action: #selector(CompletionCoordinator.requestPermissions),
            keyEquivalent: ""
        )
        permissions.target = coordinator
        menu.addItem(permissions)

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
