import CoreGraphics
import Foundation

public enum OCRCapturePolicy {
    public static func shouldCaptureFocusedEditor(
        editorIdentifier: String,
        lastFocusedEditorIdentifier: String?,
        inFlightEditorIdentifier: String?
    ) -> Bool {
        lastFocusedEditorIdentifier != editorIdentifier
            && inFlightEditorIdentifier != editorIdentifier
    }
}

public struct OCRWindowCandidate: Equatable, Sendable {
    public let id: UInt32
    public let processID: Int32
    public let frame: CGRect
    public let isActive: Bool
    public let layer: Int

    public init(
        id: UInt32,
        processID: Int32,
        frame: CGRect,
        isActive: Bool,
        layer: Int
    ) {
        self.id = id
        self.processID = processID
        self.frame = frame
        self.isActive = isActive
        self.layer = layer
    }
}

public enum FocusedWindowSelection {
    public static func select(
        processID: Int32,
        caretRect: CGRect,
        focusedWindowFrame: CGRect?,
        candidates: [OCRWindowCandidate]
    ) -> OCRWindowCandidate? {
        candidates
            .filter {
                $0.processID == processID
                    && $0.layer == 0
                    && !$0.frame.isEmpty
            }
            .max { score(
                $0,
                caretRect: caretRect,
                focusedWindowFrame: focusedWindowFrame
            ) < score(
                $1,
                caretRect: caretRect,
                focusedWindowFrame: focusedWindowFrame
            ) }
    }

    private static func score(
        _ candidate: OCRWindowCandidate,
        caretRect: CGRect,
        focusedWindowFrame: CGRect?
    ) -> Double {
        var result: Double = candidate.isActive ? 100 : 0
        if candidate.frame.contains(
            CGPoint(x: caretRect.midX, y: caretRect.midY)
        ) {
            result += 1_000
        }
        if let focusedWindowFrame, !focusedWindowFrame.isEmpty {
            result += 10_000 * intersectionOverUnion(
                candidate.frame,
                focusedWindowFrame
            )
        }
        // Prefer the tighter containing window when every other signal ties.
        result -= min(
            Double(candidate.frame.width * candidate.frame.height)
                / 100_000_000,
            1
        )
        return result
    }

    private static func intersectionOverUnion(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height
            + rhs.width * rhs.height
            - intersectionArea
        guard unionArea > 0 else { return 0 }
        return Double(intersectionArea / unionArea)
    }
}

public enum OCRContextText {
    public static func compose(
        recognizedLines: [String],
        editorText: String,
        characterLimit: Int = 6_000
    ) -> String? {
        guard characterLimit > 0 else { return nil }
        let normalizedEditorText = normalizedForComparison(editorText)
        let normalizedEditorLines = editorText
            .split(whereSeparator: \.isNewline)
            .map { normalizedForComparison(String($0)) }
            .filter { $0.count >= 3 }
        var seen = Set<String>()
        var kept: [String] = []
        var usedCharacters = 0

        for rawLine in recognizedLines {
            let line = rawLine
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let comparison = normalizedForComparison(line)
            guard seen.insert(comparison).inserted else { continue }
            let echoesEditorText = comparison.count >= 3
                && (
                    normalizedEditorText.contains(comparison)
                        || normalizedEditorLines.contains(where: {
                            comparison.contains($0)
                        })
                )
            if echoesEditorText {
                continue
            }

            let separatorCount = kept.isEmpty ? 0 : 1
            let remaining = characterLimit - usedCharacters - separatorCount
            guard remaining > 0 else { break }
            let boundedLine = String(line.prefix(remaining))
            kept.append(boundedLine)
            usedCharacters += separatorCount + boundedLine.count
            if boundedLine.count < line.count {
                break
            }
        }

        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: "\n")
    }

    private static func normalizedForComparison(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
