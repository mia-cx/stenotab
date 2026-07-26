import AppKit
import ApplicationServices
import CompletionCore
import OSLog

@MainActor
final class CompletionCoordinator: NSObject {
    private struct CachedOCRContext {
        let editorIdentifier: String
        let text: String?
    }

    private struct RefillKey: Equatable {
        let prefix: String
        let suffix: String
        let editorIdentifier: String
    }

    private enum SuggestionAssociationToken: Equatable {
        case model(UInt64)
        case refill(UInt64)
    }

    private let accessibility = AccessibilityReader()
    private let overlay = SuggestionOverlay()
    private let ocrCapture = ScreenOCRContextCapture()
    private let ocrLogger = Logger(
        subsystem: "cx.mia.stenotab",
        category: "OCR"
    )
    private let provider: any CompletionProvider
    private let promptConfiguration: @MainActor () -> PromptConfiguration
    private let applicationCompletionsAreEnabled:
        @MainActor (String?) -> Bool
    private let onApplicationObserved:
        @MainActor (ApplicationObservation) -> Void
    private let onSuggestionAccepted: @MainActor (String) -> Void
    private let onPersonalizationCapture:
        @MainActor (AcceptedSuggestionCapture) -> Void
    private let onWritingEpisode:
        @MainActor (WritingEpisodeCapture) -> Void
    private let writingHistoryCollectionIsEnabled:
        @MainActor () -> Bool
    private let onCompletionFeedback:
        @MainActor (CompletionFeedbackCapture) -> Void
    private let onCompletionEpisode:
        @MainActor (CompletionEpisodeCapture) -> Void
    private let personalCompletion:
        @MainActor (String, PersonalizationContext) -> PersonalCompletion?
    private let personalizationPromptContext:
        @MainActor (
            String,
            PersonalizationContext
        ) async -> PersonalizationPromptContext
    private var inputMonitor: GlobalInputMonitor?
    private var reconciliationTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var ocrCaptureTask: Task<Void, Never>?
    private var ocrCaptureEditorIdentifier: String?
    private var ocrCaptureRequestID: UInt64 = 0
    private var cachedOCRContext: CachedOCRContext?
    private var lastOCRFocusedEditorIdentifier: String?

    private var buffer = ShadowTextBuffer()
    private var lastSnapshot: EditorSnapshot?
    private var suggestion: String?
    private var suggestionConsumption: SuggestionConsumption?
    private var suggestionAssociationToken: SuggestionAssociationToken?
    private var newestRequestID: UInt64 = 0
    private var preparedRequestSnapshot:
        (requestID: UInt64, snapshot: EditorSnapshot)?
    private var enabled = true
    private var permissionObserver: ((PermissionState) -> Void)?
    private var lastPermissionState: PermissionState?
    private var typographyCalibrationByProcess:
        [pid_t: TypographyScaleCalibration] = [:]
    private var whitespaceCalibrationByEditor:
        [String: LeadingWhitespaceCalibration] = [:]
    private var whitespaceCalibrationTask: Task<Void, Never>?
    private var caretReanchorTask: Task<Void, Never>?
    private var refillTask: Task<Void, Never>?
    private var refillKey: RefillKey?
    private var awaitedRefillKey: RefillKey?
    private var prefetchedRefill:
        (
            key: RefillKey,
            text: String,
            requestID: UInt64,
            invocation: CompletionInvocationCapture?,
            didFail: Bool
        )?
    private var refillRequestID: UInt64 = 0
    private var consecutiveSnapshotFailures = 0
    private var writingHistoryTracker = WritingHistoryTracker()
    private var completionReversionTracker = CompletionReversionTracker()
    private var completionEpisodeTracker = CompletionEpisodeTracker()
    private var activeCompletionEpisodeToken: SuggestionAssociationToken?
    private var pendingCompletionEpisodeResolution:
        CompletionEpisodeResolution?
    private var invalidationReconciliationNotBefore: Date?
    private var invalidationReconciliationGeneration: UInt64 = 0
    private var completionEpisodeAuthoritativeBaselineField:
        CapturedFieldState?
    private var completionEpisodeExpectedField:
        CapturedFieldState?
    private var completionEpisodeRequiresPostEventObservation = false
    private var completionEpisodeObservationDeadline: Date?
    private var typedSuggestionOrigin: CapturedFieldState?
    private let completionEpisodeCollectionIsEnabled:
        @MainActor () -> Bool
    private let completionEpisodeCollectionGeneration:
        @MainActor () -> UInt64

    private lazy var requestPump = LatestStreamPump<
        CompletionRequest,
        CompletionResponse
    >(
        operation: { [provider] request in
            await provider.stream(request)
        },
        deliver: { [weak self] response in
            await MainActor.run {
                self?.receive(response)
            }
        }
    )

    init(
        provider: any CompletionProvider = ProviderFactory.make(),
        promptConfiguration: @escaping @MainActor () -> PromptConfiguration = {
            .defaults
        },
        applicationCompletionsAreEnabled: @escaping @MainActor (
            String?
        ) -> Bool = { _ in true },
        onApplicationObserved: @escaping @MainActor (
            ApplicationObservation
        ) -> Void = { _ in },
        onSuggestionAccepted: @escaping @MainActor (String) -> Void = { _ in },
        onPersonalizationCapture: @escaping @MainActor (
            AcceptedSuggestionCapture
        ) -> Void = { _ in },
        onWritingEpisode: @escaping @MainActor (
            WritingEpisodeCapture
        ) -> Void = { _ in },
        writingHistoryCollectionIsEnabled:
            @escaping @MainActor () -> Bool = { true },
        onCompletionFeedback: @escaping @MainActor (
            CompletionFeedbackCapture
        ) -> Void = { _ in },
        onCompletionEpisode: @escaping @MainActor (
            CompletionEpisodeCapture
        ) -> Void = { _ in },
        completionEpisodeCollectionIsEnabled:
            @escaping @MainActor () -> Bool = { true },
        completionEpisodeCollectionGeneration:
            @escaping @MainActor () -> UInt64 = { 0 },
        personalCompletion: @escaping @MainActor (
            String,
            PersonalizationContext
        ) -> PersonalCompletion? = { _, _ in nil },
        personalizationPromptContext: @escaping @MainActor (
            String,
            PersonalizationContext
        ) async -> PersonalizationPromptContext = { _, _ in .empty }
    ) {
        self.provider = provider
        self.promptConfiguration = promptConfiguration
        self.applicationCompletionsAreEnabled =
            applicationCompletionsAreEnabled
        self.onApplicationObserved = onApplicationObserved
        self.onSuggestionAccepted = onSuggestionAccepted
        self.onPersonalizationCapture = onPersonalizationCapture
        self.onWritingEpisode = onWritingEpisode
        self.writingHistoryCollectionIsEnabled =
            writingHistoryCollectionIsEnabled
        self.onCompletionFeedback = onCompletionFeedback
        self.onCompletionEpisode = onCompletionEpisode
        self.completionEpisodeCollectionIsEnabled =
            completionEpisodeCollectionIsEnabled
        self.completionEpisodeCollectionGeneration =
            completionEpisodeCollectionGeneration
        self.personalCompletion = personalCompletion
        self.personalizationPromptContext = personalizationPromptContext
        super.init()
    }

