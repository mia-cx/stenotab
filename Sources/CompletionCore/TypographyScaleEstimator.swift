public enum TypographyScaleEstimator {
    public static func estimate(
        previousPrefix: String,
        currentPrefix: String,
        previousCaretX: Double,
        currentCaretX: Double,
        previousCaretY: Double,
        currentCaretY: Double,
        lineHeight: Double,
        expectedAdvance: Double
    ) -> Double? {
        guard
            currentPrefix.hasPrefix(previousPrefix),
            currentPrefix.count > previousPrefix.count
        else {
            return nil
        }

        let inserted = currentPrefix.dropFirst(previousPrefix.count)
        guard
            !inserted.contains(where: { $0 == "\n" || $0 == "\r" }),
            abs(currentCaretY - previousCaretY) <= max(2, lineHeight * 0.35),
            expectedAdvance > 1
        else {
            return nil
        }

        let observedAdvance = currentCaretX - previousCaretX
        guard observedAdvance > 1 else { return nil }

        let scale = observedAdvance / expectedAdvance
        guard (0.8 ... 1.35).contains(scale) else { return nil }
        return scale
    }
}
