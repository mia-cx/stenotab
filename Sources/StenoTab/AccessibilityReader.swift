import AppKit
import ApplicationServices
import CompletionCore

struct EditorSnapshot {
    let prefix: String
    let suffix: String
    /// AppKit global-screen coordinates.
    let caretRect: CGRect
    let typography: EditorTypography
    let foregroundColor: CGColor?
    let processID: pid_t
    let isWebBacked: Bool
    let editorIdentifier: String
    let applicationName: String?
    let applicationBundleIdentifier: String?
    let applicationBundleURL: URL?
    let inputKind: String?
}

@MainActor
final class AccessibilityReader {
    private static let webBackedBundleIdentifiers: Set<String> = [
        "com.hnc.Discord",
        "com.hnc.DiscordCanary",
        "com.hnc.DiscordPTB",
        "com.openai.chat",
        "com.openai.chatgpt",
        "com.openai.codex",
        "com.tinyspeck.slackmacgap",
        "com.google.Chrome",
        "company.thebrowser.Browser",
    ]
    private var cachedWebTextElement: AXUIElement?
    private var cachedWebTextElementPID: pid_t?

    func requestTrustPrompt() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func frontmostApplicationBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func snapshot() -> EditorSnapshot? {
        guard AXIsProcessTrusted() else { return nil }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if cachedWebTextElementPID != frontmostApp?.processIdentifier {
            cachedWebTextElement = nil
            cachedWebTextElementPID = frontmostApp?.processIdentifier
        }
        let appIsWebBacked = frontmostApp
            .flatMap(\.bundleIdentifier)
            .map(Self.isWebBacked(bundleIdentifier:)) ?? false
        if let frontmostApp, appIsWebBacked {
            enableEnhancedAccessibility(for: frontmostApp)
        }

        let system = AXUIElementCreateSystemWide()
        guard
            let focusedRoot = focusedElement(on: system)
                ?? frontmostApp.flatMap({
                    focusedElement(
                        on: AXUIElementCreateApplication($0.processIdentifier)
                    )
                }),
            let focused = textElement(
                from: focusedRoot,
                appIsWebBacked: appIsWebBacked
            )
        else {
            return nil
        }

        let role = stringAttribute(kAXRoleAttribute, from: focused)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focused)
        let protected = boolAttribute("AXProtectedContent", from: focused) == true
        guard role != kAXSecureTextFieldSubrole as String,
              subrole != kAXSecureTextFieldSubrole as String,
              !protected else {
            return nil
        }

        let value = stringAttribute(kAXValueAttribute, from: focused) ?? ""
        let range = selectedRange(of: focused)
            ?? CFRange(location: value.utf16.count, length: 0)
        guard range.location >= 0, range.location <= value.utf16.count else {
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
        let caretRect = caretBounds(
            of: focused,
            range: range,
            precedingCharacter: prefix.last
        )
            ?? estimatedCaretBounds(of: focused, prefix: prefix)
            ?? .zero
        let appearance = textAppearance(
            of: focused,
            caretLocation: range.location,
            textLength: value.utf16.count,
            caretHeight: caretRect.height,
            reconcileReportedSizeWithCaret: appIsWebBacked
        )

        return EditorSnapshot(
            prefix: prefix,
            suffix: suffix,
            caretRect: caretRect,
            typography: appearance.typography,
            foregroundColor: appearance.foregroundColor,
            processID: pid,
            isWebBacked: appIsWebBacked,
            editorIdentifier: elementIdentity(focused),
            applicationName: frontmostApp?.localizedName,
            applicationBundleIdentifier: frontmostApp?.bundleIdentifier,
            applicationBundleURL: frontmostApp?.bundleURL,
            inputKind: inputKind(
                role: role,
                subrole: subrole,
                isWebBacked: appIsWebBacked
            )
        )
    }

    private func inputKind(
        role: String?,
        subrole: String?,
        isWebBacked: Bool
    ) -> String? {
        if isWebBacked,
           role == kAXTextAreaRole as String
            || role == "AXEditableText"
            || subrole == "AXEditableText" {
            return "message or rich-text input"
        }
        if role == kAXTextAreaRole as String {
            return "multi-line text area"
        }
        if role == kAXTextFieldRole as String {
            return "text field"
        }
        if role == kAXComboBoxRole as String {
            return "combo box"
        }
        return role ?? subrole
    }

    private static func isWebBacked(bundleIdentifier: String) -> Bool {
        if webBackedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        let normalized = bundleIdentifier.lowercased()
        return normalized.contains("discord") || normalized.contains("openai")
    }

