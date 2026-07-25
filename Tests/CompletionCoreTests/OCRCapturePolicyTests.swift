import CompletionCore
import XCTest

final class OCRCapturePolicyTests: XCTestCase {
    func testFocusAlwaysRefreshesUnlessSameEditorIsAlreadyInFlight() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            OCRCapturePolicy.shouldCapture(
                reason: .focusChanged,
                editorIdentifier: "editor-a",
                cachedEditorIdentifier: "editor-a",
                cachedAt: now,
                inFlightEditorIdentifier: nil,
                now: now
            )
        )
        XCTAssertFalse(
            OCRCapturePolicy.shouldCapture(
                reason: .focusChanged,
                editorIdentifier: "editor-a",
                cachedEditorIdentifier: nil,
                cachedAt: nil,
                inFlightEditorIdentifier: "editor-a",
                now: now
            )
        )
    }

    func testTypingBurstReusesFreshFocusCaptureAndRefreshesStaleCapture() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(
            OCRCapturePolicy.shouldCapture(
                reason: .typingBurstStarted,
                editorIdentifier: "editor-a",
                cachedEditorIdentifier: "editor-a",
                cachedAt: now.addingTimeInterval(-1),
                inFlightEditorIdentifier: nil,
                now: now
            )
        )
        XCTAssertTrue(
            OCRCapturePolicy.shouldCapture(
                reason: .typingBurstStarted,
                editorIdentifier: "editor-a",
                cachedEditorIdentifier: "editor-a",
                cachedAt: now.addingTimeInterval(-3),
                inFlightEditorIdentifier: nil,
                now: now
            )
        )
    }

    func testTypingBurstBoundaryUsesIdleInterval() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            OCRCapturePolicy.beginsTypingBurst(
                previousInsertionAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            OCRCapturePolicy.beginsTypingBurst(
                previousInsertionAt: now.addingTimeInterval(-1),
                now: now
            )
        )
        XCTAssertTrue(
            OCRCapturePolicy.beginsTypingBurst(
                previousInsertionAt: now.addingTimeInterval(-2),
                now: now
            )
        )
    }

    func testWindowSelectionUsesFocusedWindowGeometry() throws {
        let selected = try XCTUnwrap(
            FocusedWindowSelection.select(
                processID: 42,
                caretRect: CGRect(x: 500, y: 200, width: 2, height: 20),
                focusedWindowFrame: CGRect(
                    x: 100,
                    y: 100,
                    width: 800,
                    height: 600
                ),
                candidates: [
                    OCRWindowCandidate(
                        id: 1,
                        processID: 42,
                        frame: CGRect(x: 0, y: 0, width: 1_600, height: 900),
                        isActive: true,
                        layer: 0
                    ),
                    OCRWindowCandidate(
                        id: 2,
                        processID: 42,
                        frame: CGRect(
                            x: 100,
                            y: 100,
                            width: 800,
                            height: 600
                        ),
                        isActive: false,
                        layer: 0
                    ),
                    OCRWindowCandidate(
                        id: 3,
                        processID: 9,
                        frame: CGRect(
                            x: 100,
                            y: 100,
                            width: 800,
                            height: 600
                        ),
                        isActive: true,
                        layer: 0
                    ),
                ]
            )
        )

        XCTAssertEqual(selected.id, 2)
    }

    func testOCRTextDeduplicatesLinesAndDropsExactEditorEcho() {
        XCTAssertEqual(
            OCRContextText.compose(
                recognizedLines: [
                    "Alex: can you look at this tomorrow?",
                    "  Alex:   can you look at this tomorrow? ",
                    "sure, I can check after lunch",
                    "Other visible context",
                ],
                editorText: "sure, I can check after lunch"
            ),
            """
            Alex: can you look at this tomorrow?
            Other visible context
            """
        )
    }
}
