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
    private var newestRequestID: UInt64 = 0
    private var enabled = true

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
        requestPermissions()
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
                self?.reconcile()
            }
        }
    }

    @objc func requestPermissions() {
        accessibility.requestTrustPrompt()
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }
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
        clearSuggestion()
        buffer.apply(mutation)

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

        let focusChanged = lastSnapshot?.processID != snapshot.processID
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

        lastSnapshot = snapshot
        suggestion = text
        overlay.show(
            text,
            at: snapshot.caretRect,
            typography: snapshot.typography,
            foregroundColor: snapshot.foregroundColor
        )
    }

    private func acceptSuggestion() -> Bool {
        guard enabled, let suggestion, !suggestion.isEmpty else { return false }
        inputMonitor?.paste(suggestion)
        buffer.apply(.insert(suggestion))
        clearSuggestion()
        return true
    }

    private func clearSuggestion() {
        debounceTask?.cancel()
        suggestion = nil
        overlay.hide()
    }
}
