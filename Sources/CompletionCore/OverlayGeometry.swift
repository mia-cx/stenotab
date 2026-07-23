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

    public static func baselineOffset(
        containerHeight: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat
    ) -> CGFloat {
        let lineHeight = ascent + descent + leading
        let verticalInset = max(0, containerHeight - lineHeight) / 2
        return verticalInset + descent + leading / 2
    }

    public static func prepareLinePlacement(
        caretRect: CGRect,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat,
        backingScaleFactor: CGFloat
    ) -> PreparedOverlayLinePlacement {
        let height = max(
            ceil(ascent + descent + leading),
            caretRect.height
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
                leading: leading
            )
        )
    }
}
