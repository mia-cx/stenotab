import CompletionCore
import XCTest

final class PersonalizationCaptureTests: XCTestCase {
    func testAcceptedSuggestionPreservesCanonicalFieldAndLiteralInsertion() {
        let capture = PersonalizationCapture.acceptedSuggestion(
            fieldText: "A long field before the cursor and after it",
            selection: UTF16Selection(location: 30, length: 4),
            insertion: " exact words ",
            acceptanceScope: .nextWord,
            context: PersonalizationContext(
                applicationBundleIdentifier: "com.example.Editor",
                website: "example.com",
                inputKind: "comment",
                editorIdentifier: "editor-1"
            ),
            capturedAt: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(
            capture?.field.text,
            "A long field before the cursor and after it"
        )
        XCTAssertEqual(capture?.field.selection.location, 30)
        XCTAssertEqual(capture?.field.selection.length, 4)
        XCTAssertEqual(capture?.insertion, " exact words ")
        XCTAssertEqual(capture?.acceptanceScope, .nextWord)
        XCTAssertEqual(capture?.context.website, "example.com")
        XCTAssertEqual(capture?.capturedAt, Date(timeIntervalSince1970: 123))
    }

    func testAcceptedSuggestionRejectsEmptyOrInvalidCaptures() {
        let context = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Editor",
            editorIdentifier: "editor-1"
        )

        XCTAssertNil(
            PersonalizationCapture.acceptedSuggestion(
                fieldText: "hello",
                selection: UTF16Selection(location: 5, length: 0),
                insertion: "",
                acceptanceScope: .entireSuggestion,
                context: context
            )
        )
        XCTAssertNil(
            PersonalizationCapture.acceptedSuggestion(
                fieldText: "hello",
                selection: UTF16Selection(location: 6, length: 0),
                insertion: " world",
                acceptanceScope: .entireSuggestion,
                context: context
            )
        )
        XCTAssertNil(
            PersonalizationCapture.acceptedSuggestion(
                fieldText: "hello",
                selection: UTF16Selection(location: 4, length: 2),
                insertion: " world",
                acceptanceScope: .entireSuggestion,
                context: context
            )
        )
    }

    func testDeletionSelectionPreservesWholeExtendedGraphemeClusters() {
        let text = "A👨‍👩‍👧‍👦B"
        let familyLength = "👨‍👩‍👧‍👦".utf16.count
        let afterFamily = UTF16Selection(
            location: 1 + familyLength,
            length: 0
        )
        let beforeFamily = UTF16Selection(location: 1, length: 0)

        XCTAssertEqual(
            afterFamily.selectionForDeletion(
                in: text,
                direction: .backward
            ),
            UTF16Selection(location: 1, length: familyLength)
        )
        XCTAssertEqual(
            beforeFamily.selectionForDeletion(
                in: text,
                direction: .forward
            ),
            UTF16Selection(location: 1, length: familyLength)
        )
    }
}
