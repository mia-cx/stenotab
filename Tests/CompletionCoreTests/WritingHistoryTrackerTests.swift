import XCTest
@testable import CompletionCore

final class WritingHistoryTrackerTests: XCTestCase {
    func testDirectTypingCoalescesIntoABurstAndFocusChangeFinalizes() throws {
        let start = Date(timeIntervalSince1970: 100)
        let context = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Chat",
            website: "example.com",
            inputKind: "message",
            detectedLanguage: "en",
            editorIdentifier: "editor-1"
        )
        var tracker = WritingHistoryTracker()
        XCTAssertNil(
            tracker.observe(
                field: CapturedFieldState(
                    text: "hel",
                    selection: UTF16Selection(location: 3, length: 0)
                ),
                context: context,
                at: start,
                episodeID: UUID(
                    uuidString: "A4967CA7-A253-4E51-8D8F-2430044C0F7C"
                )!
            )
        )

        tracker.recordInsertion(
            "l",
            provenance: .directlyTyped,
            fieldBefore: CapturedFieldState(
                text: "hel",
                selection: UTF16Selection(location: 3, length: 0)
            ),
            fieldAfter: CapturedFieldState(
                text: "hell",
                selection: UTF16Selection(location: 4, length: 0)
            ),
            at: start.addingTimeInterval(0.1)
        )
        tracker.recordInsertion(
            "o",
            provenance: .directlyTyped,
            fieldBefore: CapturedFieldState(
                text: "hell",
                selection: UTF16Selection(location: 4, length: 0)
            ),
            fieldAfter: CapturedFieldState(
                text: "hello",
                selection: UTF16Selection(location: 5, length: 0)
            ),
            at: start.addingTimeInterval(0.2)
        )

        let completed = try XCTUnwrap(
            tracker.observe(
                field: CapturedFieldState(
                    text: "different",
                    selection: UTF16Selection(location: 9, length: 0)
                ),
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Chat",
                    inputKind: "message",
                    editorIdentifier: "editor-2"
                ),
                at: start.addingTimeInterval(1),
                episodeID: UUID()
            )
        )

        XCTAssertEqual(completed.initialField.text, "hel")
        XCTAssertEqual(completed.finalField.text, "hello")
        XCTAssertEqual(completed.edits.count, 1)
        XCTAssertEqual(completed.edits[0].insertedText, "lo")
        XCTAssertEqual(completed.edits[0].provenance, .directlyTyped)
        XCTAssertEqual(completed.boundary, .focusChanged)
        XCTAssertEqual(completed.context, context)
    }

    func testAcceptedTextIsNotMergedWithDirectTyping() throws {
        let date = Date(timeIntervalSince1970: 200)
        let context = PersonalizationContext(editorIdentifier: "editor")
        var tracker = WritingHistoryTracker()
        _ = tracker.observe(
            field: CapturedFieldState(
                text: "pull req",
                selection: UTF16Selection(location: 8, length: 0)
            ),
            context: context,
            at: date
        )

        tracker.recordInsertion(
            "u",
            provenance: .directlyTyped,
            fieldBefore: CapturedFieldState(
                text: "pull req",
                selection: UTF16Selection(location: 8, length: 0)
            ),
            fieldAfter: CapturedFieldState(
                text: "pull requ",
                selection: UTF16Selection(location: 9, length: 0)
            ),
            at: date.addingTimeInterval(0.1)
        )
        tracker.recordInsertion(
            "est",
            provenance: .acceptedSuggestion,
            fieldBefore: CapturedFieldState(
                text: "pull requ",
                selection: UTF16Selection(location: 9, length: 0)
            ),
            fieldAfter: CapturedFieldState(
                text: "pull request",
                selection: UTF16Selection(location: 12, length: 0)
            ),
            at: date.addingTimeInterval(0.2)
        )

        let completed = try XCTUnwrap(
            tracker.finalize(
                boundary: .submitted,
                at: date.addingTimeInterval(0.3)
            )
        )
        XCTAssertEqual(
            completed.edits.map(\.provenance),
            [.directlyTyped, .acceptedSuggestion]
        )
        XCTAssertEqual(completed.edits.map(\.insertedText), ["u", "est"])
    }

    func testIdleBoundaryPreservesCompleteLongMultilineField() throws {
        let date = Date(timeIntervalSince1970: 300)
        let longPrefix = String(repeating: "complete line\n", count: 120)
        let initial = longPrefix + "tail"
        let final = initial + "!"
        let context = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Editor",
            inputKind: "document",
            editorIdentifier: "long-editor"
        )
        var tracker = WritingHistoryTracker()
        _ = tracker.observe(
            field: CapturedFieldState(
                text: initial,
                selection: UTF16Selection(
                    location: initial.utf16.count,
                    length: 0
                )
            ),
            context: context,
            at: date
        )
        tracker.recordInsertion(
            "!",
            provenance: .directlyTyped,
            fieldBefore: CapturedFieldState(
                text: initial,
                selection: UTF16Selection(
                    location: initial.utf16.count,
                    length: 0
                )
            ),
            fieldAfter: CapturedFieldState(
                text: final,
                selection: UTF16Selection(
                    location: final.utf16.count,
                    length: 0
                )
            ),
            at: date.addingTimeInterval(0.1)
        )

        XCTAssertNil(
            tracker.finalizeIfIdle(
                at: date.addingTimeInterval(1),
                timeout: 2
            )
        )
        let completed = try XCTUnwrap(
            tracker.finalizeIfIdle(
                at: date.addingTimeInterval(3),
                timeout: 2
            )
        )
        XCTAssertEqual(completed.initialField.text, initial)
        XCTAssertEqual(completed.finalField.text, final)
        XCTAssertEqual(completed.boundary, .idle)
    }

    func testDeletionOnlyEpisodeRetainsDeletedText() throws {
        let date = Date(timeIntervalSince1970: 400)
        let context = PersonalizationContext(editorIdentifier: "editor")
        var tracker = WritingHistoryTracker()
        _ = tracker.observe(
            field: CapturedFieldState(
                text: "Anythiings",
                selection: UTF16Selection(location: 10, length: 0)
            ),
            context: context,
            at: date
        )
        tracker.recordDeletion(
            "i",
            fieldBefore: CapturedFieldState(
                text: "Anythiings",
                selection: UTF16Selection(location: 7, length: 0)
            ),
            fieldAfter: CapturedFieldState(
                text: "Anytings",
                selection: UTF16Selection(location: 6, length: 0)
            ),
            at: date.addingTimeInterval(0.1)
        )

        let episode = try XCTUnwrap(
            tracker.finalize(
                boundary: .idle,
                at: date.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(episode.edits.count, 1)
        XCTAssertEqual(episode.edits[0].insertedText, "")
        XCTAssertEqual(episode.edits[0].deletedText, "i")
    }
}
