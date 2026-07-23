public enum KeyboardShortcutPolicy {
    private static let screenshotKeyCodes: Set<Int64> = [
        20, // 3 — capture screen
        21, // 4 — capture selection
        22, // 6 — capture Touch Bar where available
        23, // 5 — open Screenshot
    ]

    public static func preservesSuggestion(
        keyCode: Int64,
        command: Bool,
        shift: Bool,
        control: Bool,
        option: Bool
    ) -> Bool {
        _ = control // Control selects the clipboard variants.
        return command
            && shift
            && !option
            && screenshotKeyCodes.contains(keyCode)
    }

    public static func beginsInteractiveScreenshot(
        keyCode: Int64,
        command: Bool,
        shift: Bool,
        control: Bool,
        option: Bool
    ) -> Bool {
        preservesSuggestion(
            keyCode: keyCode,
            command: command,
            shift: shift,
            control: control,
            option: option
        ) && keyCode == 21
    }
}
