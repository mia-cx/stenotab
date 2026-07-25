import CompletionCore
import XCTest

final class OCRCapturePolicyTests: XCTestCase {
    func testCapturesOnlyWhenADifferentEditorReceivesFocus() {
        XCTAssertTrue(
            OCRCapturePolicy.shouldCaptureFocusedEditor(
                editorIdentifier: "editor-a",
                lastFocusedEditorIdentifier: nil,
                inFlightEditorIdentifier: nil
            )
        )
        XCTAssertFalse(
            OCRCapturePolicy.shouldCaptureFocusedEditor(
                editorIdentifier: "editor-a",
                lastFocusedEditorIdentifier: "editor-a",
                inFlightEditorIdentifier: nil
            )
        )
        XCTAssertFalse(
            OCRCapturePolicy.shouldCaptureFocusedEditor(
                editorIdentifier: "editor-a",
                lastFocusedEditorIdentifier: nil,
                inFlightEditorIdentifier: "editor-a"
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

    func testOCRTextDropsWrappedAndPartialEditorEchoes() {
        XCTAssertEqual(
            OCRContextText.compose(
                recognizedLines: [
                    "Alex: what changed in the latest build?",
                    "I think the prompt is",
                    "still repeating my input",
                    "repeating my input",
                    "Other visible context",
                ],
                editorText:
                    "I think the prompt is\nstill repeating my input"
            ),
            """
            Alex: what changed in the latest build?
            Other visible context
            """
        )
    }
}
