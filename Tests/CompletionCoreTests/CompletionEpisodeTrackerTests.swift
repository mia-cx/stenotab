import XCTest
@testable import CompletionCore

final class CompletionEpisodeTrackerTests: XCTestCase {
    func testReconciliationSettlementMapsEveryDecision() {
        XCTAssertEqual(
            CompletionEpisodeReconciliationPolicy.settlement(
                for: .waitForAuthoritativeChange
            ),
            .wait
        )
        XCTAssertEqual(
            CompletionEpisodeReconciliationPolicy.settlement(
                for: .discardUnobservedAndReconcile
            ),
            .discard
        )
        XCTAssertEqual(
            CompletionEpisodeReconciliationPolicy.settlement(
                for: .finalizeFromAuthoritativeBaselineAndReconcile
            ),
            .finalizeFromAuthoritativeBaseline
        )
        XCTAssertEqual(
            CompletionEpisodeReconciliationPolicy.settlement(
                for: .reconcile
            ),
            .finalizeFromObservedField
        )
    }

    func testReconciliationWaitsForChangedAuthoritativeFieldBeforeDeadline() {
        let before = CapturedFieldState(
            text: "before",
            selection: UTF16Selection(location: 6, length: 0)
        )
        let expected = CapturedFieldState(
            text: "before after",
            selection: UTF16Selection(location: 12, length: 0)
        )

        let decision = CompletionEpisodeReconciliationPolicy.decision(
            previousEditorIdentifier: "editor",
            observedEditorIdentifier: "editor",
            authoritativeBaselineField: before,
            expectedField: expected,
            observedField: before,
            observationDeadlineExceeded: false
        )

        XCTAssertEqual(decision, .waitForAuthoritativeChange)
    }

    func testReconciliationDiscardsUnchangedFieldAfterDeadline() {
        let before = CapturedFieldState(
            text: "before",
            selection: UTF16Selection(location: 6, length: 0)
        )
        let expected = CapturedFieldState(
            text: "before after",
            selection: UTF16Selection(location: 12, length: 0)
        )

        let decision = CompletionEpisodeReconciliationPolicy.decision(
            previousEditorIdentifier: "editor",
            observedEditorIdentifier: "editor",
            authoritativeBaselineField: before,
            expectedField: expected,
            observedField: before,
            observationDeadlineExceeded: true
        )

        XCTAssertEqual(decision, .discardUnobservedAndReconcile)
    }

    func testPassThroughEventWaitsForPostEventObservation() {
        let unchanged = CapturedFieldState(
            text: "before",
            selection: UTF16Selection(location: 6, length: 0)
        )

        let decision = CompletionEpisodeReconciliationPolicy.decision(
            previousEditorIdentifier: "editor",
            observedEditorIdentifier: "editor",
            authoritativeBaselineField: unchanged,
            expectedField: unchanged,
            observedField: unchanged,
            requiresPostEventObservation: true
        )

        XCTAssertEqual(decision, .waitForAuthoritativeChange)
    }

    func testReconciliationAcceptsChangedAuthoritativeField() {
        let before = CapturedFieldState(
            text: "before",
            selection: UTF16Selection(location: 6, length: 0)
        )
        let after = CapturedFieldState(
            text: "before after",
            selection: UTF16Selection(location: 12, length: 0)
        )

        let decision = CompletionEpisodeReconciliationPolicy.decision(
            previousEditorIdentifier: "editor",
            observedEditorIdentifier: "editor",
            authoritativeBaselineField: before,
            expectedField: after,
            observedField: after
        )

        XCTAssertEqual(decision, .reconcile)
    }

    func testReconciliationWaitsForIntermediateAuthoritativeField() {
        let before = CapturedFieldState(
            text: "a",
            selection: UTF16Selection(location: 1, length: 0)
        )
        let expected = CapturedFieldState(
            text: "abc",
            selection: UTF16Selection(location: 3, length: 0)
        )
        let intermediate = CapturedFieldState(
            text: "ab",
            selection: UTF16Selection(location: 2, length: 0)
        )

        let decision = CompletionEpisodeReconciliationPolicy.decision(
            previousEditorIdentifier: "editor",
            observedEditorIdentifier: "editor",
            authoritativeBaselineField: before,
            expectedField: expected,
            observedField: intermediate
        )

        XCTAssertEqual(decision, .waitForAuthoritativeChange)
    }

