import XCTest
@testable import CompletionCore

final class CompletionFeedbackTrackerTests: XCTestCase {
    func testImmediateBackspacesProduceOneExactReversionSignal() throws {
        let date = Date(timeIntervalSince1970: 500)
        let acceptance = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: UUID(
                    uuidString: "2C787A1C-D373-42CB-9935-5F84DC320517"
                )!,
                fieldText: "pull req",
                selection: UTF16Selection(location: 8, length: 0),
                insertion: "uest",
                acceptanceScope: .nextWord,
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Editor",
                    editorIdentifier: "editor"
                ),
                capturedAt: date
            )
        )
        var tracker = CompletionReversionTracker(timeout: 5)
        tracker.register(acceptance)

        var text = "pull request"
        for offset in 1...3 {
            let before = CapturedFieldState(
                text: text,
                selection: UTF16Selection(
                    location: text.utf16.count,
                    length: 0
                )
            )
            text.removeLast()
            let feedback = tracker.recordBackwardDeletion(
                fieldBefore: before,
                at: date.addingTimeInterval(Double(offset))
            )
            XCTAssertNil(feedback)
        }

        let beforeLast = CapturedFieldState(
            text: text,
            selection: UTF16Selection(
                location: text.utf16.count,
                length: 0
            )
        )
        text.removeLast()
        let feedback = try XCTUnwrap(
            tracker.recordBackwardDeletion(
                fieldBefore: beforeLast,
                at: date.addingTimeInterval(4)
            )
        )

        XCTAssertEqual(feedback.kind, .reverted)
        XCTAssertEqual(feedback.suggestionText, "uest")
        XCTAssertEqual(feedback.affectedText, "uest")
        XCTAssertEqual(feedback.acceptanceID, acceptance.id)
        XCTAssertEqual(feedback.context, acceptance.context)
    }

    func testLateOrUnrelatedDeletionDoesNotCountAsReversion() throws {
        let date = Date(timeIntervalSince1970: 600)
        let acceptance = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                fieldText: "hi",
                selection: UTF16Selection(location: 2, length: 0),
                insertion: " there",
                acceptanceScope: .entireSuggestion,
                context: PersonalizationContext(editorIdentifier: "editor"),
                capturedAt: date
            )
        )
        var tracker = CompletionReversionTracker(timeout: 2)
        tracker.register(acceptance)

        XCTAssertNil(
            tracker.recordBackwardDeletion(
                fieldBefore: CapturedFieldState(
                    text: "hi there",
                    selection: UTF16Selection(location: 8, length: 0)
                ),
                at: date.addingTimeInterval(3)
            )
        )
    }

    func testTypedMatchSignalPreservesSuggestionAndFullField() throws {
        let capture = try XCTUnwrap(
            PersonalizationCapture.typedSuggestionMatch(
                fieldText: "can you open a pull req",
                selection: UTF16Selection(location: 23, length: 0),
                suggestionText: "uest for this",
                context: PersonalizationContext(
                    inputKind: "message",
                    editorIdentifier: "editor"
                ),
                capturedAt: Date(timeIntervalSince1970: 700)
            )
        )

        XCTAssertEqual(capture.kind, .typedSuggestionMatch)
        XCTAssertEqual(capture.suggestionText, "uest for this")
        XCTAssertEqual(
            capture.field.text,
            "can you open a pull req"
        )
    }
}