    func start() {
        requestInitialPermissionPrompts()
        publishPermissionState(force: true)
        reconcile()

        let monitor = GlobalInputMonitor(
            onMutation: { [weak self] mutation in
                self?.handle(mutation)
            },
            onTab: { [weak self] scope in
                self?.acceptSuggestion(scope: scope) ?? false
            },
            onFocus: { [weak self] in
                self?.reconcile(captureFocusedEditor: true)
            },
            onSubmit: { [weak self] in
                self?.finalizeSubmittedWritingEpisode() ?? false
            }
        )
        inputMonitor = monitor
        _ = monitor.start()

        reconciliationTimer = Timer.scheduledTimer(
            withTimeInterval: 0.4,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.inputMonitor?.isRunning == false {
                    _ = self?.inputMonitor?.start()
                }
                self?.publishPermissionState()
                self?.finalizeIdleWritingEpisode()
                self?.reconcile()
            }
        }
    }

    func observePermissionState(
        _ observer: @escaping (PermissionState) -> Void
    ) {
        permissionObserver = observer
        publishPermissionState(force: true)
    }

    @objc func openNextMissingPermission() {
        guard let pane = currentPermissionState.nextSettingsPane else { return }
        openSettings(pane)
    }

    @objc func openAccessibilitySettings() {
        openSettings(.accessibility)
    }

    func requestAccessibilityPermission() {
        accessibility.requestTrustPrompt()
        publishPermissionState(force: true)
    }

    @objc func openScreenRecordingSettings() {
        openSettings(.screenRecording)
    }

    func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        publishPermissionState(force: true)
    }

    private func requestInitialPermissionPrompts() {
        accessibility.requestTrustPrompt()
    }

    private var currentPermissionState: PermissionState {
        PermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
    }

    func stop() {
        enabled = false
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        invalidatePendingCompletion()
        clearOCRContext()
        let hasActiveCompletionEpisode =
            pendingCompletionEpisodeResolution != nil
            || completionEpisodeTracker.activeInvocationID != nil
        let shutdownSnapshot =
            hasActiveCompletionEpisode
            ? accessibility.snapshot()
            : nil
        if pendingCompletionEpisodeResolution != nil {
            if
                let snapshot = shutdownSnapshot,
                snapshot.editorIdentifier == lastSnapshot?.editorIdentifier
            {
                let observedField = capturedField(from: snapshot)
                let authoritativeBaselineField =
                    completionEpisodeAuthoritativeBaselineField
                let reconciliationDecision =
                    CompletionEpisodeReconciliationPolicy.decision(
                        previousEditorIdentifier:
                            lastSnapshot?.editorIdentifier,
                        observedEditorIdentifier:
                            snapshot.editorIdentifier,
                        authoritativeBaselineField:
                            authoritativeBaselineField,
                        expectedField: completionEpisodeExpectedField,
                        observedField: observedField,
                        requiresPostEventObservation:
                            completionEpisodeRequiresPostEventObservation,
                        observationDeadlineExceeded:
                            completionEpisodeObservationDeadlineExceeded
                    )
                lastSnapshot = snapshot
                _ = buffer.reconcile(
                    prefix: snapshot.prefix,
                    suffix: snapshot.suffix
                )
                switch CompletionEpisodeReconciliationPolicy.settlement(
                    for: reconciliationDecision
                ) {
                case .wait, .discard:
                    discardPendingCompletionEpisode()
                case .finalizeFromAuthoritativeBaseline:
                    finalizePendingCompletionEpisodeIfNeeded(
                        finalField: authoritativeBaselineField
                    )
                case .finalizeFromObservedField:
                    finalizePendingCompletionEpisodeIfNeeded(
                        finalField: observedField
                    )
                }
            } else {
                discardPendingCompletionEpisode()
            }
        } else if completionEpisodeTracker.activeInvocationID != nil {
            if
                let snapshot = shutdownSnapshot,
                snapshot.editorIdentifier == lastSnapshot?.editorIdentifier
            {
                lastSnapshot = snapshot
                _ = buffer.reconcile(
                    prefix: snapshot.prefix,
                    suffix: snapshot.suffix
                )
                finalizeCompletionEpisode(
                    resolution:
                        completionEpisodeTracker
                        .abandonedSuggestionResolution,
                    finalField: capturedField(from: snapshot)
                )
            } else {
                discardCompletionEpisodeAndSuggestion()
            }
        }
        clearSuggestion(
            resolution:
                completionEpisodeTracker.abandonedSuggestionResolution
        )
    }

    private func publishPermissionState(force: Bool = false) {
        let state = currentPermissionState
        guard force || state != lastPermissionState else { return }
        lastPermissionState = state
        permissionObserver?(state)
    }

    private func openSettings(_ pane: PermissionState.SettingsPane) {
        let anchor: String
        switch pane {
        case .accessibility:
            accessibility.requestTrustPrompt()
            anchor = "Privacy_Accessibility"
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        }

        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        if !enabled {
            invalidatePendingCompletion()
            clearOCRContext()
            clearSuggestion(
                resolution:
                    completionEpisodeTracker.abandonedSuggestionResolution
            )
        } else {
            reconcile()
        }
    }

    func applicationPolicyDidChange() {
        invalidatePendingCompletion()
        clearOCRContext()
        clearSuggestion(
            resolution:
                completionEpisodeTracker.abandonedSuggestionResolution
        )
        reconcile()
    }

    func personalizationHistoryWillReset() {
        invalidatePendingCompletion()
        clearOCRContext()
        discardCompletionEpisodeAndSuggestion()
        writingHistoryWillReset()
        completionReversionTracker = CompletionReversionTracker()
    }

    func writingHistoryWillReset() {
        writingHistoryTracker = WritingHistoryTracker()
    }

    static func shouldDeferPendingOutcomeSettlementWhileClearing(
        pendingResolution: CompletionEpisodeResolution?,
        expectedField: CapturedFieldState?
    ) -> Bool {
        pendingResolution != nil && expectedField != nil
    }

    private func handle(_ mutation: ShadowTextBuffer.Mutation) {
        guard enabled, policyAllowsCurrentApplication() else {
            invalidatePendingCompletion()
            clearSuggestion(
                resolution:
                    completionEpisodeTracker.abandonedSuggestionResolution
            )
            return
        }
        if CompletionEpisodeLiveEditorPolicy.requiresVerification(
            activeInvocationID:
                completionEpisodeTracker.activeInvocationID
        ) {
            let liveEditorIdentifier =
                accessibility.snapshot()?.editorIdentifier
            guard
                CompletionEpisodeLiveEditorPolicy.allowsCapture(
                    activeEditorIdentifier: lastSnapshot?.editorIdentifier,
                    liveEditorIdentifier: liveEditorIdentifier
                )
            else {
                invalidatePendingCompletion()
                clearOCRContext()
                buffer.apply(.invalidate)
                deferCompletionEpisodeFinalization(
                    resolution:
                        completionEpisodeTracker
                        .abandonedSuggestionResolution,
                    requiresPostEventObservation: true
                )
                return
            }
        }
        if
            case .focusChange = mutation,
            pendingCompletionEpisodeResolution != nil
        {
            // Mouse-down and pass-through Tab arrive before the target app
            // changes focus. Take the last chance to observe a preceding edit
            // in its originating editor.
            reconcile()
        }
        let snapshotBeforeMutation = lastSnapshot
        let fieldBeforeMutation = currentCapturedField()
        let deletion = fieldBeforeMutation.flatMap {
            deletionResult(for: mutation, fieldBefore: $0)
        }
        if case .deleteBackward = mutation,
           let fieldBeforeMutation,
           let feedback = completionReversionTracker
            .recordBackwardDeletion(
                fieldBefore: fieldBeforeMutation,
                at: Date()
            ) {
            onCompletionFeedback(feedback)
        } else if case .insert = mutation {
            completionReversionTracker.cancel()
        }
        buffer.apply(
            mutation,
            replacingSelection:
                fieldBeforeMutation?.selection.length ?? 0 > 0
        )
        if writingHistoryCollectionIsEnabled(),
           case let .insert(text) = mutation,
           let fieldBeforeMutation {
            writingHistoryTracker.recordInsertion(
                text,
                provenance: .directlyTyped,
                fieldBefore: fieldBeforeMutation,
                fieldAfter: currentCapturedFieldFromBuffer(),
                at: Date()
            )
        } else if writingHistoryCollectionIsEnabled(),
                  let deletion {
            writingHistoryTracker.recordDeletion(
                deletion.deletedText,
                fieldBefore: deletion.fieldBefore,
                fieldAfter: deletion.fieldAfter,
                at: Date()
            )
        }

        if case let .insert(text) = mutation,
           var consumption = suggestionConsumption {
            let outcome = consumption.apply(insertedText: text)
            suggestionConsumption = consumption
            synchronizeCompletionEpisodeTypedThrough(from: consumption)

            switch outcome {
            case let .matched(remaining):
                suggestion = remaining
                overlay.consume(
                    matchedText: text,
                    remainingSuggestion: remaining
                )
                scheduleCaretReanchor(
                    expectedPrefix: buffer.prefix,
                    previousSnapshot: snapshotBeforeMutation
                )
                return
            case .awaitingStream:
                suggestion = nil
                overlay.hide()
                scheduleCaretReanchor(
                    expectedPrefix: buffer.prefix,
                    previousSnapshot: snapshotBeforeMutation
                )
                return
            case .waitingForWhitespace:
                recordTypedSuggestionMatch(from: consumption)
                deferCompletionEpisodeFinalization(
                    resolution:
                        completionEpisodeTracker
                        .completedSuggestionResolution
                        ?? .typedThrough
                )
                suggestionConsumption = .waitingForWhitespace()
                return
            case .triggerInference:
                recordTypedSuggestionMatch(from: consumption)
                deferCompletionEpisodeFinalization(
                    resolution:
                        completionEpisodeTracker
                        .completedSuggestionResolution
                        ?? .typedThrough
                )
                scheduleCompletion()
                return
            case .diverged:
                deferCompletionEpisodeFinalization(
                    resolution:
                        completionEpisodeTracker
                        .abandonedSuggestionResolution
                )
                scheduleCompletion()
                return
            }
        }

        if case .invalidate = mutation {
            invalidatePendingCompletion()
            deferCompletionEpisodeFinalization(
                resolution:
                    completionEpisodeTracker
                    .abandonedSuggestionResolution,
                requiresPostEventObservation: true
            )
            return
        }
        if case .focusChange = mutation {
            invalidatePendingCompletion()
            deferCompletionEpisodeFinalization(
                resolution:
                    completionEpisodeTracker
                    .abandonedSuggestionResolution,
                requiresPostEventObservation: true
            )
            return
        }

        invalidatePendingCompletion()
        if
            deletion != nil,
            completionEpisodeTracker.hasSuggestionRevisions
        {
            deferCompletionEpisodeFinalization(
                resolution:
                    completionEpisodeTracker
                    .abandonedSuggestionResolution
            )
            scheduleCompletion()
            return
        }
        if pendingCompletionEpisodeResolution != nil {
            if buffer.needsReconciliation {
                reconcile()
            } else {
                scheduleCompletion()
            }
            return
        }
        clearSuggestion(
            resolution:
                completionEpisodeTracker.abandonedSuggestionResolution
        )
        if buffer.needsReconciliation {
            reconcile()
        } else {
            scheduleCompletion()
        }
    }

    private func reconcile(captureFocusedEditor: Bool = false) {
        if
            let notBefore = invalidationReconciliationNotBefore,
            Date() < notBefore
        {
            scheduleInvalidationReconciliation()
            return
        }
        invalidationReconciliationNotBefore = nil
        guard enabled else {
            clearOCRContext()
            discardPendingCompletionEpisode()
            clearSuggestion(
                resolution:
                    completionEpisodeTracker.abandonedSuggestionResolution
            )
            return
        }
        guard policyAllowsCurrentApplication() else {
            invalidatePendingCompletion()
            clearOCRContext()
            discardPendingCompletionEpisode()
            clearSuggestion(
                resolution:
                    completionEpisodeTracker.abandonedSuggestionResolution
            )
            return
        }
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        if lastSnapshot?.processID != frontmostProcessID {
            lastOCRFocusedEditorIdentifier = nil
        }
        guard let snapshot = accessibility.snapshot() else {
            if completionEpisodeExpectedField != nil {
                if completionEpisodeObservationDeadlineExceeded {
                    buffer.apply(.invalidate)
                    discardPendingCompletionEpisode()
                    return
                }
                scheduleInvalidationReconciliation()
                return
            }
            if captureFocusedEditor {
                lastOCRFocusedEditorIdentifier = nil
            }
            consecutiveSnapshotFailures += 1
            let frontmostMatches = lastSnapshot.map {
                $0.processID == frontmostProcessID
            } ?? false
            if SnapshotFailurePolicy.shouldClearSuggestion(
                consecutiveFailures: consecutiveSnapshotFailures,
                frontmostProcessMatchesLastSnapshot: frontmostMatches
            ) {
                invalidatePendingCompletion()
                clearSuggestion(
                    resolution:
                        completionEpisodeTracker.abandonedSuggestionResolution
                )
            }
            return
        }
        let recoveringFromSnapshotFailure = consecutiveSnapshotFailures > 0
        consecutiveSnapshotFailures = 0
        recordApplicationObservation(from: snapshot)

        let previousSnapshot = lastSnapshot
        let focusChanged = previousSnapshot.map {
            $0.editorIdentifier != snapshot.editorIdentifier
        } ?? true
        let hadPendingAuthoritativeObservation =
            completionEpisodeExpectedField != nil
        let reconciliationDecision =
            CompletionEpisodeReconciliationPolicy.decision(
                previousEditorIdentifier:
                    previousSnapshot?.editorIdentifier,
                observedEditorIdentifier: snapshot.editorIdentifier,
                authoritativeBaselineField:
                    completionEpisodeAuthoritativeBaselineField,
                expectedField: completionEpisodeExpectedField,
                observedField: CapturedFieldState(
                    text: snapshot.fieldText,
                    selection: snapshot.selection
                ),
                requiresPostEventObservation:
                    completionEpisodeRequiresPostEventObservation,
                observationDeadlineExceeded:
                    completionEpisodeObservationDeadlineExceeded
            )
        let reconciliationSettlement =
            CompletionEpisodeReconciliationPolicy.settlement(
                for: reconciliationDecision
            )
        if reconciliationSettlement == .wait {
            scheduleInvalidationReconciliation()
            return
        }
        let authoritativeBaselineField =
            completionEpisodeAuthoritativeBaselineField
        completionEpisodeAuthoritativeBaselineField = nil
        completionEpisodeExpectedField = nil
        completionEpisodeRequiresPostEventObservation = false
        completionEpisodeObservationDeadline = nil
        switch reconciliationSettlement {
        case .discard:
            discardPendingCompletionEpisode()
        case .finalizeFromAuthoritativeBaseline:
            finalizePendingCompletionEpisodeIfNeeded(
                finalField: authoritativeBaselineField
            )
        case .finalizeFromObservedField:
            finalizePendingCompletionEpisodeIfNeeded(
                finalField: capturedField(from: snapshot)
            )
        case .wait:
            break
        }
        if focusChanged {
            invalidatePendingCompletion()
            clearSuggestion(
                resolution:
                    completionEpisodeTracker.abandonedSuggestionResolution
            )
        }
        updateTypographyScale(from: previousSnapshot, to: snapshot)
        if writingHistoryCollectionIsEnabled(),
           let completed = writingHistoryTracker.observe(
            field: CapturedFieldState(
                text: snapshot.fieldText,
                selection: snapshot.selection
            ),
            context: personalizationContext(for: snapshot),
            at: Date()
        ) {
            onWritingEpisode(completed)
        }
        lastSnapshot = snapshot
        if focusChanged {
            if cachedOCRContext?.editorIdentifier
                != snapshot.editorIdentifier {
                cachedOCRContext = nil
            }
        }
        if captureFocusedEditor {
            requestOCRContext(
                for: snapshot,
                editorText: snapshot.prefix + snapshot.suffix
            )
        }
        if !CompletionRequestPolicy.shouldRequest(prefix: snapshot.prefix) {
            _ = buffer.reconcile(
                prefix: snapshot.prefix,
                suffix: snapshot.suffix
            )
            invalidatePendingCompletion()
            clearSuggestion(
                resolution:
                    completionEpisodeTracker.abandonedSuggestionResolution
            )
            prepareOverlay(for: snapshot)
            return
        }
        prepareOverlay(for: snapshot)

        let neededReconciliation = buffer.needsReconciliation
        if focusChanged || neededReconciliation ||
            (
                (
                    buffer.prefix != snapshot.prefix
                        || buffer.suffix != snapshot.suffix
                )
                    && suggestion == nil
                    && (
                        suggestionConsumption == nil
                            || hadPendingAuthoritativeObservation
                    )
            ) ||
            recoveringFromSnapshotFailure {
            let contentChanged = buffer.reconcile(
                prefix: snapshot.prefix,
                suffix: snapshot.suffix
            )
            if neededReconciliation {
                clearSuggestion(
                    resolution:
                        completionEpisodeTracker.abandonedSuggestionResolution
                )
            }
            if CompletionRefreshPolicy.shouldScheduleAfterReconciliation(
                contentChanged: contentChanged,
                recoveringFromSnapshotFailure:
                    recoveringFromSnapshotFailure,
                hasVisibleSuggestion: suggestion != nil,
                isTrackingSuggestionConsumption:
                    suggestionConsumption != nil
            ) {
                scheduleCompletion()
            }
        }
        if hadPendingAuthoritativeObservation, !focusChanged {
            finalizePendingCompletionEpisodeIfNeeded()
        }
    }

    private func policyAllowsCurrentApplication() -> Bool {
        applicationCompletionsAreEnabled(
            accessibility.frontmostApplicationBundleIdentifier()
        )
    }

    private func recordApplicationObservation(from snapshot: EditorSnapshot) {
        guard
            let bundleIdentifier = snapshot.applicationBundleIdentifier,
            !bundleIdentifier.isEmpty
        else {
            return
        }
        onApplicationObserved(
            ApplicationObservation(
                bundleIdentifier: bundleIdentifier,
                displayName: snapshot.applicationName ?? bundleIdentifier,
                bundleURL: snapshot.applicationBundleURL,
                observedAt: Date(),
                isSecureField: false
            )
        )
    }

    private func scheduleCompletion() {
        guard
            policyAllowsCurrentApplication(),
            CompletionRequestPolicy.shouldRequest(prefix: buffer.prefix)
        else {
            invalidatePendingCompletion()
            clearSuggestion(
                resolution:
                    completionEpisodeTracker.abandonedSuggestionResolution
            )
            return
        }
        if let candidateSnapshot = lastSnapshot,
           let candidate = personalCompletion(
                buffer.prefix,
                personalizationContext(for: candidateSnapshot)
           ),
           candidate.confidence >= 0.7 {
            let expectedPrefix = buffer.prefix
            let expectedSuffix = buffer.suffix
            guard let snapshot = prepareCurrentPresentation(
                expectedPrefix: expectedPrefix,
                expectedSuffix: expectedSuffix
            ) else {
                return
            }
            guard
                let completion = personalCompletion(
                    expectedPrefix,
                    personalizationContext(for: snapshot)
                ),
                completion.confidence >= 0.7
            else {
                scheduleModelCompletion()
                return
            }
            debounceTask?.cancel()
            newestRequestID &+= 1
            preparedRequestSnapshot = nil
            finalizeCompletionEpisode(resolution: .superseded)
            suggestionAssociationToken = nil
            suggestion = completion.insertion
            suggestionConsumption = SuggestionConsumption(
                suggestion: completion.insertion,
                isFinal: true
            )
            typedSuggestionOrigin = currentCapturedField()
            if !overlay.show(completion.insertion) {
                suggestion = nil
                suggestionConsumption = nil
                typedSuggestionOrigin = nil
            }
            return
        }

        scheduleModelCompletion()
    }

    private func scheduleModelCompletion() {
        debounceTask?.cancel()
        newestRequestID &+= 1
        preparedRequestSnapshot = nil
        let requestID = newestRequestID
        let prefix = buffer.prefix
        let suffix = buffer.suffix
        let snapshot = lastSnapshot

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled, let self else { return }
            let learnedContext: PersonalizationPromptContext
            if let snapshot {
                learnedContext = await self.personalizationPromptContext(
                    prefix,
                    self.personalizationContext(for: snapshot)
                )
            } else {
                learnedContext = .empty
            }
            guard !Task.isCancelled else { return }
            guard
                let preparedSnapshot = self.prepareCurrentPresentation(
                    expectedPrefix: prefix,
                    expectedSuffix: suffix
                )
            else {
                return
            }
            self.preparedRequestSnapshot = (
                requestID,
                preparedSnapshot
            )
            self.finalizePendingCompletionEpisodeIfNeeded()
            let request = self.makeRequest(
                id: requestID,
                prefix: prefix,
                suffix: suffix,
                snapshot: preparedSnapshot,
                invocationField: CapturedFieldState(
                    text: preparedSnapshot.fieldText,
                    selection: preparedSnapshot.selection
                ),
                personalization: learnedContext
            )
            await self.requestPump.submit(request)
        }
    }

    private func prepareCurrentPresentation(
        expectedPrefix: String,
        expectedSuffix: String
    ) -> EditorSnapshot? {
        guard policyAllowsCurrentApplication() else {
            invalidatePendingCompletion()
            discardPendingCompletionEpisode()
            clearSuggestion(
                resolution:
                    completionEpisodeTracker.abandonedSuggestionResolution
            )
            return nil
        }
        let liveSnapshot = accessibility.snapshot()
        if
            completionEpisodeExpectedField != nil,
            liveSnapshot == nil
        {
            if completionEpisodeObservationDeadlineExceeded {
                buffer.apply(.invalidate)
                discardPendingCompletionEpisode()
            }
            return nil
        }
        guard let snapshot = liveSnapshot ?? lastSnapshot else {
            return nil
        }

        let previousSnapshot = lastSnapshot
        let focusChanged = previousSnapshot.map {
            $0.editorIdentifier != snapshot.editorIdentifier
        } ?? true
        let reconciliationDecision =
            CompletionEpisodeReconciliationPolicy.decision(
                previousEditorIdentifier:
                    previousSnapshot?.editorIdentifier,
                observedEditorIdentifier: snapshot.editorIdentifier,
                authoritativeBaselineField:
                    completionEpisodeAuthoritativeBaselineField,
                expectedField: completionEpisodeExpectedField,
                observedField: CapturedFieldState(
                    text: snapshot.fieldText,
                    selection: snapshot.selection
                ),
                requiresPostEventObservation:
                    completionEpisodeRequiresPostEventObservation,
                observationDeadlineExceeded:
                    completionEpisodeObservationDeadlineExceeded
            )
        let reconciliationSettlement =
            CompletionEpisodeReconciliationPolicy.settlement(
                for: reconciliationDecision
            )
        if reconciliationSettlement == .wait {
            scheduleModelCompletion()
            return nil
        }
        let authoritativeBaselineField =
            completionEpisodeAuthoritativeBaselineField
        completionEpisodeAuthoritativeBaselineField = nil
        completionEpisodeExpectedField = nil
        completionEpisodeRequiresPostEventObservation = false
        completionEpisodeObservationDeadline = nil
        switch reconciliationSettlement {
        case .discard:
            discardPendingCompletionEpisode()
        case .finalizeFromAuthoritativeBaseline:
            finalizePendingCompletionEpisodeIfNeeded(
                finalField: authoritativeBaselineField
            )
        case .finalizeFromObservedField:
            finalizePendingCompletionEpisodeIfNeeded(
                finalField: capturedField(from: snapshot)
            )
        case .wait:
            break
        }
        if focusChanged {
            finalizeCompletionEpisode(
                resolution:
                    completionEpisodeTracker
                    .abandonedSuggestionResolution
            )
            suggestion = nil
            suggestionConsumption = nil
            suggestionAssociationToken = nil
            overlay.hide()
        }
        updateTypographyScale(from: previousSnapshot, to: snapshot)
        lastSnapshot = snapshot
        prepareOverlay(for: snapshot)

        guard CompletionPresentationPolicy.isCurrent(
            expectedPrefix: expectedPrefix,
            expectedSuffix: expectedSuffix,
            observedPrefix: snapshot.prefix,
            observedSuffix: snapshot.suffix
        ) else {
            let contentChanged = buffer.reconcile(
                prefix: snapshot.prefix,
                suffix: snapshot.suffix
            )
            if contentChanged {
                scheduleCompletion()
            }
            return nil
        }

        return snapshot
    }

    private func makeRequest(
        id: UInt64,
        prefix: String,
        suffix: String,
        snapshot: EditorSnapshot?,
        invocationField: CapturedFieldState?,
        personalization: PersonalizationPromptContext = .empty,
        detectPartialWord: Bool = true
    ) -> CompletionRequest {
        let fragment = detectPartialWord
            ? incompleteWordFragment(in: prefix)
            : nil
        let configuration = promptConfiguration()
        let includeFrecent = configuration.voice.includeInputHistory
        let includeRelevant =
            configuration.voice.includeRelevantInputHistory
        let includeVoiceAssessment =
            configuration.voice.includePeriodicAssessments
        let invocationSeed =
            completionEpisodeCollectionIsEnabled()
            ? snapshot.flatMap { snapshot in
                invocationField.map { field in
                    CompletionInvocationSeed(
                        id: UUID(),
                        field: field,
                        context: personalizationContext(for: snapshot),
                        sourceEventIDs: personalization.sourceEventIDs(
                            includeFrecent: includeFrecent,
                            includeRelevant: includeRelevant,
                            includeVoiceAssessment: includeVoiceAssessment
                        ),
                        sourceContexts: personalization.sourceContexts(
                            includeFrecent: includeFrecent,
                            includeRelevant: includeRelevant,
                            includeVoiceAssessment: includeVoiceAssessment
                        ),
                        collectionGeneration:
                            completionEpisodeCollectionGeneration(),
                        startedAt: Date()
                    )
                }
            }
            : nil
        return CompletionRequest(
            id: id,
            prefix: prefix,
            suffix: suffix,
            context: CompletionContext(
                applicationName: snapshot?.applicationName,
                website: nil,
                inputKind: snapshot?.inputKind,
                ocrContent: ocrContent(for: snapshot),
                clipboardContent: clipboardContent(
                    configuration: configuration
                ),
                inputHistory: personalization.frecentExamples,
                relevantInputHistory: personalization.relevantExamples,
                voiceAssessment: personalization.voiceAssessment
            ),
            promptConfiguration: configuration,
            partialWordFragment: fragment,
            partialWordCandidates: fragment.map {
                completionCandidates(for: $0)
            } ?? [],
            invocationSeed: invocationSeed
        )
    }

    private func clipboardContent(
        configuration: PromptConfiguration
    ) -> String? {
        guard configuration.context.includeClipboard else { return nil }
        guard let value = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(2_000))
    }

    private func ocrContent(for snapshot: EditorSnapshot?) -> String? {
        guard
            promptConfiguration().context.includeOCR,
            CGPreflightScreenCaptureAccess(),
            let snapshot,
            cachedOCRContext?.editorIdentifier == snapshot.editorIdentifier
        else {
            return nil
        }
        return cachedOCRContext?.text
    }

    private func requestOCRContext(
        for snapshot: EditorSnapshot,
        editorText: String
    ) {
        let configuration = promptConfiguration()
        guard configuration.context.includeOCR else {
            clearOCRContext()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            ocrLogger.error(
                "OCR is enabled but Screen Recording access is unavailable"
            )
            clearOCRContext()
            return
        }
        guard
            policyAllowsCurrentApplication(),
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processID
        else {
            clearOCRContext()
            return
        }
        guard OCRCapturePolicy.shouldCaptureFocusedEditor(
            editorIdentifier: snapshot.editorIdentifier,
            lastFocusedEditorIdentifier:
                lastOCRFocusedEditorIdentifier,
            inFlightEditorIdentifier: ocrCaptureEditorIdentifier
        ) else {
            return
        }

        lastOCRFocusedEditorIdentifier = snapshot.editorIdentifier
        ocrCaptureTask?.cancel()
        ocrCaptureRequestID &+= 1
        let requestID = ocrCaptureRequestID
        ocrCaptureEditorIdentifier = snapshot.editorIdentifier
        let target = OCRCaptureTarget(
            editorIdentifier: snapshot.editorIdentifier,
            processID: snapshot.processID,
            caretRect: snapshot.caretRect,
            focusedWindowFrame: snapshot.focusedWindowFrame,
            editorText: editorText
        )
        ocrCaptureTask = Task { [weak self, ocrCapture] in
            let text: String?
            do {
                text = try await ocrCapture.recognizeText(for: target)
            } catch is CancellationError {
                return
            } catch {
                self?.ocrLogger.error(
                    "Focused-window OCR failed: \(error.localizedDescription)"
                )
                text = nil
            }
            guard !Task.isCancelled, let self else { return }
            guard
                self.ocrCaptureRequestID == requestID,
                self.lastSnapshot?.editorIdentifier
                    == target.editorIdentifier,
                NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == target.processID,
                self.promptConfiguration().context.includeOCR,
                self.policyAllowsCurrentApplication()
            else {
                return
            }
            self.ocrCaptureTask = nil
            self.ocrCaptureEditorIdentifier = nil
            self.cachedOCRContext = CachedOCRContext(
                editorIdentifier: target.editorIdentifier,
                text: text
            )
            self.ocrLogger.notice(
                "Focused-window OCR cached \(text?.count ?? 0) characters"
            )

            if
                self.suggestion == nil,
                self.suggestionConsumption == nil,
                CompletionRequestPolicy.shouldRequest(
                    prefix: self.buffer.prefix
                )
            {
                self.scheduleCompletion()
            }
        }
    }

    private func clearOCRContext() {
        ocrCaptureTask?.cancel()
        ocrCaptureTask = nil
        ocrCaptureEditorIdentifier = nil
        ocrCaptureRequestID &+= 1
        cachedOCRContext = nil
        lastOCRFocusedEditorIdentifier = nil
    }

    private func incompleteWordFragment(in prefix: String) -> String? {
        PartialWordCompletion.fragment(in: prefix)
    }

    private func completionCandidates(for fragment: String) -> [String] {
        let range = NSRange(
            location: 0,
            length: (fragment as NSString).length
        )
        let completions = NSSpellChecker.shared.completions(
            forPartialWordRange: range,
            in: fragment,
            language: nil,
            inSpellDocumentWithTag: 0
        ) ?? []
        return Array(
            completions.lazy.filter {
                $0.count > fragment.count
                    && $0.lowercased().hasPrefix(fragment.lowercased())
            }.prefix(24)
        )
    }

    private func receive(_ response: CompletionResponse) {
        guard
            enabled,
            policyAllowsCurrentApplication(),
            CompletionRequestPolicy.shouldRequest(prefix: buffer.prefix),
            response.requestID == newestRequestID,
            let preparedRequestSnapshot,
            preparedRequestSnapshot.requestID == response.requestID,
            lastSnapshot?.editorIdentifier
                == preparedRequestSnapshot.snapshot.editorIdentifier
        else {
            return
        }

        if
            let invocation = response.invocation,
            completionEpisodeTracker.activeInvocationID != invocation.id
        {
            finalizeCompletionEpisode(resolution: .superseded)
            completionEpisodeTracker.begin(invocation)
            activeCompletionEpisodeToken = .model(response.requestID)
        }
        if response.didFail {
            completionEpisodeTracker.recordGenerationFailure()
        }

        guard let text = response.text, !text.isEmpty else {
            if response.isFinal, response.invocation != nil {
                let partialSuggestionRemains =
                    suggestionAssociationToken == .model(response.requestID)
                    && suggestionConsumption != nil
                completionEpisodeTracker.recordGenerationFailure()
                if partialSuggestionRemains,
                   var consumption = suggestionConsumption {
                    let outcome = consumption.finishStreaming()
                    suggestionConsumption = consumption
                    synchronizeCompletionEpisodeTypedThrough(
                        from: consumption
                    )
                    presentStreamingOutcome(outcome)
                } else {
                    finalizeCompletionEpisode(resolution: .failed)
                }
            }
            return
        }
        let outcome: SuggestionConsumption.Outcome
        if
            suggestionAssociationToken == .model(response.requestID),
            var consumption = suggestionConsumption
        {
            outcome = consumption.update(
                suggestion: text,
                isFinal: response.isFinal
            )
            suggestionConsumption = consumption
            synchronizeCompletionEpisodeTypedThrough(from: consumption)
        } else {
            suggestionAssociationToken = .model(response.requestID)
            typedSuggestionOrigin = CapturedFieldState(
                text: preparedRequestSnapshot.snapshot.fieldText,
                selection: preparedRequestSnapshot.snapshot.selection
            )
            suggestionConsumption = SuggestionConsumption(
                suggestion: text,
                isFinal: response.isFinal
            )
            outcome = .matched(remaining: text)
        }
        if case let .matched(remaining) = outcome {
            guard presentStreamingSuggestion(remaining) else { return }
            completionEpisodeTracker.observeSuggestion(
                text,
                isFinal: response.isFinal,
                at: Date()
            )
        } else {
            if response.isFinal {
                completionEpisodeTracker.markSuggestionFinalIfObserved(
                    text,
                    at: Date()
                )
            }
            presentStreamingOutcome(outcome)
        }
    }

    private func presentStreamingOutcome(
        _ outcome: SuggestionConsumption.Outcome
    ) {
        switch outcome {
        case let .matched(remaining):
            _ = presentStreamingSuggestion(remaining)
        case .awaitingStream:
            suggestion = nil
            overlay.hide()
        case .waitingForWhitespace:
            if let suggestionConsumption {
                recordTypedSuggestionMatch(from: suggestionConsumption)
            }
            deferCompletionEpisodeFinalization(
                resolution:
                    completionEpisodeTracker
                    .completedSuggestionResolution
                    ?? .typedThrough
            )
            suggestion = nil
            suggestionAssociationToken = nil
            typedSuggestionOrigin = nil
            overlay.hide()
            suggestionConsumption = .waitingForWhitespace()
        case .triggerInference:
            if let suggestionConsumption {
                recordTypedSuggestionMatch(from: suggestionConsumption)
            }
            deferCompletionEpisodeFinalization(
                resolution:
                    completionEpisodeTracker
                    .completedSuggestionResolution
                    ?? .typedThrough
            )
            scheduleCompletion()
        case .diverged:
            deferCompletionEpisodeFinalization(
                resolution:
                    completionEpisodeTracker
                    .abandonedSuggestionResolution
            )
            scheduleCompletion()
        }
    }

    @discardableResult
    private func presentStreamingSuggestion(_ remaining: String) -> Bool {
        suggestion = remaining
        guard overlay.show(remaining) else {
            if completionEpisodeTracker.hasSuggestionRevisions {
                finalizeCompletionEpisode(
                    resolution:
                        completionEpisodeTracker
                        .abandonedSuggestionResolution
                )
            } else {
                completionEpisodeTracker.discard()
                activeCompletionEpisodeToken = nil
            }
            if case .model = suggestionAssociationToken {
                invalidatePendingCompletion()
            }
            suggestion = nil
            suggestionConsumption = nil
            suggestionAssociationToken = nil
            typedSuggestionOrigin = nil
            return false
        }
        return true
    }

    private func prepareOverlay(for snapshot: EditorSnapshot) {
        overlay.prepare(
            at: snapshot.caretRect,
            typography: snapshot.typography.scaled(
                by: typographyCalibrationByProcess[
                    snapshot.processID
                ]?.scale ?? 1
            ),
            foregroundColor: snapshot.foregroundColor,
            backgroundColor: snapshot.backgroundColor,
            leadingWhitespaceCompensation: CGFloat(
                (
                    whitespaceCalibrationByEditor[snapshot.editorIdentifier]
                        ?? LeadingWhitespaceCalibration()
                ).points(
                    for: " ",
                    caretHeight: snapshot.caretRect.height,
                    isWebBacked: snapshot.isWebBacked
                )
            ),
            useNativeTextLayoutMetrics: !snapshot.isWebBacked
        )
    }

    private func updateTypographyScale(
        from previous: EditorSnapshot?,
        to current: EditorSnapshot
    ) {
        guard
            let previous,
            previous.processID == current.processID,
            current.prefix.hasPrefix(previous.prefix)
        else {
            return
        }

        let inserted = String(
            current.prefix.dropFirst(previous.prefix.count)
        )
        guard !inserted.isEmpty else { return }

        let pointSize = CGFloat(current.typography.pointSize)
        let font = current.typography.fontName.flatMap {
            NSFont(name: $0, size: pointSize)
        } ?? .systemFont(ofSize: pointSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let context = String(previous.prefix.suffix(1))
        let contextWidth = (context as NSString).size(
            withAttributes: attributes
        ).width
        let combinedWidth = ((context + inserted) as NSString).size(
            withAttributes: attributes
        ).width
        let expectedAdvance = combinedWidth - contextWidth

        guard let scale = TypographyScaleEstimator.estimate(
            previousPrefix: previous.prefix,
            currentPrefix: current.prefix,
            previousCaretX: previous.caretRect.minX,
            currentCaretX: current.caretRect.minX,
            previousCaretY: previous.caretRect.minY,
            currentCaretY: current.caretRect.minY,
            lineHeight: current.caretRect.height,
            expectedAdvance: expectedAdvance
        ) else {
            return
        }
        var calibration = typographyCalibrationByProcess[
            current.processID
        ] ?? TypographyScaleCalibration()
        calibration.consider(
            candidateScale: scale,
            caretHeight: current.caretRect.height,
            sampleLength: inserted.count
        )
        typographyCalibrationByProcess[current.processID] = calibration
    }

    private func acceptSuggestion(
        scope: SuggestionAcceptance.Scope
    ) -> Bool {
        guard
            enabled,
            policyAllowsCurrentApplication(),
            let suggestion,
            !suggestion.isEmpty
        else {
            return false
        }
        if CompletionEpisodeLiveEditorPolicy.requiresVerification(
            activeInvocationID:
                completionEpisodeTracker.activeInvocationID
        ) {
            let liveEditorIdentifier =
                accessibility.snapshot()?.editorIdentifier
            guard
                CompletionEpisodeLiveEditorPolicy.allowsCapture(
                    activeEditorIdentifier:
                        lastSnapshot?.editorIdentifier,
                    liveEditorIdentifier: liveEditorIdentifier
                )
            else {
                invalidatePendingCompletion()
                clearOCRContext()
                discardCompletionEpisodeAndSuggestion()
                buffer.apply(.invalidate)
                return false
            }
        }
        caretReanchorTask?.cancel()
        let acceptance = SuggestionAcceptance.slice(
            in: suggestion,
            scope: scope
        )
        guard !acceptance.accepted.isEmpty else { return false }
        let linkedEpisodeID: UUID?
        if
            let activeCompletionEpisodeToken,
            activeCompletionEpisodeToken == suggestionAssociationToken
        {
            linkedEpisodeID = completionEpisodeTracker.activeInvocationID
            completionEpisodeTracker.recordAcceptance(
                acceptance.accepted,
                scope: scope,
                at: Date()
            )
        } else {
            linkedEpisodeID = nil
        }
        typedSuggestionOrigin = nil
        let snapshotBeforeAcceptance = accessibility.snapshot() ?? lastSnapshot
        let fieldBeforeAcceptance = currentCapturedField()
        let personalizationCapture = snapshotBeforeAcceptance.flatMap {
            PersonalizationCapture.acceptedSuggestion(
                fieldText: $0.fieldText,
                selection: $0.selection,
                insertion: acceptance.accepted,
                acceptanceScope: scope,
                completionEpisodeID: linkedEpisodeID,
                context: personalizationContext(for: $0)
            )
        }
        if writingHistoryCollectionIsEnabled(),
           let fieldBefore = fieldBeforeAcceptance {
            let insertedUTF16Count = acceptance.accepted.utf16.count
            let afterText = replacingSelection(
                in: fieldBefore.text,
                selection: fieldBefore.selection,
                with: acceptance.accepted
            )
            writingHistoryTracker.recordInsertion(
                acceptance.accepted,
                provenance: .acceptedSuggestion,
                fieldBefore: fieldBefore,
                fieldAfter: CapturedFieldState(
                    text: afterText,
                    selection: UTF16Selection(
                        location:
                            fieldBefore.selection.location
                            + insertedUTF16Count,
                        length: 0
                    )
                ),
                at: Date()
            )
        }
        inputMonitor?.insertText(acceptance.accepted)
        buffer.apply(.insert(acceptance.accepted))
        onSuggestionAccepted(acceptance.accepted)
        if let personalizationCapture {
            onPersonalizationCapture(personalizationCapture)
            completionReversionTracker.register(
                personalizationCapture
            )
        }

        var consumption = suggestionConsumption
            ?? SuggestionConsumption(suggestion: suggestion)
        let outcome = consumption.apply(
            insertedText: acceptance.accepted
        )
        let streamHasFinished = consumption.hasFinishedStreaming
        suggestionConsumption = consumption

        switch outcome {
        case let .matched(remaining):
            self.suggestion = remaining
            overlay.consume(
                matchedText: acceptance.accepted,
                remainingSuggestion: remaining
            )
            scheduleCaretReanchor(
                expectedPrefix: buffer.prefix,
                previousSnapshot: snapshotBeforeAcceptance
            )
            if streamHasFinished {
                startRefillIfNeeded(
                    remainingSuggestion: remaining
                )
            }
        case .awaitingStream:
            self.suggestion = nil
            overlay.hide()
            scheduleCaretReanchor(
                expectedPrefix: buffer.prefix,
                previousSnapshot: snapshotBeforeAcceptance
            )
        case .waitingForWhitespace:
            deferCompletionEpisodeFinalization(
                resolution:
                    completionEpisodeTracker
                    .completedSuggestionResolution
                    ?? .accepted
            )
            if !promoteOrAwaitRefill(for: buffer.prefix) {
                scheduleCompletion()
            }
        case .triggerInference, .diverged:
            deferCompletionEpisodeFinalization(
                resolution: .partiallyAccepted
            )
            scheduleCompletion()
        }
        scheduleWhitespaceCalibration(
            suggestion: acceptance.accepted,
            snapshotBeforeAcceptance: snapshotBeforeAcceptance
        )
        return true
    }

    private func startRefillIfNeeded(remainingSuggestion: String) {
        guard
            SuggestionRefillPolicy.shouldPrefetch(
                remainingSuggestion: remainingSuggestion
            ),
            let snapshot = lastSnapshot
        else {
            return
        }

        let key = RefillKey(
            prefix: buffer.prefix + remainingSuggestion,
            suffix: buffer.suffix,
            editorIdentifier: snapshot.editorIdentifier
        )
        guard refillKey != key else { return }

        cancelRefill()
        refillRequestID &+= 1
        let requestID = refillRequestID
        refillKey = key
        refillTask = Task { [weak self, provider] in
            guard let self else { return }
            let learnedContext = await self.personalizationPromptContext(
                key.prefix,
                self.personalizationContext(for: snapshot)
            )
            guard !Task.isCancelled else { return }
            let request = self.makeRequest(
                id: requestID,
                prefix: key.prefix,
                suffix: key.suffix,
                snapshot: snapshot,
                invocationField: CapturedFieldState(
                    text: key.prefix + key.suffix,
                    selection: UTF16Selection(
                        location: key.prefix.utf16.count,
                        length: 0
                    )
                ),
                personalization: learnedContext,
                detectPartialWord: false
            )
            let response = await provider.complete(request)
            guard !Task.isCancelled else { return }
            self.receiveRefill(response, for: key)
        }
    }

    private func personalizationContext(
        for snapshot: EditorSnapshot
    ) -> PersonalizationContext {
        PersonalizationContext(
            applicationBundleIdentifier:
                snapshot.applicationBundleIdentifier,
            website: nil,
            inputKind: snapshot.inputKind,
            detectedLanguage: nil,
            editorIdentifier: snapshot.editorIdentifier
        )
    }

    private func recordTypedSuggestionMatch(
        from consumption: SuggestionConsumption
    ) {
        guard
            let origin = typedSuggestionOrigin,
            let snapshot = lastSnapshot,
            let feedback = PersonalizationCapture.typedSuggestionMatch(
                fieldText: origin.text,
                selection: origin.selection,
                suggestionText: consumption.consumedSuggestionText,
                context: personalizationContext(for: snapshot)
            )
        else {
            return
        }
        typedSuggestionOrigin = nil
        onCompletionFeedback(feedback)
    }

    private func currentCapturedField() -> CapturedFieldState? {
        if let lastSnapshot {
            return buffer.capturedField(
                authoritativeField: CapturedFieldState(
                    text: lastSnapshot.fieldText,
                    selection: lastSnapshot.selection
                ),
                authoritativePrefix: lastSnapshot.prefix,
                authoritativeSuffix: lastSnapshot.suffix
            )
        }
        return currentCapturedFieldFromBuffer()
    }

    private func currentCapturedFieldFromBuffer() -> CapturedFieldState {
        CapturedFieldState(
            text: buffer.prefix + buffer.suffix,
            selection: UTF16Selection(
                location: buffer.prefix.utf16.count,
                length: 0
            )
        )
    }

    private func replacingSelection(
        in text: String,
        selection: UTF16Selection,
        with insertion: String
    ) -> String {
        guard selection.isValid(for: text) else {
            return text + insertion
        }
        let utf16 = text.utf16
        let start = utf16.index(
            utf16.startIndex,
            offsetBy: selection.location
        )
        let end = utf16.index(start, offsetBy: selection.length)
        return String(decoding: utf16[..<start], as: UTF16.self)
            + insertion
            + String(decoding: utf16[end...], as: UTF16.self)
    }

    private func deletionResult(
        for mutation: ShadowTextBuffer.Mutation,
        fieldBefore: CapturedFieldState
    ) -> (
        deletedText: String,
        fieldBefore: CapturedFieldState,
        fieldAfter: CapturedFieldState
    )? {
        let selection: UTF16Selection
        if fieldBefore.selection.length > 0 {
            selection = fieldBefore.selection
        } else {
            switch mutation {
            case .deleteBackward:
                guard let resolved = fieldBefore.selection
                    .selectionForDeletion(
                        in: fieldBefore.text,
                        direction: .backward
                    )
                else { return nil }
                selection = resolved
            case .deleteForward:
                guard let resolved = fieldBefore.selection
                    .selectionForDeletion(
                        in: fieldBefore.text,
                        direction: .forward
                    )
                else { return nil }
                selection = resolved
            case .insert, .invalidate, .focusChange:
                return nil
            }
        }
        let nsText = fieldBefore.text as NSString
        let range = NSRange(
            location: selection.location,
            length: selection.length
        )
        guard NSMaxRange(range) <= nsText.length else { return nil }
        let deletedText = nsText.substring(with: range)
        let afterText = nsText.replacingCharacters(
            in: range,
            with: ""
        )
        return (
            deletedText,
            fieldBefore,
            CapturedFieldState(
                text: afterText,
                selection: UTF16Selection(
                    location: selection.location,
                    length: 0
                )
            )
        )
    }

    private func finalizeIdleWritingEpisode() {
        guard writingHistoryCollectionIsEnabled() else {
            writingHistoryTracker = WritingHistoryTracker()
            return
        }
        if let completed = writingHistoryTracker.finalizeIfIdle(
            at: Date(),
            timeout: 2
        ) {
            onWritingEpisode(completed)
        }
    }

    private func finalizeSubmittedWritingEpisode() -> Bool {
        let submissionKinds: Set<String> = [
            "comment",
            "email",
            "message",
            "post",
            "reply",
            "search"
        ]
        guard
            let inputKind = lastSnapshot?.inputKind,
            submissionKinds.contains(inputKind)
        else {
            return false
        }
        if writingHistoryCollectionIsEnabled(),
           let completed = writingHistoryTracker.finalize(
            boundary: .submitted,
            at: Date()
        ) {
            onWritingEpisode(completed)
        }
        return true
    }

    private func receiveRefill(
        _ response: CompletionResponse,
        for key: RefillKey
    ) {
        guard refillKey == key else { return }
        refillTask = nil

        guard let text = response.text, !text.isEmpty else {
            let shouldSchedule = awaitedRefillKey == key
                && buffer.prefix == key.prefix
            refillKey = nil
            awaitedRefillKey = nil
            prefetchedRefill = nil
            if shouldSchedule {
                scheduleCompletion()
            }
            return
        }

        prefetchedRefill = (
            key,
            text,
            response.requestID,
            response.invocation,
            response.didFail
        )
        if
            awaitedRefillKey == key,
            buffer.prefix == key.prefix,
            lastSnapshot?.editorIdentifier == key.editorIdentifier
        {
            presentRefill(
                text,
                requestID: response.requestID,
                invocation: response.invocation,
                didFail: response.didFail,
                for: key
            )
        }
    }

    private func promoteOrAwaitRefill(for prefix: String) -> Bool {
        guard
            let key = refillKey,
            key.prefix == prefix,
            key.suffix == buffer.suffix,
            key.editorIdentifier == lastSnapshot?.editorIdentifier
        else {
            cancelRefill()
            return false
        }

        awaitedRefillKey = key
        if let prefetchedRefill, prefetchedRefill.key == key {
            presentRefill(
                prefetchedRefill.text,
                requestID: prefetchedRefill.requestID,
                invocation: prefetchedRefill.invocation,
                didFail: prefetchedRefill.didFail,
                for: key
            )
        }
        return true
    }

    private func presentRefill(
        _ text: String,
        requestID: UInt64,
        invocation: CompletionInvocationCapture?,
        didFail: Bool,
        for key: RefillKey
    ) {
        guard
            buffer.prefix == key.prefix,
            buffer.suffix == key.suffix,
            lastSnapshot?.editorIdentifier == key.editorIdentifier
        else {
            return
        }

        refillTask?.cancel()
        refillTask = nil
        refillKey = nil
        awaitedRefillKey = nil
        prefetchedRefill = nil
        guard
            let snapshot = accessibility.snapshot(),
            snapshot.prefix == key.prefix,
            snapshot.suffix == key.suffix,
            snapshot.editorIdentifier == key.editorIdentifier
        else {
            scheduleCompletion()
            return
        }
        updateTypographyScale(from: lastSnapshot, to: snapshot)
        lastSnapshot = snapshot
        prepareOverlay(for: snapshot)
        guard overlay.show(text) else {
            scheduleCompletion()
            return
        }

        if let invocation {
            finalizeCompletionEpisode(resolution: .superseded)
            completionEpisodeTracker.begin(invocation)
            completionEpisodeTracker.observeSuggestion(
                text,
                isFinal: true,
                at: Date()
            )
            if didFail {
                completionEpisodeTracker.recordGenerationFailure()
            }
            activeCompletionEpisodeToken = .refill(requestID)
        }
        suggestion = text
        suggestionConsumption = SuggestionConsumption(suggestion: text)
        suggestionAssociationToken = .refill(requestID)
        typedSuggestionOrigin = nil
    }

    private func scheduleCaretReanchor(
        expectedPrefix: String,
        previousSnapshot: EditorSnapshot?
    ) {
        caretReanchorTask?.cancel()
        guard let editorIdentifier = lastSnapshot?.editorIdentifier else {
            return
        }

        caretReanchorTask = Task { [weak self] in
            for delay in [12, 24, 48, 80, 120, 180, 260, 400, 500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                guard
                    self.buffer.prefix == expectedPrefix
                else {
                    return
                }
                guard
                    let snapshot = self.accessibility.snapshot(),
                    snapshot.prefix == expectedPrefix,
                    snapshot.editorIdentifier == editorIdentifier,
                    CaretReanchorPolicy.isReady(
                        previousPrefix: previousSnapshot?.prefix ?? "",
                        expectedPrefix: expectedPrefix,
                        observedPrefix: snapshot.prefix,
                        previousCaretRect: previousSnapshot?.caretRect,
                        observedCaretRect: snapshot.caretRect
                    )
                else {
                    continue
                }

                self.updateTypographyScale(
                    from: self.lastSnapshot,
                    to: snapshot
                )
                self.lastSnapshot = snapshot
                self.prepareOverlay(for: snapshot)
                if let suggestion = self.suggestion,
                   !suggestion.isEmpty {
                    self.overlay.show(suggestion)
                } else {
                    self.overlay.hide()
                }
                return
            }
        }
    }

    private func cancelRefill() {
        refillTask?.cancel()
        refillTask = nil
        refillKey = nil
        awaitedRefillKey = nil
        prefetchedRefill = nil
    }

    private func scheduleWhitespaceCalibration(
        suggestion: String,
        snapshotBeforeAcceptance: EditorSnapshot?
    ) {
        whitespaceCalibrationTask?.cancel()
        guard
            let before = snapshotBeforeAcceptance,
            before.isWebBacked,
            suggestion.first == " "
        else {
            return
        }

        whitespaceCalibrationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.calibrateLeadingWhitespace(
                suggestion: suggestion,
                before: before
            )
        }
    }

    private func calibrateLeadingWhitespace(
        suggestion: String,
        before: EditorSnapshot
    ) {
        guard
            let after = accessibility.snapshot(),
            after.processID == before.processID,
            after.editorIdentifier == before.editorIdentifier,
            after.prefix == before.prefix + suggestion,
            abs(after.caretRect.minY - before.caretRect.minY)
                <= max(2, after.caretRect.height * 0.35)
        else {
            return
        }

        let typography = before.typography.scaled(
            by: typographyCalibrationByProcess[before.processID]?.scale ?? 1
        )
        let renderedAdvance = textAdvance(
            suggestion,
            after: String(before.prefix.suffix(1)),
            typography: typography
        )
        let observedAdvance = after.caretRect.minX - before.caretRect.minX
        let leadingSpaceCount = suggestion.prefix { $0 == " " }.count
        var calibration = whitespaceCalibrationByEditor[
            before.editorIdentifier
        ] ?? LeadingWhitespaceCalibration()
        calibration.consider(
            observedAdvance: observedAdvance,
            renderedAdvance: renderedAdvance,
            caretHeight: before.caretRect.height,
            leadingSpaceCount: leadingSpaceCount
        )
        whitespaceCalibrationByEditor[before.editorIdentifier] = calibration
        lastSnapshot = after
    }

    private func textAdvance(
        _ text: String,
        after context: String,
        typography: EditorTypography
    ) -> Double {
        let pointSize = CGFloat(typography.pointSize)
        let font = typography.fontName.flatMap {
            NSFont(name: $0, size: pointSize)
        } ?? .systemFont(ofSize: pointSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let contextWidth = (context as NSString).size(
            withAttributes: attributes
        ).width
        let combinedWidth = ((context + text) as NSString).size(
            withAttributes: attributes
        ).width
        return combinedWidth - contextWidth
    }

    private func synchronizeCompletionEpisodeTypedThrough(
        from consumption: SuggestionConsumption
    ) {
        guard
            let activeCompletionEpisodeToken,
            activeCompletionEpisodeToken == suggestionAssociationToken
        else {
            return
        }
        completionEpisodeTracker.synchronizeTypedThrough(
            consumedSuggestionText: consumption.consumedSuggestionText
        )
    }

    private func finalizeCompletionEpisode(
        resolution: CompletionEpisodeResolution,
        finalField authoritativeFinalField: CapturedFieldState? = nil
    ) {
        guard completionEpisodeTracker.activeInvocationID != nil else {
            resetCompletionEpisodeFinalizationState()
            return
        }
        let effectiveResolution =
            pendingCompletionEpisodeResolution ?? resolution
        resetCompletionEpisodeFinalizationState()
        guard
            let finalField =
                authoritativeFinalField
                ?? currentCapturedField()
                ?? completionEpisodeTracker.activeInitialField,
            let episode = completionEpisodeTracker.finalize(
                resolution: effectiveResolution,
                finalField: finalField,
                at: Date()
            )
        else {
            completionEpisodeTracker.discard()
            activeCompletionEpisodeToken = nil
            return
        }
        activeCompletionEpisodeToken = nil
        onCompletionEpisode(episode)
    }

    private func resetCompletionEpisodeFinalizationState() {
        pendingCompletionEpisodeResolution = nil
        invalidationReconciliationNotBefore = nil
        completionEpisodeAuthoritativeBaselineField = nil
        completionEpisodeExpectedField = nil
        completionEpisodeRequiresPostEventObservation = false
        completionEpisodeObservationDeadline = nil
        invalidationReconciliationGeneration &+= 1
        activeCompletionEpisodeToken = nil
    }

    private func discardCompletionEpisodeAndSuggestion() {
        completionEpisodeTracker.discard()
        resetCompletionEpisodeFinalizationState()
        suggestion = nil
        suggestionConsumption = nil
        suggestionAssociationToken = nil
        typedSuggestionOrigin = nil
        overlay.hide()
    }

    private func deferCompletionEpisodeFinalization(
        resolution: CompletionEpisodeResolution,
        requiresPostEventObservation: Bool = false
    ) {
        guard completionEpisodeTracker.activeInvocationID != nil else {
            resetCompletionEpisodeFinalizationState()
            suggestion = nil
            suggestionConsumption = nil
            suggestionAssociationToken = nil
            typedSuggestionOrigin = nil
            overlay.hide()
            return
        }
        pendingCompletionEpisodeResolution =
            CompletionEpisodePendingResolutionPolicy.resolve(
                existing: pendingCompletionEpisodeResolution,
                proposed: resolution
            )
        let authoritativeBaseline = lastSnapshot.map {
            CapturedFieldState(
                text: $0.fieldText,
                selection: $0.selection
            )
        }
        let expectedField = currentCapturedFieldFromBuffer()
        if
            let authoritativeBaseline,
            (
                expectedField != authoritativeBaseline
                    || requiresPostEventObservation
            )
        {
            completionEpisodeAuthoritativeBaselineField =
                authoritativeBaseline
            completionEpisodeExpectedField = expectedField
            completionEpisodeRequiresPostEventObservation =
                requiresPostEventObservation
            let now = Date()
            completionEpisodeObservationDeadline =
                now.addingTimeInterval(1)
            invalidationReconciliationNotBefore =
                now.addingTimeInterval(0.05)
            invalidationReconciliationGeneration &+= 1
            scheduleInvalidationReconciliation()
        } else {
            finalizeCompletionEpisode(resolution: resolution)
        }
        suggestion = nil
        suggestionConsumption = nil
        suggestionAssociationToken = nil
        typedSuggestionOrigin = nil
        overlay.hide()
    }

    private func scheduleInvalidationReconciliation() {
        let generation = invalidationReconciliationGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard
                !Task.isCancelled,
                let self,
                generation == self.invalidationReconciliationGeneration
            else {
                return
            }
            self.reconcile()
        }
    }

    private func finalizePendingCompletionEpisodeIfNeeded(
        finalField: CapturedFieldState? = nil
    ) {
        guard let resolution = pendingCompletionEpisodeResolution else {
            return
        }
        finalizeCompletionEpisode(
            resolution: resolution,
            finalField: finalField
        )
    }

    private func discardPendingCompletionEpisode() {
        guard pendingCompletionEpisodeResolution != nil else { return }
        completionEpisodeTracker.discard()
        resetCompletionEpisodeFinalizationState()
    }

    private var completionEpisodeObservationDeadlineExceeded: Bool {
        completionEpisodeObservationDeadline.map { Date() >= $0 } ?? false
    }

    private func capturedField(
        from snapshot: EditorSnapshot
    ) -> CapturedFieldState {
        CapturedFieldState(
            text: snapshot.fieldText,
            selection: snapshot.selection
        )
    }

    private func clearSuggestion(
        resetConsumption: Bool = true,
        resolution: CompletionEpisodeResolution
    ) {
        debounceTask?.cancel()
        caretReanchorTask?.cancel()
        suggestion = nil
        if resetConsumption {
            if !Self.shouldDeferPendingOutcomeSettlementWhileClearing(
                pendingResolution: pendingCompletionEpisodeResolution,
                expectedField: completionEpisodeExpectedField
            ) {
                finalizeCompletionEpisode(resolution: resolution)
            }
            suggestionConsumption = nil
            suggestionAssociationToken = nil
            typedSuggestionOrigin = nil
        }
        overlay.hide()
    }

    private func invalidatePendingCompletion() {
        debounceTask?.cancel()
        caretReanchorTask?.cancel()
        cancelRefill()
        preparedRequestSnapshot = nil
        newestRequestID &+= 1
        let invalidatedRequestID = newestRequestID
        Task { [weak self, requestPump] in
            guard
                let self,
                self.newestRequestID == invalidatedRequestID
            else {
                return
            }
            await requestPump.cancel()
        }
    }
}
