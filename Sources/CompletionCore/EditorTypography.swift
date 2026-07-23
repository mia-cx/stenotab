public struct EditorTypography: Sendable, Equatable {
    public let fontName: String?
    public let pointSize: Double

    public init(
        reportedFontName: String?,
        reportedPointSize: Double?,
        caretHeight: Double
    ) {
        if let reportedFontName, !reportedFontName.isEmpty {
            fontName = reportedFontName
        } else {
            fontName = nil
        }

        if let reportedPointSize, reportedPointSize > 0 {
            pointSize = reportedPointSize
        } else {
            let inferredSize = caretHeight > 0 ? caretHeight * 0.8 : 13
            pointSize = min(max(inferredSize, 10), 72)
        }
    }
}
