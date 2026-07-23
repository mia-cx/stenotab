public struct EditorTypography: Sendable, Equatable {
    public let fontName: String?
    public let pointSize: Double

    public init(
        reportedFontName: String?,
        reportedPointSize: Double?,
        caretHeight: Double,
        reconcileReportedSizeWithCaret: Bool = false
    ) {
        if let reportedFontName, !reportedFontName.isEmpty {
            fontName = reportedFontName
        } else {
            fontName = nil
        }

        if let reportedPointSize, reportedPointSize > 0 {
            let caretInferredSize = caretHeight * 0.65
            let reportedLooksUnscaled = reconcileReportedSizeWithCaret
                && caretInferredSize >= reportedPointSize * 1.15
            let resolvedSize = reportedLooksUnscaled
                ? caretInferredSize
                : reportedPointSize
            pointSize = min(max(resolvedSize, 10), 72)
        } else {
            let multiplier = reconcileReportedSizeWithCaret ? 0.65 : 0.8
            let inferredSize = caretHeight > 0
                ? caretHeight * multiplier
                : 13
            pointSize = min(max(inferredSize, 10), 72)
        }
    }
}
