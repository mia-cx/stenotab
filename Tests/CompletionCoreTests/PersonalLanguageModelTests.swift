import XCTest
@testable import CompletionCore

final class PersonalLanguageModelTests: XCTestCase {
    func testLearnsPartialWordAndPhraseFromRepeatedPersonalText() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        var model = PersonalLanguageModel()
        for offset in 0..<3 {
            model.learn(
                insertedText: "pull request for this",
                precedingText: "can you open a ",
                signal: .directlyTyped,
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Chat",
                    inputKind: "message",
                    editorIdentifier: "editor"
                ),
                at: date.addingTimeInterval(Double(offset))
            )
        }

        let completion = try XCTUnwrap(
            model.completion(
                for: "can you open a pull req",
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Chat",
                    inputKind: "message",
                    editorIdentifier: "editor"
                ),
                at: date.addingTimeInterval(10)
            )
        )

        XCTAssertEqual(completion.insertion, "uest for this")
        XCTAssertGreaterThanOrEqual(completion.confidence, 0.7)
        XCTAssertEqual(completion.source, .personalLanguageModel)
    }

    func testLearnsPreferredCapitalization() throws {
        var model = PersonalLanguageModel()
        for offset in 0..<3 {
            model.learn(
                insertedText: "StenoTab",
                precedingText: "open ",
                signal: .directlyTyped,
                context: PersonalizationContext(editorIdentifier: "editor"),
                at: Date(timeIntervalSince1970: Double(offset))
            )
        }

        let completion = try XCTUnwrap(
            model.completion(
                for: "open steno",
                context: PersonalizationContext(editorIdentifier: "editor"),
                at: Date(timeIntervalSince1970: 5)
            )
        )
        XCTAssertEqual(completion.insertion, "Tab")
    }

    func testApplicationScopeBreaksOtherwiseEqualTie() throws {
        let date = Date(timeIntervalSince1970: 2_000)
        var model = PersonalLanguageModel()
        for _ in 0..<3 {
            model.learn(
                insertedText: "request",
                precedingText: "pull ",
                signal: .directlyTyped,
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Work",
                    editorIdentifier: "work"
                ),
                at: date
            )
            model.learn(
                insertedText: "requests",
                precedingText: "pull ",
                signal: .directlyTyped,
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Chat",
                    editorIdentifier: "chat"
                ),
                at: date
            )
        }

        let completion = try XCTUnwrap(
            model.completion(
                for: "pull req",
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Work",
                    editorIdentifier: "work"
                ),
                at: date
            )
        )
        XCTAssertEqual(completion.insertion, "uest")
    }

    func testReversionDemotesAnOtherwiseLearnedCandidate() {
        let date = Date(timeIntervalSince1970: 3_000)
        var model = PersonalLanguageModel()
        for _ in 0..<2 {
            model.learn(
                insertedText: "anything",
                precedingText: "do ",
                signal: .acceptedSuggestion,
                context: PersonalizationContext(editorIdentifier: "editor"),
                at: date
            )
        }
        for _ in 0..<2 {
            model.learn(
                insertedText: "anything",
                precedingText: "do ",
                signal: .revertedSuggestion,
                context: PersonalizationContext(editorIdentifier: "editor"),
                at: date
            )
        }

        XCTAssertNil(
            model.completion(
                for: "do anyt",
                context: PersonalizationContext(editorIdentifier: "editor"),
                at: date
            )
        )
    }

    func testSingleUnconfirmedWordDoesNotBecomeACompletion() {
        var model = PersonalLanguageModel()
        model.learn(
            insertedText: "oneoffname",
            precedingText: "hi ",
            signal: .directlyTyped,
            context: PersonalizationContext(editorIdentifier: "editor")
        )

        XCTAssertNil(
            model.completion(
                for: "hi one",
                context: PersonalizationContext(editorIdentifier: "editor")
            )
        )
    }
}
