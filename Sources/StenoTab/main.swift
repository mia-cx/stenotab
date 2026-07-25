import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
ApplicationMenu.install(on: application, delegate: delegate)
application.run()