    private func enableEnhancedAccessibility(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
    }

    private func textElement(
        from root: AXUIElement,
        appIsWebBacked: Bool
    ) -> AXUIElement? {
        if appIsWebBacked,
           let cachedWebTextElement,
           isUsableTextElement(cachedWebTextElement),
           boolAttribute(kAXFocusedAttribute, from: cachedWebTextElement) != false {
            return cachedWebTextElement
        }

        let rootIsUsable = isUsableTextElement(root)
        let rootRole = stringAttribute(kAXRoleAttribute, from: root)
        let rootSubrole = stringAttribute(kAXSubroleAttribute, from: root)
        let rootIsWebContainer = rootRole == "AXWebArea"
            || rootRole == "AXDocument"
            || rootSubrole == "AXWebArea"
            || rootSubrole == "AXDocument"
        let shouldSearch = TextElementPolicy.shouldSearchDescendants(
            rootIsUsable: rootIsUsable,
            rootIsWebContainer: rootIsWebContainer,
            appIsWebBacked: appIsWebBacked
        )

        if rootIsUsable, !shouldSearch {
            return root
        }
        guard shouldSearch else { return nil }

        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = Set<String>()
        var best: (element: AXUIElement, score: Int)?

        while !queue.isEmpty, visited.count < 600 {
            let (candidate, depth) = queue.removeFirst()
            let identity = elementIdentity(candidate)
            guard visited.insert(identity).inserted else { continue }

            if isUsableTextElement(candidate) {
                let score = textElementScore(candidate)
                if best == nil || score > best!.score {
                    best = (candidate, score)
                }
            }

            guard depth < 20 else { continue }
            for child in childElements(of: candidate) {
                queue.append((child, depth + 1))
            }
        }

        let result = best?.element ?? (rootIsUsable ? root : nil)
        if appIsWebBacked {
            cachedWebTextElement = result
        }
        return result
    }

