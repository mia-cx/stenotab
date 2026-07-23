import AppKit
import ApplicationServices
import CompletionCore

@MainActor
final class CompletionCoordinator: NSObject {
    private let accessibility = AccessibilityReader()
    private let overlay = SuggestionOverlay()
    private let provider: any CompletionProvider
    private var inputMonitor: GlobalInputMonitor?
    private var reconciliationTimer: Timer?
    private var debounceTask: Task<Void, Never>?

    private var buffer = ShadowTextBuffer()
    private var lastSnapshot: EditorSnapshot?
    private var suggestion: String?
    private var suggestionConsumption: SuggestionConsumption?
    private var newestRequestID: UInt64 = 0
    private var enabled = true
    private var permissionObserver: ((PermissionState) -> Void)?
    private var lastPermissionState: PermissionState?
    private var typographyCalibrationByProcess:
        [pid_t: TypographyScaleCalibration] = [:]

    private lazy var requestPump = LatestRequestPump<CompletionRequest, CompletionResponse>(
        operation: { [provider] request in
            await provider.complete(request)
        },
        deliver: { [weak self] response in
            await MainActor.run {
                self?.receive(response)
            }
        }
    )

    override init() {
        provider = ProviderFactory.make()
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
            onTab: { [weak self] in
                self?.acceptSuggestion() ?? false
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

    private func requestInitialPermissionPrompts() {
        accessibility.requestTrustPrompt()
    }

    private var currentPermissionState: PermissionState {
        PermissionState(accessibilityGranted: AXIsProcessTrusted())
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
            clearSuggestion()
        } else {
            reconcile()
        }
    }

    private func handle(_ mutation: ShadowTextBuffer.Mutation) {
        guard enabled else { return }
        buffer.apply(mutation)

        if case let .insert(text) = mutation,
           var consumption = suggestionConsumption {
            let outcome = consumption.apply(insertedText: text)
            suggestionConsumption = consumption

            switch outcome {
            case let .matched(remaining):
                suggestion = remaining
                overlay.consume(
                    matchedText: text,
                    remainingSuggestion: remaining
                )
                return
            case .waitingForWhitespace:
                suggestion = nil
                overlay.hide()
                return
            case .triggerInference:
                clearSuggestion()
                scheduleCompletion()
                return
            case .diverged:
                clearSuggestion()
                scheduleCompletion()
                return
            }
        }

        clearSuggestion()
        if buffer.needsReconciliation {
            reconcile()
        } else {
            scheduleCompletion()
        }
    }

    private func reconcile() {
        guard enabled, let snapshot = accessibility.snapshot() else {
            clearSuggestion()
            return
        }

        let previousSnapshot = lastSnapshot
        let focusChanged = previousSnapshot?.processID != snapshot.processID
        updateTypographyScale(from: previousSnapshot, to: snapshot)
        lastSnapshot = snapshot

        if focusChanged || buffer.needsReconciliation ||
            (buffer.prefix != snapshot.prefix && suggestion == nil) {
            buffer.reconcile(prefix: snapshot.prefix, suffix: snapshot.suffix)
        }
    }

    private func scheduleCompletion() {
        debounceTask?.cancel()
        newestRequestID &+= 1
        let request = CompletionRequest(
            id: newestRequestID,
            prefix: buffer.prefix,
            suffix: buffer.suffix
        )

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled, let self else { return }
            await self.requestPump.submit(request)
        }
    }

    private func receive(_ response: CompletionResponse) {
        guard
            enabled,
            response.requestID == newestRequestID,
            let text = response.text,
            let snapshot = accessibility.snapshot() ?? lastSnapshot
        else {
            return
        }

        updateTypographyScale(from: lastSnapshot, to: snapshot)
        lastSnapshot = snapshot
        suggestion = text
        suggestionConsumption = SuggestionConsumption(suggestion: text)
        overlay.show(
            text,
            at: snapshot.caretRect,
            typography: snapshot.typography.scaled(
                by: typographyCalibrationByProcess[
                    snapshot.processID
                ]?.scale ?? 1
            ),
            foregroundColor: snapshot.foregroundColor
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

    private func acceptSuggestion() -> Bool {
        guard enabled, let suggestion, !suggestion.isEmpty else { return false }
        inputMonitor?.paste(suggestion)
        buffer.apply(.insert(suggestion))
        suggestionConsumption = .waitingForWhitespace()
        clearSuggestion(resetConsumption: false)
        return true
    }

    private func clearSuggestion(resetConsumption: Bool = true) {
        debounceTask?.cancel()
        suggestion = nil
        if resetConsumption {
            suggestionConsumption = nil
        }
        overlay.hide()
    }
}
