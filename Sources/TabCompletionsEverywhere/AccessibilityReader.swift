import AppKit
import ApplicationServices

struct EditorSnapshot {
    let prefix: String
    let suffix: String
    let caretRect: CGRect
    let processID: pid_t
}

final class AccessibilityReader {
    func requestTrustPrompt() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func snapshot() -> EditorSnapshot? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        guard let focused: AXUIElement = copyAttribute(
            kAXFocusedUIElementAttribute,
            from: system
        ) else {
            return nil
        }

        let role: String? = copyAttribute(kAXRoleAttribute, from: focused)
        let subrole: String? = copyAttribute(kAXSubroleAttribute, from: focused)
        guard role == kAXTextFieldRole as String ||
              role == kAXTextAreaRole as String ||
              role == kAXComboBoxRole as String
        else {
            return nil
        }
        guard subrole != kAXSecureTextFieldSubrole as String else { return nil }

        guard
            let value: String = copyAttribute(kAXValueAttribute, from: focused),
            let range = selectedRange(of: focused),
            range.location >= 0,
            range.location <= value.utf16.count
        else {
            return nil
        }

        let utf16 = value.utf16
        let caretIndex = utf16.index(utf16.startIndex, offsetBy: range.location)
        let prefix = String(decoding: utf16[..<caretIndex], as: UTF16.self)
        let selectionEnd = min(range.location + range.length, utf16.count)
        let suffixIndex = utf16.index(utf16.startIndex, offsetBy: selectionEnd)
        let suffix = String(decoding: utf16[suffixIndex...], as: UTF16.self)

        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)

        return EditorSnapshot(
            prefix: prefix,
            suffix: suffix,
            caretRect: caretBounds(of: focused, range: range) ?? .zero,
            processID: pid
        )
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value: AXValue = copyAttribute(
            kAXSelectedTextRangeAttribute,
            from: element
        ) else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private func caretBounds(of element: AXUIElement, range: CFRange) -> CGRect? {
        var caretRange = CFRange(location: range.location, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &caretRange) else {
            return nil
        }

        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &raw
        ) == .success, let boundsValue = raw as! AXValue? else {
            return nil
        }

        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &bounds) else { return nil }
        return bounds
    }

    private func copyAttribute<T>(
        _ name: String,
        from element: AXUIElement
    ) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &raw
        ) == .success else {
            return nil
        }
        return raw as? T
    }
}