    private func isUsableTextElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        guard TextElementPolicy.isSupported(role: role)
                || TextElementPolicy.isSupported(role: subrole) else {
            return false
        }
        return selectedRange(of: element) != nil
            || stringAttribute(kAXValueAttribute, from: element) != nil
    }

    private func textElementScore(_ element: AXUIElement) -> Int {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        var score = 0
        if boolAttribute(kAXFocusedAttribute, from: element) == true {
            score += 1_000
        }
        if selectedRange(of: element) != nil {
            score += 300
        }
        if role == kAXTextAreaRole as String
            || role == kAXTextFieldRole as String
            || role == kAXComboBoxRole as String {
            score += 100
        }
        if subrole == "AXEditableText" || role == "AXEditableText" {
            score += 80
        }
        return score
    }

    private func textAppearance(
        of element: AXUIElement,
        caretLocation: Int,
        textLength: Int,
        caretHeight: CGFloat,
        reconcileReportedSizeWithCaret: Bool
    ) -> (typography: EditorTypography, foregroundColor: CGColor?) {
        guard textLength > 0 else {
            return fallbackAppearance(
                caretHeight: caretHeight,
                reconcileReportedSizeWithCaret:
                    reconcileReportedSizeWithCaret
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
            return fallbackAppearance(
                caretHeight: caretHeight,
                reconcileReportedSizeWithCaret:
                    reconcileReportedSizeWithCaret
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
                caretHeight: caretHeight,
                reconcileReportedSizeWithCaret:
                    reconcileReportedSizeWithCaret
            ),
            foregroundColor
        )
    }

    private func fallbackAppearance(
        caretHeight: CGFloat,
        reconcileReportedSizeWithCaret: Bool
    ) -> (typography: EditorTypography, foregroundColor: CGColor?) {
        (
            EditorTypography(
                reportedFontName: nil,
                reportedPointSize: nil,
                caretHeight: caretHeight,
                reconcileReportedSizeWithCaret:
                    reconcileReportedSizeWithCaret
            ),
            nil
        )
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        guard
            let raw = copyRawAttribute(
                kAXSelectedTextRangeAttribute,
                from: element
            ),
            CFGetTypeID(raw) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private func caretBounds(
        of element: AXUIElement,
        range: CFRange,
        precedingCharacter: Character?
    ) -> CGRect? {
        var caretRange = CFRange(location: range.location, length: 0)
        if
            let rangeValue = AXValueCreate(.cfRange, &caretRange),
            let raw = copyParameterizedAttribute(
                kAXBoundsForRangeParameterizedAttribute,
                parameter: rangeValue,
                from: element
            ),
            let bounds = rect(from: raw),
            OverlayGeometry.isUsableCaretRect(bounds)
        {
            let previousBounds: CGRect?
            if range.location > 0 {
                var previousRange = CFRange(
                    location: range.location - 1,
                    length: 1
                )
                previousBounds = AXValueCreate(.cfRange, &previousRange)
                    .flatMap {
                        copyParameterizedAttribute(
                            kAXBoundsForRangeParameterizedAttribute,
                            parameter: $0,
                            from: element
                        )
                    }
                    .flatMap(rect(from:))
            } else {
                previousBounds = nil
            }
            let reconciled = OverlayGeometry.reconcileCaretRect(
                bounds,
                previousCharacterRect: previousBounds,
                precedingCharacterIsLineBreak:
                    precedingCharacter == "\n"
                    || precedingCharacter == "\r"
            )
            return cocoaRect(fromAccessibilityRect: reconciled)
        }

        guard
            let markerRange = copyRawAttribute(
                "AXSelectedTextMarkerRange",
                from: element
            ),
            let raw = copyParameterizedAttribute(
                "AXBoundsForTextMarkerRange",
                parameter: markerRange,
                from: element
            ),
            let bounds = rect(from: raw),
            OverlayGeometry.isUsableCaretRect(bounds)
        else {
            return nil
        }
        return cocoaRect(fromAccessibilityRect: bounds)
    }

    private func estimatedCaretBounds(
        of element: AXUIElement,
        prefix: String
    ) -> CGRect? {
        guard
            let rawFrame = rectAttribute("AXFrame", from: element),
            !rawFrame.isEmpty
        else {
            return nil
        }
        let frame = cocoaRect(fromAccessibilityRect: rawFrame)
        let font = NSFont.systemFont(ofSize: 13)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lastLine = prefix.components(separatedBy: .newlines).last ?? ""
        let lineWidth = (lastLine as NSString).size(
            withAttributes: [.font: font]
        ).width
        let logicalLineCount = max(
            1,
            prefix.components(separatedBy: .newlines).count
        )
        let x = min(frame.maxX - 2, frame.minX + 8 + lineWidth)
        let y = max(
            frame.minY + 4,
            frame.maxY - 8 - CGFloat(logicalLineCount) * lineHeight
        )
        return CGRect(x: x, y: y, width: 2, height: lineHeight)
    }

    private func cocoaRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            guard
                let screenNumber = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                continue
            }
            let displayBounds = CGDisplayBounds(
                CGDirectDisplayID(screenNumber.uint32Value)
            )
            guard displayBounds.contains(midpoint)
                    || displayBounds.intersects(rect) else {
                continue
            }
            return CGRect(
                x: screen.frame.minX + rect.minX - displayBounds.minX,
                y: screen.frame.maxY - (rect.minY - displayBounds.minY)
                    - rect.height,
                width: rect.width,
                height: rect.height
            )
        }

        let desktopBounds = NSScreen.screens
            .map(\.frame)
            .reduce(into: CGRect.null) { $0 = $0.union($1) }
        guard !desktopBounds.isNull else { return rect }
        return CGRect(
            x: rect.minX,
            y: desktopBounds.maxY - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func focusedElement(on element: AXUIElement) -> AXUIElement? {
        guard
            let raw = copyRawAttribute(
                kAXFocusedUIElementAttribute,
                from: element
            ),
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard
            let rawChildren = copyRawAttribute(kAXChildrenAttribute, from: element)
                as? [AnyObject]
        else {
            return []
        }
        return rawChildren.compactMap { raw in
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(raw, to: AXUIElement.self)
        }
    }

    private func elementIdentity(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return "\(pid)-\(CFHash(element))"
    }

    private func stringAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> String? {
        guard let raw = copyRawAttribute(name, from: element) else { return nil }
        if let string = raw as? String {
            return string
        }
        if let attributed = raw as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    private func boolAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> Bool? {
        guard let raw = copyRawAttribute(name, from: element) else { return nil }
        if let bool = raw as? Bool {
            return bool
        }
        return (raw as? NSNumber)?.boolValue
    }

    private func rectAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> CGRect? {
        guard let raw = copyRawAttribute(name, from: element) else { return nil }
        return rect(from: raw)
    }

    private func rect(from raw: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    private func copyRawAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &raw
        ) == .success else {
            return nil
        }
        return raw
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
