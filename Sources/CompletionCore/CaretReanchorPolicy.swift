import CoreGraphics

public enum CaretReanchorPolicy {
    public static func isReady(
        previousPrefix: String,
        expectedPrefix: String,
        observedPrefix: String,
        previousCaretRect: CGRect?,
        observedCaretRect: CGRect
    ) -> Bool {
        guard observedPrefix == expectedPrefix else { return false }
        guard expectedPrefix != previousPrefix else { return true }
        guard
            let previousCaretRect,
            OverlayGeometry.isUsableCaretRect(previousCaretRect),
            OverlayGeometry.isUsableCaretRect(observedCaretRect)
        else {
            return true
        }

        let movementTolerance: CGFloat = 0.5
        return abs(observedCaretRect.minX - previousCaretRect.minX)
                >= movementTolerance
            || abs(observedCaretRect.minY - previousCaretRect.minY)
                >= movementTolerance
    }
}
