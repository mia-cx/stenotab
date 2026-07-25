public enum TextElementPolicy {
    private static let supportedRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXComboBox",
        "AXEditableText",
        "AXDocument",
    ]

    public static func isSupported(role: String?) -> Bool {
        role.map(supportedRoles.contains) == true
    }

    public static func shouldSearchDescendants(
        rootIsUsable: Bool,
        rootIsWebContainer: Bool,
        appIsWebBacked: Bool
    ) -> Bool {
        appIsWebBacked && (rootIsWebContainer || !rootIsUsable)
    }

    public static func isEligibleFocusedCandidate(
        isFocusedRoot: Bool,
        focusedAttribute: Bool?
    ) -> Bool {
        isFocusedRoot || focusedAttribute == true
    }
}
