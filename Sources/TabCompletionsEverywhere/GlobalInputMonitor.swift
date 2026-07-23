import AppKit
import CompletionCore
@preconcurrency import CoreGraphics

final class GlobalInputMonitor {
    typealias MutationHandler = (ShadowTextBuffer.Mutation) -> Void
    typealias TabHandler = () -> Bool

    private static let syntheticMarker: Int64 = 0x5441_4243

    private let onMutation: MutationHandler
    private let onTab: TabHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool {
        eventTap != nil
    }

    init(onMutation: @escaping MutationHandler, onTab: @escaping TabHandler) {
        self.onMutation = onMutation
        self.onTab = onTab
    }

    @MainActor
    func start() -> Bool {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDown.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: context
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    @MainActor
    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        )
        for event in [keyDown, keyUp] {
            event?.flags = .maskCommand
            event?.setIntegerValueField(
                .eventSourceUserData,
                value: Self.syntheticMarker
            )
            event?.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let oldString {
                pasteboard.setString(oldString, forType: .string)
            }
        }
    }

    private static let callback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<GlobalInputMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown {
            monitor.onMutation(.invalidate)
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 48, monitor.onTab() {
            return nil
        }
        if keyCode == 51 {
            monitor.onMutation(.deleteBackward)
            return Unmanaged.passUnretained(event)
        }
        if keyCode == 117 {
            monitor.onMutation(.deleteForward)
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            monitor.onMutation(.invalidate)
            return Unmanaged.passUnretained(event)
        }

        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &length,
            unicodeString: &characters
        )
        if length > 0 {
            monitor.onMutation(
                .insert(String(utf16CodeUnits: characters, count: length))
            )
        } else {
            monitor.onMutation(.invalidate)
        }
        return Unmanaged.passUnretained(event)
    }
}
