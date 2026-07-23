import CoreGraphics

public enum OverlayGeometry {
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
}
