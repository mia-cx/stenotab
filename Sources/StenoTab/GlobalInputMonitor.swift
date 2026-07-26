import CompletionCore
@preconcurrency import CoreGraphics

final class GlobalInputMonitor {
    typealias MutationHandler = (ShadowTextBuffer.Mutation) -> Void
    typealias TabHandler = (SuggestionAcceptance.Scope) -> Bool
    typealias FocusHandler = () -> Void
    typealias SubmitHandler = () -> Bool

    private static let syntheticMarker: Int64 = 0x5441_4243

    private let onMutation: MutationHandler
    private let onTab: TabHandler
    private let onFocus: FocusHandler
    private let onSubmit: SubmitHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isSelectingScreenshotRegion = false
    private var reconcileFocusOnTabKeyUp = false

    var isRunning: Bool {
        eventTap != nil
    }

    init(
        onMutation: @escaping MutationHandler,
        onTab: @escaping TabHandler,
        onFocus: @escaping FocusHandler,
        onSubmit: @escaping SubmitHandler = { false }
    ) {
        self.onMutation = onMutation
        self.onTab = onTab
        self.onFocus = onFocus
        self.onSubmit = onSubmit
    }

    @MainActor
    func start() -> Bool {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseUp.rawValue)

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
    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        let codeUnits = Array(text.utf16)
        let source = CGEventSource(stateID: .hidSystemState)
        codeUnits.withUnsafeBufferPointer { buffer in
            for keyDown in [true, false] {
                let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: keyDown
                )
                event?.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                event?.setIntegerValueField(
                    .eventSourceUserData,
                    value: Self.syntheticMarker
                )
                event?.post(tap: .cghidEventTap)
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

        if type == .leftMouseUp || type == .rightMouseUp {
            if monitor.isSelectingScreenshotRegion {
                monitor.isSelectingScreenshotRegion = false
            } else {
                monitor.onFocus()
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown {
            if monitor.isSelectingScreenshotRegion {
                return Unmanaged.passUnretained(event)
            }
            monitor.onMutation(.focusChange)
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 48, monitor.reconcileFocusOnTabKeyUp {
                monitor.reconcileFocusOnTabKeyUp = false
                monitor.onFocus()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if monitor.isSelectingScreenshotRegion, keyCode == 53 {
            monitor.isSelectingScreenshotRegion = false
            return Unmanaged.passUnretained(event)
        }
        if keyCode == 48 {
            let action = KeyboardShortcutPolicy.tabAction(
                command: flags.contains(.maskCommand),
                shift: flags.contains(.maskShift),
                control: flags.contains(.maskControl),
                option: flags.contains(.maskAlternate)
            )
            let scope: SuggestionAcceptance.Scope?
            switch action {
            case .acceptNextWord:
                scope = .nextWord
            case .acceptEntireSuggestion:
                scope = .entireSuggestion
            case .passThrough:
                scope = nil
            }
            if let scope, monitor.onTab(scope) {
                monitor.reconcileFocusOnTabKeyUp = false
                return nil
            }
            monitor.reconcileFocusOnTabKeyUp = true
            monitor.onMutation(.focusChange)
            return Unmanaged.passUnretained(event)
        }
        if keyCode == 51 {
            monitor.onMutation(.deleteBackward)
            return Unmanaged.passUnretained(event)
        }
        if keyCode == 117 {
            monitor.onMutation(.deleteForward)
            return Unmanaged.passUnretained(event)
        }
        if (keyCode == 36 || keyCode == 76),
           !flags.contains(.maskShift),
           !flags.contains(.maskAlternate),
           monitor.onSubmit() {
            monitor.onMutation(.invalidate)
            return Unmanaged.passUnretained(event)
        }

        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            if KeyboardShortcutPolicy.preservesSuggestion(
                keyCode: keyCode,
                command: flags.contains(.maskCommand),
                shift: flags.contains(.maskShift),
                control: flags.contains(.maskControl),
                option: flags.contains(.maskAlternate)
            ) {
                monitor.isSelectingScreenshotRegion =
                    KeyboardShortcutPolicy.beginsInteractiveScreenshot(
                        keyCode: keyCode,
                        command: flags.contains(.maskCommand),
                        shift: flags.contains(.maskShift),
                        control: flags.contains(.maskControl),
                        option: flags.contains(.maskAlternate)
                    )
                return Unmanaged.passUnretained(event)
            }
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
