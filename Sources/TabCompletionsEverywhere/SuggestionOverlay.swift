import AppKit
import CompletionCore
import CoreText

@MainActor
final class SuggestionOverlay {
    private let panel: NSPanel
    private let textView: GhostTextView
    private var solidCaretColor: NSColor?

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

        textView = GhostTextView()
        panel.contentView = textView
    }

    func show(
        _ suggestion: String,
        at caretRect: CGRect,
        typography: EditorTypography,
        foregroundColor: CGColor?,
        leadingWhitespaceCompensation: CGFloat
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
        solidCaretColor = sourceColor
        let attributedSuggestion = NSMutableAttributedString(
            string: suggestion,
            attributes: [
                .font: font,
                .foregroundColor: sourceColor.withAlphaComponent(0.34),
            ]
        )
        let leadingSpaceLength = suggestion.prefix { $0 == " " }.utf16.count
        if leadingWhitespaceCompensation > 0, leadingSpaceLength > 0 {
            attributedSuggestion.addAttribute(
                .kern,
                value: leadingWhitespaceCompensation,
                range: NSRange(
                    location: leadingSpaceLength - 1,
                    length: 1
                )
            )
        }
        let layout = layout(
            for: attributedSuggestion,
            minimumHeight: caretRect.height
        )
        let origin = CGPoint(
            x: caretRect.maxX,
            y: caretRect.minY - (layout.size.height - caretRect.height) / 2
        )

        textView.set(
            attributedSuggestion,
            baselineOffset: layout.baselineOffset,
            caretColor: OverlayGeometry.shouldStabilizeCaret(
                for: suggestion
            ) ? sourceColor : nil
        )
        panel.setFrame(
            NSRect(origin: origin, size: layout.size),
            display: true
        )
        textView.frame = NSRect(origin: .zero, size: layout.size)
        panel.orderFrontRegardless()
    }

    func consume(matchedText: String, remainingSuggestion: String) {
        guard
            !remainingSuggestion.isEmpty,
            textView.attributedText.length > 0
        else {
            hide()
            return
        }

        let previous = textView.attributedText
        let matchedLength = (matchedText as NSString).length
        guard matchedLength <= previous.length else {
            hide()
            return
        }
        let remaining = previous.attributedSubstring(
            from: NSRange(
                location: matchedLength,
                length: previous.length - matchedLength
            )
        )
        let layout = layout(
            for: remaining,
            minimumHeight: panel.frame.height
        )
        var frame = panel.frame
        frame.origin.x += lineWidth(of: previous) - lineWidth(of: remaining)
        frame.size = layout.size

        textView.set(
            remaining,
            baselineOffset: layout.baselineOffset,
            caretColor: OverlayGeometry.shouldStabilizeCaret(
                for: remainingSuggestion
            ) ? solidCaretColor : nil
        )
        panel.setFrame(frame, display: true)
        textView.frame = NSRect(origin: .zero, size: layout.size)
    }

    func hide() {
        panel.orderOut(nil)
        solidCaretColor = nil
    }

    private func layout(
        for text: NSAttributedString,
        minimumHeight: CGFloat
    ) -> (size: CGSize, baselineOffset: CGFloat) {
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(
            CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
        )
        let height = max(
            ceil(ascent + descent + leading),
            minimumHeight
        )
        return (
            CGSize(
                width: min(max(ceil(width) + 1, 1), 720),
                height: height
            ),
            OverlayGeometry.baselineOffset(
                containerHeight: height,
                ascent: ascent,
                descent: descent,
                leading: leading
            )
        )
    }

    private func lineWidth(of text: NSAttributedString) -> CGFloat {
        CGFloat(
            CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(text),
                nil,
                nil,
                nil
            )
        )
    }
}

private final class GhostTextView: NSView {
    private(set) var attributedText = NSAttributedString()
    private var baselineOffset: CGFloat = 0
    private var caretColor: NSColor?

    override var isOpaque: Bool { false }

    func set(
        _ attributedText: NSAttributedString,
        baselineOffset: CGFloat,
        caretColor: NSColor?
    ) {
        self.attributedText = attributedText
        self.baselineOffset = baselineOffset
        self.caretColor = caretColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            attributedText.length > 0,
            let context = NSGraphicsContext.current?.cgContext
        else {
            return
        }

        context.saveGState()
        if let caretColor {
            context.setFillColor(caretColor.cgColor)
            context.fill(
                CGRect(x: 0, y: 0, width: 1, height: bounds.height)
            )
        }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: baselineOffset)
        CTLineDraw(CTLineCreateWithAttributedString(attributedText), context)
        context.restoreGState()
    }
}
