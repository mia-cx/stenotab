import AppKit
import ApplicationServices
import CompletionCore

struct EditorSnapshot {
    let prefix: String
    let suffix: String
    let caretRect: CGRect
    let typography: EditorTypography
    let foregroundColor: CGColor?
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
        let caretRect = caretBounds(of: focused, range: range) ?? .zero
        let appearance = textAppearance(
            of: focused,
            caretLocation: range.location,
            textLength: value.utf16.count,
            caretHeight: caretRect.height
        )

        return EditorSnapshot(
            prefix: prefix,
            suffix: suffix,
            caretRect: caretRect,
            typography: appearance.typography,
            foregroundColor: appearance.foregroundColor,
            processID: pid
        )
    }

    private func textAppearance(
        of element: AXUIElement,
        caretLocation: Int,
        textLength: Int,
        caretHeight: CGFloat
    ) -> (typography: EditorTypography, foregroundColor: CGColor?) {
        guard textLength > 0 else {
            return (
                EditorTypography(
                    reportedFontName: nil,
                    reportedPointSize: nil,
                    caretHeight: caretHeight
                ),
                nil
            )
        }

        var styleRange = CFRange(
            location: min(max(caretLocation - 1, 0), textLength - 1),
            length: 1
        )
        guard
            let rangeValue = AXValueCreate(.cfRange, &styleRange),
            let attributed = copyParameterizedAttribute(
                kAXAttributedStringForRangeParameterizedAttribute,
                parameter: rangeValue,
                from: element
            ) as? NSAttributedString,
            attributed.length > 0
        else {
            return (
                EditorTypography(
                    reportedFontName: nil,
                    reportedPointSize: nil,
                    caretHeight: caretHeight
                ),
                nil
            )
        }

        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        let fontDictionary = attributes[.accessibilityFont] as? NSDictionary
        let fontName = fontDictionary?[
            NSAccessibility.FontAttributeKey.fontName
        ] as? String
        let fontSize = (
            fontDictionary?[
                NSAccessibility.FontAttributeKey.fontSize
            ] as? NSNumber
        )?.doubleValue
        let foregroundValue = attributes[.accessibilityForegroundColor]
        let foregroundColor: CGColor?
        if
            let foregroundValue,
            CFGetTypeID(foregroundValue as CFTypeRef) == CGColor.typeID
        {
            foregroundColor = (foregroundValue as! CGColor)
        } else {
            foregroundColor = nil
        }

        return (
            EditorTypography(
                reportedFontName: fontName,
                reportedPointSize: fontSize,
                caretHeight: caretHeight
            ),
            foregroundColor
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

    private func copyParameterizedAttribute(
        _ name: String,
        parameter: CFTypeRef,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            name as CFString,
            parameter,
            &raw
        ) == .success else {
            return nil
        }
        return raw
    }
}
