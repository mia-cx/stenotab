import AppKit

@MainActor
final class SuggestionOverlay {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14)
        label.textColor = .tertiaryLabelColor
        label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        label.drawsBackground = true
        label.isBezeled = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.alignment = .left
        panel.contentView = label
    }

    func show(_ suggestion: String, at accessibilityRect: CGRect) {
        guard !suggestion.isEmpty, accessibilityRect != .zero else {
            hide()
            return
        }

        label.stringValue = suggestion
        let textSize = label.intrinsicContentSize
        let size = CGSize(
            width: min(max(textSize.width + 12, 24), 520),
            height: max(textSize.height + 6, 22)
        )

        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = mainHeight - accessibilityRect.maxY
        let origin = CGPoint(
            x: accessibilityRect.maxX + 2,
            y: cocoaY - (size.height - accessibilityRect.height) / 2
        )

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        label.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
