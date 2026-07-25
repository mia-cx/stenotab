import AppKit
import CompletionCore
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision

struct OCRCaptureTarget: Sendable {
    let editorIdentifier: String
    let processID: pid_t
    let caretRect: CGRect
    let focusedWindowFrame: CGRect?
    let editorText: String
}

enum ScreenOCRCaptureError: LocalizedError {
    case focusedWindowUnavailable
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .focusedWindowUnavailable:
            "The focused app window is not available for capture."
        case .imageUnavailable:
            "ScreenCaptureKit returned no image."
        }
    }
}

final class ScreenOCRContextCapture: Sendable {
    private struct DisplayMapping: Sendable {
        let displayBounds: CGRect
        let cocoaFrame: CGRect
    }

    private struct SendableImage: @unchecked Sendable {
        let value: CGImage
    }

    func recognizeText(for target: OCRCaptureTarget) async throws -> String? {
        try Task.checkCancellation()
        let content = try await shareableContent()
        try Task.checkCancellation()
        let mappings = await MainActor.run {
            Self.currentDisplayMappings()
        }
        let candidates = content.windows.map { window in
            OCRWindowCandidate(
                id: window.windowID,
                processID: window.owningApplication?.processID ?? -1,
                frame: Self.cocoaRect(
                    fromScreenCaptureRect: window.frame,
                    mappings: mappings
                ),
                isActive: window.isActive,
                layer: window.windowLayer
            )
        }
        guard
            let selected = FocusedWindowSelection.select(
                processID: target.processID,
                caretRect: target.caretRect,
                focusedWindowFrame: target.focusedWindowFrame,
                candidates: candidates
            ),
            let window = content.windows.first(where: {
                $0.windowID == selected.id
            })
        else {
            throw ScreenOCRCaptureError.focusedWindowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = Self.configuration(
            for: window,
            filter: filter
        )
        let image = try await captureImage(
            filter: filter,
            configuration: configuration
        )
        try Task.checkCancellation()
        let sendableImage = SendableImage(value: image)
        let lines = try await Task.detached(priority: .userInitiated) {
            try Self.recognizedLines(in: sendableImage.value)
        }.value
        try Task.checkCancellation()
        return OCRContextText.compose(
            recognizedLines: lines,
            editorText: target.editorText
        )
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(
                        throwing:
                            ScreenOCRCaptureError.focusedWindowUnavailable
                    )
                }
            }
        }
    }

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: ScreenOCRCaptureError.imageUnavailable
                    )
                }
            }
        }
    }

    private static func configuration(
        for window: SCWindow,
        filter: SCContentFilter
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let nativeScale = max(CGFloat(filter.pointPixelScale), 1)
        let nativeWidth = max(window.frame.width * nativeScale, 1)
        let nativeHeight = max(window.frame.height * nativeScale, 1)
        let maximumDimension: CGFloat = 2_560
        let downscale = min(
            1,
            maximumDimension / max(nativeWidth, nativeHeight)
        )
        configuration.width = Int(nativeWidth * downscale)
        configuration.height = Int(nativeHeight * downscale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    private static func recognizedLines(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.006

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap { observation -> (String, CGRect)? in
                guard let text = observation.topCandidates(1).first?.string
                else {
                    return nil
                }
                return (text, observation.boundingBox)
            }
            .sorted { lhs, rhs in
                let lineTolerance: CGFloat = 0.012
                if abs(lhs.1.midY - rhs.1.midY) > lineTolerance {
                    return lhs.1.midY > rhs.1.midY
                }
                return lhs.1.minX < rhs.1.minX
            }
            .map(\.0)
    }

    @MainActor
    private static func currentDisplayMappings() -> [DisplayMapping] {
        NSScreen.screens.compactMap { screen in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                return nil
            }
            return DisplayMapping(
                displayBounds: CGDisplayBounds(
                    CGDirectDisplayID(number.uint32Value)
                ),
                cocoaFrame: screen.frame
            )
        }
    }

    private static func cocoaRect(
        fromScreenCaptureRect rect: CGRect,
        mappings: [DisplayMapping]
    ) -> CGRect {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)
        guard
            let mapping = mappings.first(where: {
                $0.displayBounds.contains(midpoint)
                    || $0.displayBounds.intersects(rect)
            })
        else {
            return rect
        }
        return CGRect(
            x: mapping.cocoaFrame.minX
                + rect.minX
                - mapping.displayBounds.minX,
            y: mapping.cocoaFrame.maxY
                - (rect.minY - mapping.displayBounds.minY)
                - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
