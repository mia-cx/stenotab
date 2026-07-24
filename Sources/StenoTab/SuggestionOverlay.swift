import AppKit
import CompletionCore
import CoreText

@MainActor
final class SuggestionOverlay {
    private struct PreparedPresentation {
        let attributes: [NSAttributedString.Key: Any]
        let linePlacement: PreparedOverlayLinePlacement
        let leadingWhitespaceCompensation: CGFloat
    }

    private let panel: NSPanel
    private let textView: GhostTextView
    private var preparedPresentation: PreparedPresentation?

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
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

    func prepare(
        at caretRect: CGRect,
        typography: EditorTypography,
        foregroundColor: CGColor?,
        leadingWhitespaceCompensation: CGFloat
    ) {
        guard OverlayGeometry.isUsableCaretRect(caretRect) else {
            preparedPresentation = nil
            return
        }

        let pointSize = CGFloat(typography.pointSize)
        let font = typography.fontName.flatMap {
            NSFont(name: $0, size: pointSize)
        } ?? .systemFont(ofSize: pointSize)
        let sourceColor = foregroundColor.flatMap(NSColor.init(cgColor:))
            ?? .labelColor
        let coreTextFont = CTFontCreateWithName(
            font.fontName as CFString,
            font.pointSize,
            nil
        )
        let backingScaleFactor = screen(containing: caretRect)?
            .backingScaleFactor ?? 2
        preparedPresentation = PreparedPresentation(
            attributes: [
                .font: font,
                .foregroundColor: sourceColor.withAlphaComponent(0.34),
            ],
            linePlacement: OverlayGeometry.prepareLinePlacement(
                caretRect: caretRect,
                ascent: CTFontGetAscent(coreTextFont),
                descent: CTFontGetDescent(coreTextFont),
                leading: CTFontGetLeading(coreTextFont),
                backingScaleFactor: backingScaleFactor
            ),
            leadingWhitespaceCompensation: leadingWhitespaceCompensation
        )
    }

    func show(_ suggestion: String) {
        guard
            !suggestion.isEmpty,
            let preparedPresentation
        else {
            hide()
            return
        }

        let attributedSuggestion = NSMutableAttributedString(
            string: suggestion,
            attributes: preparedPresentation.attributes
        )
        let leadingSpaceLength = suggestion.prefix { $0 == " " }.utf16.count
        if abs(preparedPresentation.leadingWhitespaceCompensation) > 0.001,
           leadingSpaceLength > 0 {
            attributedSuggestion.addAttribute(
                .kern,
                value: preparedPresentation.leadingWhitespaceCompensation
                    * CGFloat(leadingSpaceLength),
                range: NSRange(
                    location: leadingSpaceLength - 1,
                    length: 1
                )
            )
        }
        let size = CGSize(
            width: overlayWidth(of: attributedSuggestion),
            height: preparedPresentation.linePlacement.height
        )

        panel.setFrame(
            NSRect(
                origin: preparedPresentation.linePlacement.origin,
                size: size
            ),
            display: false
        )
        textView.frame = NSRect(origin: .zero, size: size)
        textView.set(
            attributedSuggestion,
            baselineOffset: preparedPresentation.linePlacement.baselineOffset
        )
        panel.displayIfNeeded()
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
        let backingScaleFactor = panel.backingScaleFactor
        frame.origin = OverlayGeometry.pixelAlignedOrigin(
            frame.origin,
            backingScaleFactor: backingScaleFactor
        )
        frame.size = layout.size

        panel.setFrame(frame, display: false)
        textView.frame = NSRect(origin: .zero, size: layout.size)
        textView.set(
            remaining,
            baselineOffset: layout.baselineOffset
        )
        panel.displayIfNeeded()
    }

    func hide() {
        panel.orderOut(nil)
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

    private func overlayWidth(of text: NSAttributedString) -> CGFloat {
        min(max(ceil(lineWidth(of: text)) + 1, 1), 720)
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(midpoint) }
            ?? NSScreen.main
    }
}

private final class GhostTextView: NSView {
    private(set) var attributedText = NSAttributedString()
    private var baselineOffset: CGFloat = 0

    override var isOpaque: Bool { false }

    func set(
        _ attributedText: NSAttributedString,
        baselineOffset: CGFloat
    ) {
        self.attributedText = attributedText
        self.baselineOffset = baselineOffset
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
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: baselineOffset)
        CTLineDraw(
            CTLineCreateWithAttributedString(attributedText),
            context
        )
        context.restoreGState()
    }
}
