import Foundation

public enum InputKindInference {
    public static func classify(
        role: String?,
        subrole: String?,
        isWebBacked: Bool,
        semanticHints: [String]
    ) -> String? {
        let hint = semanticHints
            .joined(separator: " ")
            .lowercased()

        for (keywords, kind) in semanticKinds {
            if keywords.contains(where: hint.contains) {
                return kind
            }
        }

        if role == "AXSearchField" || subrole == "AXSearchField" {
            return "search"
        }
        if isWebBacked,
           role == "AXTextArea"
            || role == "AXEditableText"
            || subrole == "AXEditableText" {
            return "message"
        }
        if role == "AXTextArea" {
            return "multi-line text area"
        }
        if role == "AXTextField" {
            return "text field"
        }
        if role == "AXComboBox" {
            return "combo box"
        }
        return role ?? subrole
    }

    private static let semanticKinds: [([String], String)] = [
        (["comment"], "comment"),
        (["reply", "respond"], "reply"),
        (["message", "chat"], "message"),
        (["search", "find"], "search"),
        (["e-mail", "email"], "email"),
        (["post", "publish"], "post"),
        (["document", "editor"], "document"),
        (["code"], "code"),
    ]
}
