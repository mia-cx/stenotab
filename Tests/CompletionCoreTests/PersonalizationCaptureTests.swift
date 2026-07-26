import CompletionCore
import XCTest

final class PersonalizationCaptureTests: XCTestCase {
    func testCapturedFieldReplacesUTF16Selection() {
        let field = CapturedFieldState(
            text: "hello 🌍 world",
            selection: UTF16Selection(location: 6, length: 2)
        )

        XCTAssertEqual(
            field.replacingSelection(with: "beautiful"),
            "hello beautiful world"
        )
    }

    private struct LegacyAcceptedSuggestionCapture: Codable {
        let id: UUID
        let field: CapturedFieldState
        let insertion: String
        let acceptanceScope: SuggestionAcceptance.Scope
        let context: PersonalizationContext
        let capturedAt: Date
    }

    func testAcceptedSuggestionPreservesCanonicalFieldAndLiteralInsertion() {
        let completionEpisodeID = UUID(
            uuidString: "783C7828-C2BA-44B4-8AEF-249829420EB6"
        )!
        let capture = PersonalizationCapture.acceptedSuggestion(
            fieldText: "A long field before the cursor and after it",
            selection: UTF16Selection(location: 30, length: 4),
            insertion: " exact words ",
            acceptanceScope: .nextWord,
            completionEpisodeID: completionEpisodeID,
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
        XCTAssertEqual(capture?.completionEpisodeID, completionEpisodeID)
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

    func testAcceptedSuggestionDecodesEventsFromBeforeEpisodeLinkage() throws {
        let legacyCapture = LegacyAcceptedSuggestionCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "legacy input",
                selection: UTF16Selection(location: 12, length: 0)
            ),
            insertion: " continued",
            acceptanceScope: .entireSuggestion,
            context: PersonalizationContext(
                applicationBundleIdentifier: "com.example.Editor",
                editorIdentifier: "legacy-editor"
            ),
            capturedAt: Date(timeIntervalSince1970: 456)
        )

        let encoded = try JSONEncoder().encode(legacyCapture)
        let decoded = try JSONDecoder().decode(
            AcceptedSuggestionCapture.self,
            from: encoded
        )

        XCTAssertEqual(decoded.id, legacyCapture.id)
        XCTAssertEqual(decoded.insertion, " continued")
        XCTAssertNil(decoded.completionEpisodeID)
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

    func testSelectionRejectsUTF16OffsetsInsideSurrogatePairs() {
        let text = "😀"

        XCTAssertFalse(
            UTF16Selection(location: 1, length: 0).isValid(for: text)
        )
        XCTAssertFalse(
            UTF16Selection(location: 0, length: 1).isValid(for: text)
        )
        XCTAssertTrue(
            UTF16Selection(location: 0, length: 2).isValid(for: text)
        )
        XCTAssertTrue(
            UTF16Selection(location: 2, length: 0).isValid(for: text)
        )
    }
}
