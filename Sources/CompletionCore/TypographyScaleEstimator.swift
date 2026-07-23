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

public struct TypographyScaleCalibration: Sendable, Equatable {
    public private(set) var scale: Double = 1
    public private(set) var referenceCaretHeight: Double?

    public init() {}

    @discardableResult
    public mutating func consider(
        candidateScale: Double,
        caretHeight: Double,
        sampleLength: Int
    ) -> Bool {
        guard
            candidateScale.isFinite,
            candidateScale > 0,
            caretHeight > 0,
            sampleLength >= 3
        else {
            return false
        }

        if let referenceCaretHeight {
            let relativeHeightChange = abs(
                caretHeight - referenceCaretHeight
            ) / max(referenceCaretHeight, 1)
            guard relativeHeightChange >= 0.12 else {
                return false
            }
        }

        scale = candidateScale
        referenceCaretHeight = caretHeight
        return true
    }
}
