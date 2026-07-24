import CoreGraphics

public struct PreparedOverlayLinePlacement: Sendable, Equatable {
    public let origin: CGPoint
    public let height: CGFloat
    public let baselineOffset: CGFloat

    public init(
        origin: CGPoint,
        height: CGFloat,
        baselineOffset: CGFloat
    ) {
        self.origin = origin
        self.height = height
        self.baselineOffset = baselineOffset
    }
}

public enum OverlayGeometry {
    public static func pixelAlignedOrigin(
        _ origin: CGPoint,
        backingScaleFactor: CGFloat
    ) -> CGPoint {
        guard backingScaleFactor.isFinite, backingScaleFactor > 0 else {
            return origin
        }
        return CGPoint(
            x: (origin.x * backingScaleFactor).rounded()
                / backingScaleFactor,
            y: (origin.y * backingScaleFactor).rounded()
                / backingScaleFactor
        )
    }

    public static func isUsableCaretRect(_ rect: CGRect) -> Bool {
        !rect.isNull
            && !rect.isInfinite
            && rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.height >= 1
    }

    public static func reconcileCaretRect(
        _ reportedCaretRect: CGRect,
        previousCharacterRect: CGRect?,
        precedingCharacterIsLineBreak: Bool
    ) -> CGRect {
        guard
            !precedingCharacterIsLineBreak,
            let previousCharacterRect,
            isUsableCaretRect(reportedCaretRect),
            isUsableCaretRect(previousCharacterRect)
        else {
            return reportedCaretRect
        }

        let lineHeight = max(
            reportedCaretRect.height,
            previousCharacterRect.height
        )
        let sharesEndpoint = abs(
            reportedCaretRect.minX - previousCharacterRect.maxX
        ) <= max(1, lineHeight * 0.04)
        let hasMatchingHeight = abs(
            reportedCaretRect.height - previousCharacterRect.height
        ) <= max(1, lineHeight * 0.08)
        let verticalOffset = abs(
            reportedCaretRect.minY - previousCharacterRect.minY
        )
        let isExactlyOneLineAway =
            (lineHeight * 0.75 ... lineHeight * 1.25)
                .contains(verticalOffset)

        guard sharesEndpoint, hasMatchingHeight, isExactlyOneLineAway else {
            return reportedCaretRect
        }
        return CGRect(
            x: reportedCaretRect.minX,
            y: previousCharacterRect.minY,
            width: reportedCaretRect.width,
            height: previousCharacterRect.height
        )
    }

    public static func baselineOffset(
        containerHeight: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat,
        nativeLineHeight: CGFloat? = nil,
        nativeBaselineOffsetFromTop: CGFloat? = nil
    ) -> CGFloat {
        if
            let nativeLineHeight,
            let nativeBaselineOffsetFromTop,
            nativeLineHeight.isFinite,
            nativeLineHeight > 0,
            nativeBaselineOffsetFromTop.isFinite,
            (0 ... nativeLineHeight).contains(nativeBaselineOffsetFromTop)
        {
            let verticalInset = max(
                0,
                containerHeight - nativeLineHeight
            ) / 2
            return verticalInset
                + nativeLineHeight
                - nativeBaselineOffsetFromTop
        }

        let lineHeight = ascent + descent + leading
        let verticalInset = max(0, containerHeight - lineHeight) / 2
        return verticalInset + descent + leading / 2
    }

    public static func prepareLinePlacement(
        caretRect: CGRect,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat,
        nativeLineHeight: CGFloat? = nil,
        nativeBaselineOffsetFromTop: CGFloat? = nil,
        backingScaleFactor: CGFloat
    ) -> PreparedOverlayLinePlacement {
        let height = max(
            ceil(ascent + descent + leading),
            caretRect.height,
            nativeLineHeight ?? 0
        )
        let origin = pixelAlignedOrigin(
            CGPoint(
                x: caretRect.maxX,
                y: caretRect.minY - (height - caretRect.height) / 2
            ),
            backingScaleFactor: backingScaleFactor
        )
        return PreparedOverlayLinePlacement(
            origin: origin,
            height: height,
            baselineOffset: baselineOffset(
                containerHeight: height,
                ascent: ascent,
                descent: descent,
                leading: leading,
                nativeLineHeight: nativeLineHeight,
                nativeBaselineOffsetFromTop:
                    nativeBaselineOffsetFromTop
            )
        )
    }
}