    func testFocusChangeDiscardsUnobservedOutcome() {
        let authoritative = CapturedFieldState(
            text: "before",
            selection: UTF16Selection(location: 6, length: 0)
        )
        let predicted = CapturedFieldState(
            text: "before accepted",
            selection: UTF16Selection(location: 15, length: 0)
        )

        let decision = CompletionEpisodeReconciliationPolicy.decision(
            previousEditorIdentifier: "old-editor",
            observedEditorIdentifier: "new-editor",
            authoritativeBaselineField: authoritative,
            expectedField: predicted,
            observedField: CapturedFieldState(
                text: "new",
                selection: UTF16Selection(location: 3, length: 0)
            )
        )

        XCTAssertEqual(
            decision,
            .discardUnobservedAndReconcile
        )
    }

    func testFocusChangeRetainsDismissedSuggestionFromKnownBaseline() {
        let authoritative = CapturedFieldState(
            text: "before",
            selection: UTF16Selection(location: 6, length: 0)
        )

        let decision = CompletionEpisodeReconciliationPolicy.decision(
            previousEditorIdentifier: "old-editor",
            observedEditorIdentifier: "new-editor",
            authoritativeBaselineField: authoritative,
            expectedField: authoritative,
            observedField: CapturedFieldState(
                text: "new",
                selection: UTF16Selection(location: 3, length: 0)
            ),
            requiresPostEventObservation: true
        )

        XCTAssertEqual(
            decision,
            .finalizeFromAuthoritativeBaselineAndReconcile
        )
    }

    func testDeletionBoundaryRejectsOnlyPreDeletionInvocations() {
        let startedAt = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(
            CompletionEpisodeDeletionBoundaryPolicy.allowsCapture(
                invocationStartedAt: startedAt,
                deleteAllAt: Date(timeIntervalSince1970: 101),
                applicationDeletedAt: nil
            )
        )
        XCTAssertFalse(
            CompletionEpisodeDeletionBoundaryPolicy.allowsCapture(
                invocationStartedAt: startedAt,
                deleteAllAt: nil,
                applicationDeletedAt: Date(timeIntervalSince1970: 101)
            )
        )
        XCTAssertTrue(
            CompletionEpisodeDeletionBoundaryPolicy.allowsCapture(
                invocationStartedAt: Date(timeIntervalSince1970: 102),
                deleteAllAt: Date(timeIntervalSince1970: 101),
                applicationDeletedAt: Date(timeIntervalSince1970: 101)
            )
        )
    }

    func testUnchangedInvalidationReconcilesWithoutPolling() {
        let unchanged = CapturedFieldState(
            text: "before",
            selection: UTF16Selection(location: 6, length: 0)
        )

        let decision = CompletionEpisodeReconciliationPolicy.decision(
            previousEditorIdentifier: "editor",
            observedEditorIdentifier: "editor",
            authoritativeBaselineField: unchanged,
            expectedField: unchanged,
            observedField: unchanged
        )

        XCTAssertEqual(decision, .reconcile)
    }

    func testPendingTerminalResolutionCannotBeOverwrittenByAbandonment() {
        XCTAssertEqual(
            CompletionEpisodePendingResolutionPolicy.resolve(
                existing: .typedThrough,
                proposed: .rejected
            ),
            .typedThrough
        )
        XCTAssertEqual(
            CompletionEpisodePendingResolutionPolicy.resolve(
                existing: .accepted,
                proposed: .partiallyAccepted
            ),
            .accepted
        )
    }

