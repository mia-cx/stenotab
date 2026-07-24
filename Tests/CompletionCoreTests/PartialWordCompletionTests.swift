import CompletionCore
import XCTest

final class PartialWordCompletionTests: XCTestCase {
    func testExtractsOnlyAnAlphabeticWordAtTheCaret() {
        XCTAssertEqual(
            PartialWordCompletion.fragment(in: "Do anythi"),
            "anythi"
        )
        XCTAssertEqual(
            PartialWordCompletion.fragment(in: "actually ty"),
            "ty"
        )
        XCTAssertNil(PartialWordCompletion.fragment(in: "anything "))
        XCTAssertNil(PartialWordCompletion.fragment(in: "@mia"))
        XCTAssertNil(PartialWordCompletion.fragment(in: "x"))
    }

    func testSanitizesFewShotOutputToOnlyTheMissingLetters() {
        let fixtures = [
            ("anyt", " hing\n\nText: something", "hing"),
            ("anyth", " ing", "ing"),
            ("anythi", " ng", "ng"),
            ("anythin", " g", "g"),
        ]

        for (fragment, raw, expected) in fixtures {
            XCTAssertEqual(
                PartialWordCompletion.sanitize(
                    raw,
                    after: fragment,
                    candidates: ["anything"]
                ),
                expected
            )
            XCTAssertEqual(fragment + expected, "anything")
        }
    }

    func testRejectsScaffoldingAndRepeatedFragments() {
        XCTAssertNil(
            PartialWordCompletion.sanitize(
                " Continuation: ing",
                after: "anyth",
                candidates: ["anything"]
            )
        )
        XCTAssertNil(
            PartialWordCompletion.sanitize(
                " anyth",
                after: "anyth",
                candidates: ["anything"]
            )
        )
    }

    func testRepairsInvalidAndRepeatedModelSuffixesUsingDictionaryCandidates() {
        XCTAssertEqual(
            PartialWordCompletion.sanitize(
                " ing",
                after: "anyt",
                candidates: ["anything", "anytime"]
            ),
            "hing"
        )
        XCTAssertEqual(
            PartialWordCompletion.sanitize(
                " inginginginginging",
                after: "anyt",
                candidates: ["anything", "anytime"]
            ),
            "hing"
        )
    }

    func testNeverReturnsACombinedWordOutsideTheCandidateSet() {
        XCTAssertNil(
            PartialWordCompletion.sanitize(
                " xyz",
                after: "anyt",
                candidates: []
            )
        )
    }
}
