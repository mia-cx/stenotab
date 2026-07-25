import XCTest
@testable import CompletionCore

final class PersonalLanguageModelTests: XCTestCase {
    func testLegacyProjectionWithoutVersionRequiresRebuild() throws {
        let current = PersonalLanguageModel()
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "projectionVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            PersonalLanguageModel.self,
            from: legacyData
        )

        XCTAssertTrue(decoded.requiresRebuild)
        XCTAssertFalse(current.requiresRebuild)
    }

    func testOlderProjectionVersionRequiresRebuild() throws {
        let current = PersonalLanguageModel()
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object["projectionVersion"] = 4
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            PersonalLanguageModel.self,
            from: legacyData
        )

        XCTAssertTrue(decoded.requiresRebuild)
    }

    func testWritingEpisodeLearnsAffectedFullWordInsteadOfTypedFragment() {
        let date = Date(timeIntervalSince1970: 50)
        let initialText = "some validation from m"
        let finalText = "some validation from me"
        let context = PersonalizationContext(editorIdentifier: "editor")
        let episode = WritingEpisodeCapture(
            id: UUID(),
            initialField: CapturedFieldState(
                text: initialText,
                selection: UTF16Selection(
                    location: initialText.utf16.count,
                    length: 0
                )
            ),
            finalField: CapturedFieldState(
                text: finalText,
                selection: UTF16Selection(
                    location: finalText.utf16.count,
                    length: 0
                )
            ),
            edits: [
                WritingEditCapture(
                    insertedText: "e",
                    provenance: .directlyTyped,
                    selectionBefore: UTF16Selection(
                        location: initialText.utf16.count,
                        length: 0
                    ),
                    selectionAfter: UTF16Selection(
                        location: finalText.utf16.count,
                        length: 0
                    ),
                    fieldBefore: CapturedFieldState(
                        text: initialText,
                        selection: UTF16Selection(
                            location: initialText.utf16.count,
                            length: 0
                        )
                    ),
                    startedAt: date,
                    endedAt: date
                )
            ],
            context: context,
            startedAt: date,
            endedAt: date,
            boundary: .submitted
        )

        var model = PersonalLanguageModel()
        model.ingest(episode)

        let entries = model.vocabularyEntries()
        XCTAssertEqual(entries.map(\.normalized), ["me"])
        XCTAssertFalse(entries.contains { $0.normalized == "e" })
    }

    func testAcceptedPartialWordLearnsCompletedEditorWord() throws {
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                fieldText: "Do anyt",
                selection: UTF16Selection(location: 7, length: 0),
                insertion: "hing",
                acceptanceScope: .nextWord,
                context: PersonalizationContext(
                    editorIdentifier: "editor"
                ),
                capturedAt: Date(timeIntervalSince1970: 75)
            )
        )

        var model = PersonalLanguageModel()
        model.ingest(capture)

        let entries = model.vocabularyEntries()
        XCTAssertEqual(entries.map(\.normalized), ["anything"])
        XCTAssertFalse(entries.contains { $0.normalized == "hing" })
    }

    func testAcceptedDelimiterOnlyCompletionBecomesLearnedEvidence() throws {
        let context = PersonalizationContext(editorIdentifier: "editor")
        var model = PersonalLanguageModel()
        for offset in 0..<2 {
            let capture = try XCTUnwrap(
                PersonalizationCapture.acceptedSuggestion(
                    fieldText: "hello",
                    selection: UTF16Selection(location: 5, length: 0),
                    insertion: "!",
                    acceptanceScope: .entireSuggestion,
                    context: context,
                    capturedAt: Date(
                        timeIntervalSince1970: Double(75 + offset)
                    )
                )
            )
            model.ingest(capture)
        }

        XCTAssertEqual(
            model.completion(for: "hello", context: context)?.insertion,
            "!"
        )
    }

    func testMixedEpisodeLearnsOnlyDirectlyTypedEdits() {
        let date = Date(timeIntervalSince1970: 77)
        let initial = CapturedFieldState(
            text: "open a pull req",
            selection: UTF16Selection(location: 15, length: 0)
        )
        let afterAcceptance = CapturedFieldState(
            text: "open a pull request ",
            selection: UTF16Selection(location: 20, length: 0)
        )
        let final = CapturedFieldState(
            text: "open a pull request please",
            selection: UTF16Selection(location: 26, length: 0)
        )
        let episode = WritingEpisodeCapture(
            id: UUID(),
            initialField: initial,
            finalField: final,
            edits: [
                WritingEditCapture(
                    insertedText: "uest ",
                    provenance: .acceptedSuggestion,
                    selectionBefore: initial.selection,
                    selectionAfter: afterAcceptance.selection,
                    fieldBefore: initial,
                    fieldAfter: afterAcceptance,
                    startedAt: date,
                    endedAt: date
                ),
                WritingEditCapture(
                    insertedText: "please",
                    provenance: .directlyTyped,
                    selectionBefore: afterAcceptance.selection,
                    selectionAfter: final.selection,
                    fieldBefore: afterAcceptance,
                    fieldAfter: final,
                    startedAt: date,
                    endedAt: date
                ),
            ],
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: date,
            endedAt: date,
            boundary: .submitted
        )

        var model = PersonalLanguageModel()
        model.ingest(episode)

        XCTAssertEqual(
            model.vocabularyEntries().map(\.normalized),
            ["please"]
        )
    }

    func testTypedDelimiterDoesNotRelabelAcceptedWordAsDirectWriting() {
        let date = Date(timeIntervalSince1970: 77.5)
        let initial = CapturedFieldState(
            text: "hello",
            selection: UTF16Selection(location: 5, length: 0)
        )
        let afterAcceptance = CapturedFieldState(
            text: "hello world",
            selection: UTF16Selection(location: 11, length: 0)
        )
        let final = CapturedFieldState(
            text: "hello world ",
            selection: UTF16Selection(location: 12, length: 0)
        )
        let episode = WritingEpisodeCapture(
            id: UUID(),
            initialField: initial,
            finalField: final,
            edits: [
                WritingEditCapture(
                    insertedText: " world",
                    provenance: .acceptedSuggestion,
                    selectionBefore: initial.selection,
                    selectionAfter: afterAcceptance.selection,
                    fieldBefore: initial,
                    fieldAfter: afterAcceptance,
                    startedAt: date,
                    endedAt: date
                ),
                WritingEditCapture(
                    insertedText: " ",
                    provenance: .directlyTyped,
                    selectionBefore: afterAcceptance.selection,
                    selectionAfter: final.selection,
                    fieldBefore: afterAcceptance,
                    fieldAfter: final,
                    startedAt: date,
                    endedAt: date
                ),
            ],
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: date,
            endedAt: date,
            boundary: .submitted
        )

        var model = PersonalLanguageModel(minimumEvidence: 0)
        model.ingest(episode)

        XCTAssertTrue(model.vocabularyEntries().isEmpty)
    }

    func testMergedTypedBurstDoesNotRelabelAcceptedBoundaryWord() {
        let date = Date(timeIntervalSince1970: 77.75)
        let initial = CapturedFieldState(
            text: "hello",
            selection: UTF16Selection(location: 5, length: 0)
        )
        let afterAcceptance = CapturedFieldState(
            text: "hello world",
            selection: UTF16Selection(location: 11, length: 0)
        )
        let final = CapturedFieldState(
            text: "hello world please",
            selection: UTF16Selection(location: 18, length: 0)
        )
        let episode = WritingEpisodeCapture(
            id: UUID(),
            initialField: initial,
            finalField: final,
            edits: [
                WritingEditCapture(
                    insertedText: " world",
                    provenance: .acceptedSuggestion,
                    selectionBefore: initial.selection,
                    selectionAfter: afterAcceptance.selection,
                    fieldBefore: initial,
                    fieldAfter: afterAcceptance,
                    startedAt: date,
                    endedAt: date
                ),
                WritingEditCapture(
                    insertedText: " please",
                    provenance: .directlyTyped,
                    selectionBefore: afterAcceptance.selection,
                    selectionAfter: final.selection,
                    fieldBefore: afterAcceptance,
                    fieldAfter: final,
                    startedAt: date,
                    endedAt: date
                ),
            ],
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: date,
            endedAt: date,
            boundary: .submitted
        )

        var model = PersonalLanguageModel(minimumEvidence: 0)
        model.ingest(episode)

        XCTAssertEqual(
            model.vocabularyEntries().map(\.normalized),
            ["please"]
        )
    }

    func testAcceptedSeparatorDoesNotReinforceUnchangedBoundaryWord() throws {
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                fieldText: "hello",
                selection: UTF16Selection(location: 5, length: 0),
                insertion: " world",
                acceptanceScope: .nextWord,
                context: PersonalizationContext(editorIdentifier: "editor"),
                capturedAt: Date(timeIntervalSince1970: 78)
            )
        )

        var model = PersonalLanguageModel()
        model.ingest(capture)

        XCTAssertEqual(
            model.vocabularyEntries().map(\.normalized),
            ["world"]
        )
    }

    func testEmptyPrefixLocalCompletionDoesNotAddLeadingSpace() throws {
        var model = PersonalLanguageModel(minimumEvidence: 0)
        for offset in 0..<3 {
            model.learn(
                insertedText: "hello",
                precedingText: "",
                signal: .directlyTyped,
                context: PersonalizationContext(editorIdentifier: "editor"),
                at: Date(timeIntervalSince1970: Double(80 + offset))
            )
        }

        let completion = try XCTUnwrap(
            model.completion(
                for: "",
                context: PersonalizationContext(editorIdentifier: "editor"),
                at: Date(timeIntervalSince1970: 90)
            )
        )

        XCTAssertEqual(completion.insertion, "hello")
    }

    func testRepeatedEditorPhrasesCanCompleteLocally() throws {
        let context = PersonalizationContext(
            applicationBundleIdentifier: "com.example.Chat",
            inputKind: "message",
            editorIdentifier: "editor"
        )
        var model = PersonalLanguageModel()
        for offset in 0..<3 {
            let date = Date(timeIntervalSince1970: 80 + Double(offset))
            let finalText = "can you open a pull request for this"
            model.ingest(
                WritingEpisodeCapture(
                    id: UUID(),
                    initialField: CapturedFieldState(
                        text: "",
                        selection: UTF16Selection(location: 0, length: 0)
                    ),
                    finalField: CapturedFieldState(
                        text: finalText,
                        selection: UTF16Selection(
                            location: finalText.utf16.count,
                            length: 0
                        )
                    ),
                    edits: [
                        WritingEditCapture(
                            insertedText: finalText,
                            provenance: .directlyTyped,
                            selectionBefore: UTF16Selection(
                                location: 0,
                                length: 0
                            ),
                            selectionAfter: UTF16Selection(
                                location: finalText.utf16.count,
                                length: 0
                            ),
                            fieldBefore: CapturedFieldState(
                                text: "",
                                selection: UTF16Selection(
                                    location: 0,
                                    length: 0
                                )
                            ),
                            startedAt: date,
                            endedAt: date
                        )
                    ],
                    context: context,
                    startedAt: date,
                    endedAt: date,
                    boundary: .submitted
                )
            )
        }

        let completion = try XCTUnwrap(
            model.completion(
                for: "can you open a pull req",
                context: context,
                at: Date(timeIntervalSince1970: 100)
            )
        )

        XCTAssertEqual(completion.insertion, "uest for this")
    }

    func testPhraseCompletionPreservesPunctuationSeparators() throws {
        let context = PersonalizationContext(editorIdentifier: "editor")
        var model = PersonalLanguageModel()
        for offset in 0..<3 {
            model.learn(
                insertedText: "hello, world",
                precedingText: "",
                signal: .directlyTyped,
                context: context,
                at: Date(timeIntervalSince1970: Double(100 + offset))
            )
        }

        XCTAssertEqual(
            model.completion(
                for: "hello",
                context: context,
                at: Date(timeIntervalSince1970: 110)
            )?.insertion,
            ", world"
        )
        XCTAssertEqual(
            model.completion(
                for: "hello,",
                context: context,
                at: Date(timeIntervalSince1970: 110)
            )?.insertion,
            " world"
        )
        XCTAssertEqual(
            model.completion(
                for: "hello, w",
                context: context,
                at: Date(timeIntervalSince1970: 110)
            )?.insertion,
            "orld"
        )
    }

    func testPunctuationSplitsWordsWithoutSplittingContractions() {
        let context = PersonalizationContext(editorIdentifier: "editor")
        var model = PersonalLanguageModel(minimumEvidence: 0)

        model.learn(
            insertedText: "hello,world can't re-enter",
            precedingText: "",
            signal: .directlyTyped,
            context: context
        )

        XCTAssertEqual(
            Set(model.vocabularyEntries().map(\.normalized)),
            Set(["hello", "world", "can't", "re-enter"])
        )
    }

    func testPhraseCompletionPreservesTerminalPunctuation() throws {
        let context = PersonalizationContext(editorIdentifier: "editor")
        var model = PersonalLanguageModel()
        for offset in 0..<3 {
            model.learn(
                insertedText: "hello, world!",
                precedingText: "",
                signal: .directlyTyped,
                context: context,
                at: Date(timeIntervalSince1970: Double(120 + offset))
            )
        }

        XCTAssertEqual(
            model.completion(
                for: "hello",
                context: context,
                at: Date(timeIntervalSince1970: 130)
            )?.insertion,
            ", world!"
        )
        XCTAssertEqual(
            model.completion(
                for: "hello, world",
                context: context,
                at: Date(timeIntervalSince1970: 130)
            )?.insertion,
            "!"
        )
    }

    func testPartialWordCompletionPreservesApostrophesAndHyphens() throws {
        let context = PersonalizationContext(editorIdentifier: "editor")
        var model = PersonalLanguageModel()
        for offset in 0..<3 {
            let date = Date(timeIntervalSince1970: Double(140 + offset))
            model.learn(
                insertedText: "can't",
                precedingText: "",
                signal: .directlyTyped,
                context: context,
                at: date
            )
            model.learn(
                insertedText: "re-enter",
                precedingText: "",
                signal: .directlyTyped,
                context: context,
                at: date
            )
        }

        XCTAssertEqual(
            model.completion(for: "can", context: context)?.insertion,
            "'t"
        )
        XCTAssertEqual(
            model.completion(for: "re", context: context)?.insertion,
            "-enter"
        )
    }

    func testIdleEpisodeWaitsForDelimiterBeforeLearningTrailingWord() {
        let context = PersonalizationContext(editorIdentifier: "editor")
        let firstDate = Date(timeIntervalSince1970: 110)
        var model = PersonalLanguageModel()
        model.ingest(
            WritingEpisodeCapture(
                id: UUID(),
                initialField: CapturedFieldState(
                    text: "",
                    selection: UTF16Selection(location: 0, length: 0)
                ),
                finalField: CapturedFieldState(
                    text: "th",
                    selection: UTF16Selection(location: 2, length: 0)
                ),
                edits: [
                    WritingEditCapture(
                        insertedText: "th",
                        provenance: .directlyTyped,
                        selectionBefore: UTF16Selection(
                            location: 0,
                            length: 0
                        ),
                        selectionAfter: UTF16Selection(
                            location: 2,
                            length: 0
                        ),
                        fieldBefore: CapturedFieldState(
                            text: "",
                            selection: UTF16Selection(
                                location: 0,
                                length: 0
                            )
                        ),
                        startedAt: firstDate,
                        endedAt: firstDate
                    )
                ],
                context: context,
                startedAt: firstDate,
                endedAt: firstDate,
                boundary: .idle
            )
        )
        XCTAssertTrue(model.vocabularyEntries().isEmpty)

        let secondDate = Date(timeIntervalSince1970: 120)
        model.ingest(
            WritingEpisodeCapture(
                id: UUID(),
                initialField: CapturedFieldState(
                    text: "th",
                    selection: UTF16Selection(location: 2, length: 0)
                ),
                finalField: CapturedFieldState(
                    text: "the ",
                    selection: UTF16Selection(location: 4, length: 0)
                ),
                edits: [
                    WritingEditCapture(
                        insertedText: "e ",
                        provenance: .directlyTyped,
                        selectionBefore: UTF16Selection(
                            location: 2,
                            length: 0
                        ),
                        selectionAfter: UTF16Selection(
                            location: 4,
                            length: 0
                        ),
                        fieldBefore: CapturedFieldState(
                            text: "th",
                            selection: UTF16Selection(
                                location: 2,
                                length: 0
                            )
                        ),
                        startedAt: secondDate,
                        endedAt: secondDate
                    )
                ],
                context: context,
                startedAt: secondDate,
                endedAt: secondDate,
                boundary: .idle
            )
        )

        XCTAssertEqual(
            model.vocabularyEntries().map(\.normalized),
            ["the"]
        )
    }

    func testIdleEpisodeDoesNotLearnEarlierPausedWordFragment() {
        let date = Date(timeIntervalSince1970: 125)
        let initial = CapturedFieldState(
            text: "",
            selection: UTF16Selection(location: 0, length: 0)
        )
        let afterFirstBurst = CapturedFieldState(
            text: "th",
            selection: UTF16Selection(location: 2, length: 0)
        )
        let final = CapturedFieldState(
            text: "the ",
            selection: UTF16Selection(location: 4, length: 0)
        )
        let episode = WritingEpisodeCapture(
            id: UUID(),
            initialField: initial,
            finalField: final,
            edits: [
                WritingEditCapture(
                    insertedText: "th",
                    provenance: .directlyTyped,
                    selectionBefore: initial.selection,
                    selectionAfter: afterFirstBurst.selection,
                    fieldBefore: initial,
                    fieldAfter: afterFirstBurst,
                    startedAt: date,
                    endedAt: date
                ),
                WritingEditCapture(
                    insertedText: "e ",
                    provenance: .directlyTyped,
                    selectionBefore: afterFirstBurst.selection,
                    selectionAfter: final.selection,
                    fieldBefore: afterFirstBurst,
                    fieldAfter: final,
                    startedAt: date.addingTimeInterval(1),
                    endedAt: date.addingTimeInterval(1)
                ),
            ],
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: date,
            endedAt: date.addingTimeInterval(1),
            boundary: .idle
        )

        var model = PersonalLanguageModel(minimumEvidence: 0)
        model.ingest(episode)

        XCTAssertEqual(
            model.vocabularyEntries().map(\.normalized),
            ["the"]
        )
    }

    func testVocabularyEntriesExposePreferredCasingAndFeedbackEvidence() {
        var model = PersonalLanguageModel()
        let context = PersonalizationContext(editorIdentifier: "editor")
        model.learn(
            insertedText: "StenoTab",
            precedingText: "use ",
            signal: .acceptedSuggestion,
            context: context,
            at: Date(timeIntervalSince1970: 100)
        )
        model.learn(
            insertedText: "stenotab",
            precedingText: "open ",
            signal: .directlyTyped,
            context: context,
            at: Date(timeIntervalSince1970: 200)
        )

        let entry = model.vocabularyEntries(limit: 1).first

        XCTAssertEqual(entry?.normalized, "stenotab")
        XCTAssertEqual(entry?.preferredCasing, "StenoTab")
        XCTAssertEqual(entry?.positiveEvidence, 3.5)
        XCTAssertEqual(entry?.acceptedCount, 1)
        XCTAssertEqual(entry?.lastSeen, Date(timeIntervalSince1970: 200))
    }

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

    func testTerminalSeparatorStopsPhraseGeneration() {
        let context = PersonalizationContext(editorIdentifier: "editor")
        var model = PersonalLanguageModel()
        for offset in 0..<3 {
            model.learn(
                insertedText: "hello world!",
                precedingText: "",
                signal: .directlyTyped,
                context: context,
                at: Date(timeIntervalSince1970: Double(1_100 + offset))
            )
        }
        for offset in 0..<2 {
            model.learn(
                insertedText: "hello world again",
                precedingText: "",
                signal: .directlyTyped,
                context: context,
                at: Date(timeIntervalSince1970: Double(1_200 + offset))
            )
        }

        XCTAssertEqual(
            model.completion(for: "hello", context: context)?.insertion,
            " world!"
        )
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