    func testCaptureRequiresLiveSnapshotFromActiveEditor() {
        XCTAssertFalse(
            CompletionEpisodeLiveEditorPolicy.requiresVerification(
                activeInvocationID: nil
            )
        )
        XCTAssertTrue(
            CompletionEpisodeLiveEditorPolicy.requiresVerification(
                activeInvocationID: UUID()
            )
        )
        XCTAssertTrue(
            CompletionEpisodeLiveEditorPolicy.allowsCapture(
                activeEditorIdentifier: "editor",
                liveEditorIdentifier: "editor"
            )
        )
        XCTAssertFalse(
            CompletionEpisodeLiveEditorPolicy.allowsCapture(
                activeEditorIdentifier: "editor",
                liveEditorIdentifier: nil
            )
        )
        XCTAssertFalse(
            CompletionEpisodeLiveEditorPolicy.allowsCapture(
                activeEditorIdentifier: "editor",
                liveEditorIdentifier: "secure-or-different-editor"
            )
        )
        let expectedField = CapturedFieldState(
            text: "selected text",
            selection: UTF16Selection(location: 0, length: 8)
        )
        XCTAssertTrue(
            CompletionEpisodeLiveEditorPolicy.allowsCapture(
                activeEditorIdentifier: "editor",
                liveEditorIdentifier: "editor",
                expectedField: expectedField,
                liveField: expectedField
            )
        )
        XCTAssertFalse(
            CompletionEpisodeLiveEditorPolicy.allowsCapture(
                activeEditorIdentifier: "editor",
                liveEditorIdentifier: "editor",
                expectedField: expectedField,
                liveField: CapturedFieldState(
                    text: "changed text",
                    selection: expectedField.selection
                )
            )
        )
        XCTAssertFalse(
            CompletionEpisodeLiveEditorPolicy.allowsCapture(
                activeEditorIdentifier: "editor",
                liveEditorIdentifier: "editor",
                expectedField: expectedField,
                liveField: CapturedFieldState(
                    text: expectedField.text,
                    selection: UTF16Selection(location: 8, length: 0)
                )
            )
        )
    }

    func testRejectedSuggestionPreservesPromptRevisionsAndFinalWriting() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let invocation = CompletionInvocationCapture(
            id: UUID(
                uuidString: "D09D4AFF-B477-47B6-96C3-ED3D45949518"
            )!,
            field: CapturedFieldState(
                text: "I think we sh",
                selection: UTF16Selection(location: 13, length: 0)
            ),
            prompt: CapturedCompletionPrompt(
                transport: .chatCompletion,
                systemMessage:
                    "Continue the user's current text at the cursor.",
                userMessage:
                    "Some text visible on screen:\nReview the cache.\n\n"
                    + "My writing:\n§I think we sh"
            ),
            generation: CompletionGenerationMetadata(
                providerKind: "openai-compatible",
                modelIdentifier: "gemma-4-e2b",
                maximumTokens: 16,
                temperature: 0,
                stopSequences: []
            ),
            context: PersonalizationContext(
                applicationBundleIdentifier: "com.example.Chat",
                website: "example.com",
                inputKind: "message",
                editorIdentifier: "editor-1"
            ),
            startedAt: startedAt
        )
        var tracker = CompletionEpisodeTracker()

        tracker.begin(invocation)
        tracker.observeSuggestion(
            "ould probably clear it",
            isFinal: false,
            at: startedAt.addingTimeInterval(0.1)
        )
        tracker.observeSuggestion(
            "ould probably clear it first",
            isFinal: true,
            at: startedAt.addingTimeInterval(0.2)
        )

