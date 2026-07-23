public enum LeadingWhitespaceCompensation {
    /// A cold-start estimate for Chromium-backed editors, which expose caret
    /// geometry but commonly omit the actual web font. Runtime calibration
    /// should replace this as soon as an accepted suggestion supplies a real
    /// caret advance.
    public static func points(
        for suggestion: String,
        caretHeight: Double,
        isWebBacked: Bool
    ) -> Double {
        guard isWebBacked, caretHeight > 0 else { return 0 }

        let leadingSpaceCount = suggestion.prefix { $0 == " " }.count
        guard leadingSpaceCount > 0 else { return 0 }

        return caretHeight * 0.125 * Double(leadingSpaceCount)
    }
}

public struct LeadingWhitespaceCalibration: Sendable, Equatable {
    private var correctionPerCaretHeight: Double?

    public init() {}

    public func points(
        for suggestion: String,
        caretHeight: Double,
        isWebBacked: Bool
    ) -> Double {
        let leadingSpaceCount = suggestion.prefix { $0 == " " }.count
        guard
            isWebBacked,
            caretHeight > 0,
            leadingSpaceCount > 0
        else {
            return 0
        }

        if let correctionPerCaretHeight {
            return correctionPerCaretHeight
                * caretHeight
                * Double(leadingSpaceCount)
        }
        return LeadingWhitespaceCompensation.points(
            for: suggestion,
            caretHeight: caretHeight,
            isWebBacked: isWebBacked
        )
    }

    @discardableResult
    public mutating func consider(
        observedAdvance: Double,
        renderedAdvance: Double,
        caretHeight: Double,
        leadingSpaceCount: Int
    ) -> Bool {
        guard
            observedAdvance.isFinite,
            renderedAdvance.isFinite,
            caretHeight > 0,
            leadingSpaceCount > 0
        else {
            return false
        }

        let correction = observedAdvance - renderedAdvance
        let ratio = correction
            / (caretHeight * Double(leadingSpaceCount))
        guard (-0.25 ... 0.35).contains(ratio) else { return false }

        correctionPerCaretHeight = ratio
        return true
    }
}
