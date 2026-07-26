import AppKit

@MainActor
enum ApplicationMenu {
    static func install(
        on application: NSApplication,
        delegate: AppDelegate
    ) {
        let mainMenu = NSMenu()
        mainMenu.addItem(
            submenu: applicationMenu(delegate: delegate),
            title: "StenoTab"
        )
        mainMenu.addItem(submenu: editMenu(), title: "Edit")
        application.mainMenu = mainMenu
    }

    private static func applicationMenu(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "StenoTab")
        menu.addItem(
            title: "About StenoTab",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        )
        menu.addItem(.separator())

        let settings = menu.addItem(
            title: "Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settings.target = delegate

        menu.addItem(.separator())
        menu.addItem(
            title: "Hide StenoTab",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = menu.addItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:))
        )
        menu.addItem(.separator())
        menu.addItem(
            title: "Quit StenoTab",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redo = menu.addItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        menu.addItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        menu.addItem(
            title: "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "V"
        ).keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(.separator())
        menu.addItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        return menu
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(
        title: String,
        action: Selector?,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        addItem(item)
        return item
    }

    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
