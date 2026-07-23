import AppKit
import CompletionCore

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
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        label = NSTextField(labelWithAttributedString: NSAttributedString())
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byClipping
        label.cell?.usesSingleLineMode = true
        panel.contentView = label
    }

    func show(
        _ suggestion: String,
        at caretRect: CGRect,
        typography: EditorTypography,
        foregroundColor: CGColor?
    ) {
        guard !suggestion.isEmpty, caretRect != .zero else {
            hide()
            return
        }

        let pointSize = CGFloat(typography.pointSize)
        let font = typography.fontName.flatMap {
            NSFont(name: $0, size: pointSize)
        } ?? .systemFont(ofSize: pointSize)
        let sourceColor = foregroundColor.flatMap(NSColor.init(cgColor:))
            ?? .labelColor
        let attributedSuggestion = NSAttributedString(
            string: suggestion,
            attributes: [
                .font: font,
                .foregroundColor: sourceColor.withAlphaComponent(0.34),
            ]
        )
        let size = fittedSize(
            for: attributedSuggestion,
            minimumHeight: caretRect.height
        )
        let origin = CGPoint(
            x: caretRect.maxX,
            y: caretRect.minY - (size.height - caretRect.height) / 2
        )

        label.attributedStringValue = attributedSuggestion
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        label.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }

    func consume(matchedText: String, remainingSuggestion: String) {
        guard
            !remainingSuggestion.isEmpty,
            label.attributedStringValue.length > 0
        else {
            hide()
            return
        }

        let attributes = label.attributedStringValue.attributes(
            at: 0,
            effectiveRange: nil
        )
        let matchedWidth = NSAttributedString(
            string: matchedText,
            attributes: attributes
        ).size().width
        let remaining = NSAttributedString(
            string: remainingSuggestion,
            attributes: attributes
        )
        let size = fittedSize(
            for: remaining,
            minimumHeight: panel.frame.height
        )
        var frame = panel.frame
        frame.origin.x += matchedWidth
        frame.size = size

        label.attributedStringValue = remaining
        panel.setFrame(frame, display: true)
        label.frame = NSRect(origin: .zero, size: size)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func fittedSize(
        for text: NSAttributedString,
        minimumHeight: CGFloat
    ) -> CGSize {
        let measured = text.size()
        return CGSize(
            width: min(max(ceil(measured.width) + 1, 1), 720),
            height: max(ceil(measured.height), minimumHeight)
        )
    }
}