        let finalField = CapturedFieldState(
            text: "I think we should reuse the cache",
            selection: UTF16Selection(location: 33, length: 0)
        )
        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .rejected,
                finalField: finalField,
                at: startedAt.addingTimeInterval(0.5)
            )
        )

        XCTAssertEqual(episode.id, invocation.id)
        XCTAssertEqual(episode.invocation, invocation)
        XCTAssertEqual(
            episode.suggestionRevisions.map(\.text),
            [
                "ould probably clear it",
                "ould probably clear it first",
            ]
        )
        XCTAssertEqual(
            episode.suggestionRevisions.map(\.isFinal),
            [false, true]
        )
        XCTAssertEqual(episode.acceptedText, "")
        XCTAssertEqual(episode.typedThroughText, "")
        XCTAssertEqual(episode.resolution, .rejected)
        XCTAssertEqual(episode.finalField, finalField)
        XCTAssertEqual(
            episode.actualInsertedText,
            "ould reuse the cache"
        )
    }

    func testPartialAcceptancesPreserveEveryLiteralInsertedSpan() throws {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let invocation = CompletionInvocationCapture(
            id: UUID(
                uuidString: "99EC0AA4-5945-4573-8B9B-B7181119BB57"
            )!,
            field: CapturedFieldState(
                text: "can you open a pull req",
                selection: UTF16Selection(location: 23, length: 0)
            ),
            prompt: CapturedCompletionPrompt(
                transport: .textCompletion,
                textPrompt: "My writing:\n§can you open a pull req"
            ),
            generation: CompletionGenerationMetadata(
                providerKind: "local",
                modelIdentifier: "gemma-4-e2b",
                maximumTokens: 16,
                temperature: 0,
                stopSequences: []
            ),
            context: PersonalizationContext(editorIdentifier: "editor-2"),
            startedAt: startedAt
        )
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(
            "uest for this change",
            isFinal: true,
            at: startedAt.addingTimeInterval(0.1)
        )
        tracker.recordAcceptance(
            "uest ",
            scope: .nextWord,
            at: startedAt.addingTimeInterval(0.2)
        )
        tracker.recordAcceptance(
            "for ",
            scope: .nextWord,
            at: startedAt.addingTimeInterval(0.3)
        )

        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .partiallyAccepted,
                finalField: CapturedFieldState(
                    text: "can you open a pull request for another change",
                    selection: UTF16Selection(location: 46, length: 0)
                ),
                at: startedAt.addingTimeInterval(0.5)
            )
        )

        XCTAssertEqual(episode.acceptedText, "uest for ")
        XCTAssertEqual(
            episode.acceptances.map(\.text),
            ["uest ", "for "]
        )
        XCTAssertEqual(
            episode.acceptances.map(\.scope),
            [.nextWord, .nextWord]
        )
        XCTAssertEqual(
            episode.actualInsertedText,
            "uest for another change"
        )
    }

    func testTypedThroughTextIsKeptSeparateFromAcceptedModelText() throws {
        let startedAt = Date(timeIntervalSince1970: 3_000)
        let invocation = CompletionInvocationCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "thank",
                selection: UTF16Selection(location: 5, length: 0)
            ),
            prompt: CapturedCompletionPrompt(
                transport: .textCompletion,
                textPrompt: "My writing:\n§thank"
            ),
            generation: CompletionGenerationMetadata(
                providerKind: "local",
                modelIdentifier: "gemma-4-e2b",
                maximumTokens: 16,
                temperature: 0,
                stopSequences: []
            ),
            context: PersonalizationContext(editorIdentifier: "editor-3"),
            startedAt: startedAt
        )
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(
            " you for checking",
            isFinal: true,
            at: startedAt.addingTimeInterval(0.1)
        )
        tracker.synchronizeTypedThrough(
            consumedSuggestionText: " you "
        )

        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .typedThrough,
                finalField: CapturedFieldState(
                    text: "thank you anyway",
                    selection: UTF16Selection(location: 16, length: 0)
                ),
                at: startedAt.addingTimeInterval(0.3)
            )
        )

        XCTAssertEqual(episode.acceptedText, "")
        XCTAssertEqual(episode.typedThroughText, " you ")
        XCTAssertEqual(episode.actualInsertedText, " you anyway")
    }

    func testFinalStreamMarkerUpdatesRatherThanDuplicatesSameSuggestion()
        throws
    {
        let date = Date(timeIntervalSince1970: 4_000)
        let invocation = CompletionInvocationCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "hello",
                selection: UTF16Selection(location: 5, length: 0)
            ),
            prompt: CapturedCompletionPrompt(
                transport: .textCompletion,
                textPrompt: "My writing:\n§hello"
            ),
            generation: CompletionGenerationMetadata(
                providerKind: "local",
                modelIdentifier: "gemma-4-e2b",
                maximumTokens: 16,
                temperature: 0,
                stopSequences: []
            ),
            context: PersonalizationContext(editorIdentifier: "editor-4"),
            startedAt: date
        )
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(
            " there",
            isFinal: false,
            at: date.addingTimeInterval(0.1)
        )
        tracker.observeSuggestion(
            " there",
            isFinal: true,
            at: date.addingTimeInterval(0.2)
        )

        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .rejected,
                finalField: invocation.field,
                at: date.addingTimeInterval(0.3)
            )
        )
        XCTAssertEqual(episode.suggestionRevisions.count, 1)
        XCTAssertEqual(episode.suggestionRevisions[0].text, " there")
        XCTAssertTrue(episode.suggestionRevisions[0].isFinal)
        XCTAssertEqual(
            episode.suggestionRevisions[0].observedAt,
            date.addingTimeInterval(0.2)
        )
    }

    func testHiddenFinalMarkerUpdatesOnlyTheDisplayedRevision() throws {
        let date = Date(timeIntervalSince1970: 4_100)
        let invocation = makeInvocation(date: date)
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(" hello", isFinal: false, at: date)

        tracker.markSuggestionFinalIfObserved(
            " hello",
            at: date.addingTimeInterval(1)
        )
        tracker.markSuggestionFinalIfObserved(
            " hello world",
            at: date.addingTimeInterval(2)
        )

        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .typedThrough,
                finalField: invocation.field,
                at: date.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(episode.suggestionRevisions.count, 1)
        XCTAssertEqual(episode.suggestionRevisions[0].text, " hello")
        XCTAssertTrue(episode.suggestionRevisions[0].isFinal)
    }

    func testMixedTabAcceptanceAndTypedThroughResolvesAsPartialAcceptance() {
        let date = Date(timeIntervalSince1970: 5_000)
        let invocation = CompletionInvocationCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "pull req",
                selection: UTF16Selection(location: 8, length: 0)
            ),
            prompt: CapturedCompletionPrompt(
                transport: .textCompletion,
                textPrompt: "My writing:\n§pull req"
            ),
            generation: CompletionGenerationMetadata(
                providerKind: "local",
                modelIdentifier: "gemma-4-e2b",
                maximumTokens: 16,
                temperature: 0,
                stopSequences: []
            ),
            context: PersonalizationContext(editorIdentifier: "editor-5"),
            startedAt: date
        )
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(
            "uest for this",
            isFinal: true,
            at: date
        )
        tracker.recordAcceptance("uest ", scope: .nextWord, at: date)
        tracker.synchronizeTypedThrough(
            consumedSuggestionText: "uest for this"
        )

        XCTAssertEqual(
            tracker.completedSuggestionResolution,
            .partiallyAccepted
        )
    }

    func testAbandoningPartiallyAcceptedSuggestionIsNotFullyAccepted() {
        let date = Date(timeIntervalSince1970: 5_500)
        let invocation = makeInvocation(date: date)
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(" there now", isFinal: true, at: date)
        tracker.recordAcceptance(" there", scope: .nextWord, at: date)

        XCTAssertEqual(tracker.completedSuggestionResolution, .accepted)
        XCTAssertEqual(
            tracker.abandonedSuggestionResolution,
            .partiallyAccepted
        )
    }

    func testTypedThroughOnlyIncludesStreamConfirmedText() throws {
        let date = Date(timeIntervalSince1970: 5_750)
        let invocation = makeInvocation(date: date)
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(" h", isFinal: false, at: date)
        tracker.synchronizeTypedThrough(consumedSuggestionText: " h")
        tracker.observeSuggestion(" hi", isFinal: true, at: date)
        tracker.synchronizeTypedThrough(consumedSuggestionText: " hi")

        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .typedThrough,
                finalField: CapturedFieldState(
                    text: "hello hi",
                    selection: UTF16Selection(location: 8, length: 0)
                ),
                at: date
            )
        )

        XCTAssertEqual(episode.typedThroughText, " hi")
    }

    func testTypedThroughSpansCanSurroundAnAcceptance() throws {
        let date = Date(timeIntervalSince1970: 5_800)
        let invocation = makeInvocation(date: date)
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(" there now", isFinal: true, at: date)
        tracker.synchronizeTypedThrough(consumedSuggestionText: " ")
        tracker.recordAcceptance("there ", scope: .nextWord, at: date)
        tracker.synchronizeTypedThrough(
            consumedSuggestionText: " there now"
        )

        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .partiallyAccepted,
                finalField: CapturedFieldState(
                    text: "hello there now",
                    selection: UTF16Selection(location: 15, length: 0)
                ),
                at: date
            )
        )

        XCTAssertEqual(episode.acceptedText, "there ")
        XCTAssertEqual(episode.typedThroughText, " now")
    }

    func testGenerationFailureRemainsVisibleAfterPartialSuggestionResolution()
        throws
    {
        let date = Date(timeIntervalSince1970: 5_875)
        let invocation = makeInvocation(date: date)
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(" there", isFinal: false, at: date)
        tracker.recordGenerationFailure()

        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .rejected,
                finalField: invocation.field,
                at: date
            )
        )

        XCTAssertTrue(episode.generationDidFail)
        XCTAssertEqual(episode.resolution, .rejected)
    }

    func testSuggestionRevisionHistoryPreservesEveryReachableStreamRevision()
        throws
    {
        let date = Date(timeIntervalSince1970: 5_900)
        let invocation = makeInvocation(date: date)
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        var revision = ""
        for index in 0..<4_096 {
            revision.append("x")
            tracker.observeSuggestion(
                revision,
                isFinal: index == 4_095,
                at: date
            )
        }

        let episode = try XCTUnwrap(
            tracker.finalize(
                resolution: .rejected,
                finalField: invocation.field,
                at: date
            )
        )

        XCTAssertEqual(episode.suggestionRevisions.count, 4_096)
        XCTAssertEqual(
            episode.suggestionRevisions[512].text.count,
            513
        )
        XCTAssertEqual(episode.suggestionRevisions.last?.text.count, 4_096)
        XCTAssertTrue(episode.suggestionRevisions.last?.isFinal == true)
    }

    func testFinalizeWithoutSuggestionRevisionReturnsNil() {
        let date = Date(timeIntervalSince1970: 6_000)
        let invocation = makeInvocation(date: date)
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)

        XCTAssertNil(
            tracker.finalize(
                resolution: .rejected,
                finalField: invocation.field,
                at: date
            )
        )
    }

    func testFinalizeWithInvalidFinalSelectionReturnsNil() {
        let date = Date(timeIntervalSince1970: 7_000)
        let invocation = makeInvocation(date: date)
        var tracker = CompletionEpisodeTracker()
        tracker.begin(invocation)
        tracker.observeSuggestion(" there", isFinal: true, at: date)

        XCTAssertNil(
            tracker.finalize(
                resolution: .rejected,
                finalField: CapturedFieldState(
                    text: "hello",
                    selection: UTF16Selection(location: 99, length: 0)
                ),
                at: date
            )
        )
    }

    private func makeInvocation(date: Date) -> CompletionInvocationCapture {
        CompletionInvocationCapture(
            id: UUID(),
            field: CapturedFieldState(
                text: "hello",
                selection: UTF16Selection(location: 5, length: 0)
            ),
            prompt: CapturedCompletionPrompt(
                transport: .textCompletion,
                textPrompt: "My writing:\n§hello"
            ),
            generation: CompletionGenerationMetadata(
                providerKind: "local",
                modelIdentifier: "gemma-4-e2b",
                maximumTokens: 16,
                temperature: 0,
                stopSequences: []
            ),
            context: PersonalizationContext(editorIdentifier: "editor"),
            startedAt: date
        )
    }
}
