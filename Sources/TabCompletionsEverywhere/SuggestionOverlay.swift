import AppKit
import CompletionCore

@MainActor
final class SuggestionOverlay {
    private let panel: NSPanel
    private let ghostTextView: GhostTextView

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

        ghostTextView = GhostTextView()
        panel.contentView = ghostTextView
    }

    func show(
        _ suggestion: String,
        at accessibilityRect: CGRect,
        typography: EditorTypography,
        foregroundColor: CGColor?
    ) {
        guard !suggestion.isEmpty, accessibilityRect != .zero else {
            hide()
            return
        }

        let pointSize = CGFloat(typography.pointSize)
        let font = typography.fontName.flatMap {
            NSFont(name: $0, size: pointSize)
        } ?? .systemFont(ofSize: pointSize)
        let sourceColor = foregroundColor.flatMap(NSColor.init(cgColor:))
            ?? .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: sourceColor.withAlphaComponent(0.34),
        ]
        let attributedSuggestion = NSAttributedString(
            string: suggestion,
            attributes: attributes
        )
        let textSize = attributedSuggestion.size()
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let size = CGSize(
            width: min(max(ceil(textSize.width) + 1, 1), 720),
            height: max(ceil(textSize.height), lineHeight, accessibilityRect.height)
        )

        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let caretBottom = primaryScreenHeight - accessibilityRect.maxY
        let origin = CGPoint(
            x: accessibilityRect.maxX,
            y: caretBottom - (size.height - accessibilityRect.height) / 2
        )

        ghostTextView.attributedText = attributedSuggestion
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        ghostTextView.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

@MainActor
private final class GhostTextView: NSView {
    var attributedText = NSAttributedString() {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let textHeight = attributedText.size().height
        let y = max(0, (bounds.height - textHeight) / 2)
        attributedText.draw(at: CGPoint(x: 0, y: y))
    }
}
