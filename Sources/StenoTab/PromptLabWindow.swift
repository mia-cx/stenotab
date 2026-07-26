import AppKit
import CompletionCore
import SwiftUI

struct SettingsActions {
    let requestAccessibilityPermission: @MainActor () -> Void
    let openAccessibilitySettings: @MainActor () -> Void
    let requestScreenRecordingPermission: @MainActor () -> Void
    let openScreenRecordingSettings: @MainActor () -> Void
    let openClipboardSettings: @MainActor () -> Void
    let openKeyboardSettings: @MainActor () -> Void
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        promptStore: PromptSettingsStore,
        applicationPolicyStore: ApplicationPolicyStore,
        providerSettingsStore: ProviderSettingsStore,
        runtimeStatusStore: RuntimeStatusStore,
        launchAtLoginSettingsStore: LaunchAtLoginSettingsStore,
        systemTextSuggestionSettingsStore:
            SystemTextSuggestionSettingsStore,
        clipboardAccessStore: ClipboardAccessStore,
        personalizationSettingsStore: PersonalizationSettingsStore,
        actions: SettingsActions
    ) {
        let rootView = SettingsRootView(
            promptStore: promptStore,
            applicationPolicyStore: applicationPolicyStore,
            providerSettingsStore: providerSettingsStore,
            runtimeStatusStore: runtimeStatusStore,
            launchAtLoginSettingsStore: launchAtLoginSettingsStore,
            systemTextSuggestionSettingsStore:
                systemTextSuggestionSettingsStore,
            clipboardAccessStore: clipboardAccessStore,
            personalizationSettingsStore: personalizationSettingsStore,
            actions: actions
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 1_020, height: 780))
        window.minSize = NSSize(width: 820, height: 620)
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case setup
    case models
    case contextPrivacy
    case personalization
    case promptLab
    case appSettings

    var id: String { rawValue }
}

private struct SettingsRootView: View {
    @ObservedObject var promptStore: PromptSettingsStore
    @ObservedObject var applicationPolicyStore: ApplicationPolicyStore
    @ObservedObject var providerSettingsStore: ProviderSettingsStore
    @ObservedObject var runtimeStatusStore: RuntimeStatusStore
    @ObservedObject var launchAtLoginSettingsStore: LaunchAtLoginSettingsStore
    @ObservedObject var systemTextSuggestionSettingsStore:
        SystemTextSuggestionSettingsStore
    @ObservedObject var clipboardAccessStore: ClipboardAccessStore
    @ObservedObject var personalizationSettingsStore:
        PersonalizationSettingsStore
    let actions: SettingsActions
    @State private var selection: SettingsPage? = .setup

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Setup", systemImage: "checkmark.shield")
                    .tag(SettingsPage.setup)
                Label("Models", systemImage: "shippingbox")
                    .tag(SettingsPage.models)
                Label("Context & Privacy", systemImage: "hand.raised")
                    .tag(SettingsPage.contextPrivacy)
                Label("Personalization", systemImage: "person.crop.circle.badge.checkmark")
                    .tag(SettingsPage.personalization)
                Label("Prompt Lab", systemImage: "text.badge.sparkles")
                    .tag(SettingsPage.promptLab)
                Label("App Settings", systemImage: "app.badge.checkmark")
                    .tag(SettingsPage.appSettings)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            switch selection ?? .setup {
            case .setup:
                SetupSettingsView(
                    store: runtimeStatusStore,
                    launchAtLoginStore: launchAtLoginSettingsStore,
                    systemTextSuggestionStore:
                        systemTextSuggestionSettingsStore,
                    actions: actions
                )
            case .models:
                ModelsView(
                    runtimeStore: runtimeStatusStore,
                    providerStore: providerSettingsStore
                )
            case .contextPrivacy:
                ContextPrivacyView(
                    store: promptStore,
                    clipboardEnabled: clipboardEnabled
                )
            case .personalization:
                PersonalizationSettingsView(
                    store: personalizationSettingsStore
                )
            case .promptLab:
                PromptLabView(
                    store: promptStore,
                    clipboardEnabled: clipboardEnabled
                )
            case .appSettings:
                AppSettingsView(store: applicationPolicyStore)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            clipboardAccessStore.refresh()
        }
    }

    private var clipboardEnabled: Binding<Bool> {
        Binding(
            get: {
                promptStore.configuration.context.includeClipboard
            },
            set: { isEnabled in
                guard isEnabled else {
                    promptStore.configuration.context.includeClipboard = false
                    return
                }

                switch clipboardAccessStore.state.enableAction {
                case .enable:
                    promptStore.configuration.context.includeClipboard = true
                case .requestAccess:
                    let state = clipboardAccessStore.requestAccess()
                    promptStore.configuration.context.includeClipboard =
                        state != .denied
                case .openSettings:
                    promptStore.configuration.context.includeClipboard = false
                    actions.openClipboardSettings()
                }
            }
        )
    }
}

private struct PersonalizationSettingsView: View {
    @ObservedObject var store: PersonalizationSettingsStore
    @State private var confirmsDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Learning") {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Learn from my writing")
                                .font(.headline)
                            Text(
                                "Store model inputs, suggestion outcomes, "
                                + "accepted completions, and writing history "
                                + "locally in encrypted form. Turning this "
                                + "off stops new collection."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle(
                            "Learn from my writing",
                            isOn: $store.collectionEnabled
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .frame(width: 54, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    Divider()
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Learn from directly typed text")
                                .font(.headline)
                            Text(
                                "Store completed writing episodes even when "
                                + "you did not accept a suggestion."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle(
                            "Learn from directly typed text",
                            isOn: $store.collectDirectTyping
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .frame(width: 54, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    Divider()
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Use high-confidence local completions")
                                .font(.headline)
                            Text(
                                "Use learned vocabulary and phrases without "
                                + "calling the AI model when local evidence "
                                + "is strong enough."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle(
                            "Use high-confidence local completions",
                            isOn: $store.useLocalCompletions
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .frame(width: 54, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }

                SettingsSection(title: "Automatic Voice Profile") {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            if let assessment = store.voiceAssessment {
                                Text(assessment.summary)
                                    .textSelection(.enabled)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                Text(
                                    "Based on \(assessment.sampleCount) recent "
                                        + "writing samples • updated "
                                        + assessment.generatedAt
                                            .formatted(.relative(presentation: .named))
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else {
                                Text(
                                    "StenoTab will summarize observable traits "
                                        + "such as sentence length, casing, "
                                        + "punctuation, contractions, and "
                                        + "technical vocabulary after at least "
                                        + "10 writing events."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Reassess") {
                            store.reassessVoice()
                        }
                        .disabled(store.storedEventCount < 10)
                    }
                }

                if !store.vocabularyEntries.isEmpty {
                    SettingsSection(title: "Learned Vocabulary") {
                        ForEach(store.vocabularyEntries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.preferredCasing)
                                    .font(.headline)
                                    .textSelection(.enabled)
                                Spacer()
                                Text(
                                    entry.positiveEvidence.formatted(
                                        .number.precision(
                                            .fractionLength(0...1)
                                        )
                                    )
                                    + " evidence"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text(entry.lastSeen, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if entry.id != store.vocabularyEntries.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                SettingsSection(title: "Retention") {
                    LabeledContent("Keep history") {
                        Picker(
                            "Keep history",
                            selection: $store.retentionDays
                        ) {
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                            Text("1 year").tag(365)
                            Text("Forever").tag(0)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    Divider()
                    LabeledContent("Maximum encrypted data") {
                        Picker(
                            "Maximum encrypted data",
                            selection: $store.maximumStorageMegabytes
                        ) {
                            Text("25 MB").tag(25)
                            Text("100 MB").tag(100)
                            Text("500 MB").tag(500)
                            Text("Unlimited").tag(0)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }

                SettingsSection(title: "Stored Data") {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Personalization events")
                                .font(.headline)
                            Text(
                                "\(store.storedEventCount) encrypted "
                                + (store.storedEventCount == 1
                                    ? "event is"
                                    : "events are")
                                + " stored on this Mac."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Export…") {
                            exportHistory()
                        }
                        .disabled(store.storedEventCount == 0)
                        Button("Delete All…") {
                            confirmsDeletion = true
                        }
                        .disabled(
                            store.storedEventCount == 0
                                && !store.recoveryDeletionIsAvailable
                        )
                    }

                    Text(
                        ByteCountFormatter.string(
                            fromByteCount:
                                Int64(store.encryptedPayloadBytes),
                            countStyle: .file
                        )
                        + " of encrypted personalization data"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let operationError = store.operationError {
                        Divider()
                        Text(operationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !store.recentEpisodes.isEmpty {
                    SettingsSection(title: "Recent Writing") {
                        ForEach(
                            Array(store.recentEpisodes.reversed()),
                            id: \.id
                        ) { episode in
                            WritingEpisodeHistoryRow(
                                episode: episode,
                                delete: {
                                    store.deleteEvent(id: episode.id)
                                },
                                deleteApplication: {
                                    guard let bundleIdentifier =
                                        episode.context
                                            .applicationBundleIdentifier
                                    else {
                                        return
                                    }
                                    store.deleteApplicationHistory(
                                        bundleIdentifier:
                                            bundleIdentifier
                                    )
                                }
                            )
                            if episode.id != store.recentEpisodes.first?.id {
                                Divider()
                            }
                        }
                    }
                }

                if !store.recentCompletionEpisodes.isEmpty {
                    SettingsSection(title: "Recent Completion Outcomes") {
                        ForEach(
                            Array(
                                store.recentCompletionEpisodes.reversed()
                            ),
                            id: \.id
                        ) { episode in
                            CompletionEpisodeHistoryRow(
                                episode: episode,
                                delete: {
                                    store.deleteEvent(id: episode.id)
                                },
                                deleteApplication: {
                                    guard let bundleIdentifier =
                                        episode.invocation.context
                                            .applicationBundleIdentifier
                                    else {
                                        return
                                    }
                                    store.deleteApplicationHistory(
                                        bundleIdentifier:
                                            bundleIdentifier
                                    )
                                }
                            )
                            if episode.id
                                != store.recentCompletionEpisodes.first?.id {
                                Divider()
                            }
                        }
                    }
                }

                if !store.recentAcceptedSuggestions.isEmpty {
                    SettingsSection(title: "Recent Accepted Suggestions") {
                        ForEach(
                            Array(
                                store.recentAcceptedSuggestions.reversed()
                            ),
                            id: \.id
                        ) { capture in
                            AcceptedSuggestionHistoryRow(
                                capture: capture,
                                delete: {
                                    store.deleteEvent(id: capture.id)
                                },
                                deleteApplication: {
                                    guard let bundleIdentifier =
                                        capture.context
                                            .applicationBundleIdentifier
                                    else {
                                        return
                                    }
                                    store.deleteApplicationHistory(
                                        bundleIdentifier:
                                            bundleIdentifier
                                    )
                                }
                            )
                            if capture.id
                                != store.recentAcceptedSuggestions.first?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.setHistoryInspectorVisible(true)
        }
        .onDisappear {
            store.setHistoryInspectorVisible(false)
        }
        .confirmationDialog(
            "Delete all personalization data?",
            isPresented: $confirmsDeletion
        ) {
            Button("Delete All", role: .destructive) {
                store.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes the encrypted writing history "
                + "and all learned personalization derived from it."
            )
        }
    }

    private func exportHistory() {
        Task {
            do {
                let data = try await store.exportData()
                let panel = NSSavePanel()
                panel.nameFieldStringValue =
                    "StenoTab Personalization Export.json"
                panel.canCreateDirectories = true
                guard
                    panel.runModal() == .OK,
                    let url = panel.url
                else {
                    return
                }
                try data.write(to: url, options: .atomic)
            } catch {
                store.report(error: error)
            }
        }
    }
}

private struct CompletionEpisodeHistoryRow: View {
    let episode: CompletionEpisodeCapture
    let delete: () -> Void
    let deleteApplication: () -> Void
    @State private var showsModelInput = false

    private var finalSuggestion: String {
        episode.suggestionRevisions.last?.text ?? ""
    }

    private var modelInput: String {
        let prompt = episode.invocation.prompt
        return [
            prompt.systemMessage.map { "System:\n\($0)" },
            prompt.userMessage.map { "User:\n\($0)" },
            prompt.textPrompt.map { "Prompt:\n\($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(episode.invocation.field.text)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !finalSuggestion.isEmpty {
                    Text("Suggested: “\(finalSuggestion)”")
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let actualInsertedText = episode.actualInsertedText {
                    Text("Outcome: “\(actualInsertedText)”")
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 6) {
                    Text(episode.invocation.generation.modelIdentifier)
                    Text("•")
                    Text(
                        episode.resolution.rawValue.replacingOccurrences(
                            of: "_",
                            with: " "
                        )
                    )
                    Text("•")
                    Text(episode.endedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if !modelInput.isEmpty {
                    DisclosureGroup(
                        "Model input",
                        isExpanded: $showsModelInput
                    ) {
                        Text(modelInput)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }

            Menu {
                Button("Delete This Record", role: .destructive) {
                    delete()
                }
                if episode.invocation.context
                    .applicationBundleIdentifier != nil
                {
                    Button(
                        "Delete All from This App",
                        role: .destructive
                    ) {
                        deleteApplication()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

private struct AcceptedSuggestionHistoryRow: View {
    let capture: AcceptedSuggestionCapture
    let delete: () -> Void
    let deleteApplication: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.field.text + capture.insertion)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(
                        capture.context.applicationBundleIdentifier
                            ?? "Unknown application"
                    )
                    Text("•")
                    Text("inserted “\(capture.insertion)”")
                    Text("•")
                    Text(capture.capturedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Menu {
                Button("Delete This Record", role: .destructive) {
                    delete()
                }
                if capture.context.applicationBundleIdentifier != nil {
                    Button(
                        "Delete All from This App",
                        role: .destructive
                    ) {
                        deleteApplication()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

private struct WritingEpisodeHistoryRow: View {
    let episode: WritingEpisodeCapture
    let delete: () -> Void
    let deleteApplication: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.finalField.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(
                        episode.context.applicationBundleIdentifier
                            ?? "Unknown application"
                    )
                    Text("•")
                    Text(episode.boundary.rawValue.replacingOccurrences(
                        of: "_",
                        with: " "
                    ))
                    Text("•")
                    Text(episode.endedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Menu {
                Button("Delete This Record", role: .destructive) {
                    delete()
                }
                if episode.context.applicationBundleIdentifier != nil {
                    Button(
                        "Delete All from This App",
                        role: .destructive
                    ) {
                        deleteApplication()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

private struct SetupSettingsView: View {
    @ObservedObject var store: RuntimeStatusStore
    @ObservedObject var launchAtLoginStore: LaunchAtLoginSettingsStore
    @ObservedObject var systemTextSuggestionStore:
        SystemTextSuggestionSettingsStore
    let actions: SettingsActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "General") {
                    LaunchAtLoginRow(store: launchAtLoginStore)
                }

                SettingsSection(title: "Permissions") {
                    PermissionSettingsRow(
                        title: "Accessibility",
                        detail:
                            "Required to detect editable fields, read the "
                            + "current cursor context, and insert accepted text.",
                        isGranted:
                            store.permissionState.accessibilityGranted,
                        request: actions.requestAccessibilityPermission,
                        openSettings: actions.openAccessibilitySettings
                    )
                    Divider()
                    PermissionSettingsRow(
                        title: "Screen Recording",
                        detail:
                            "Used for screenshot and OCR context when that "
                            + "feature is enabled.",
                        isGranted:
                            store.permissionState.screenRecordingGranted,
                        request: actions.requestScreenRecordingPermission,
                        openSettings: actions.openScreenRecordingSettings
                    )
                    Divider()
                    SystemTextSuggestionsSettingsRow(
                        store: systemTextSuggestionStore,
                        openSettings: actions.openKeyboardSettings
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ContextPrivacyView: View {
    @ObservedObject var store: PromptSettingsStore
    let clipboardEnabled: Binding<Bool>

    private var configuration: Binding<PromptConfiguration> {
        $store.configuration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Context Sources") {
                    ContextPrivacyToggleRow(
                        title: "Current application",
                        detail:
                            "Include the name of the app containing the "
                            + "focused editor.",
                        isOn:
                            configuration.context.includeCurrentApplication
                    )
                    Divider()
                    ContextPrivacyToggleRow(
                        title: "Input kind",
                        detail:
                            "Include whether the focused editor looks like a "
                            + "message box, text area, or text field.",
                        isOn: configuration.context.includeInputKind
                    )
                    Divider()
                    ContextPrivacyToggleRow(
                        title: "Clipboard contents",
                        detail:
                            "Read up to 2,000 characters of text from the "
                            + "clipboard as read-only model context. StenoTab "
                            + "never inserts clipboard contents. Off by "
                            + "default. Completion history can retain the "
                            + "model input when collection is enabled.",
                        isOn: clipboardEnabled
                    )
                    Divider()
                    ContextPrivacyToggleRow(
                        title: "Snapshots / OCR",
                        detail:
                            "Capture the focused app window when an editor "
                            + "gains focus. The screenshot is discarded after "
                            + "local recognition. Completion history can "
                            + "retain recognized text included in model input "
                            + "when collection is enabled.",
                        isOn: configuration.context.includeOCR
                    )
                    Divider()
                    ContextPrivacyToggleRow(
                        title: "Current website",
                        detail:
                            "Browser website detection is not connected yet.",
                        badge: "Coming soon",
                        isOn: .constant(false),
                        isEnabled: false
                    )
                }

            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ContextPrivacyToggleRow: View {
    let title: String
    let detail: String
    var badge: String?
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.14))
                            )
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!isEnabled)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

private struct LaunchAtLoginRow: View {
    @ObservedObject var store: LaunchAtLoginSettingsStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Launch automatically at login")
                    .font(.headline)
                Text(
                    "Start StenoTab after you sign in so completions are "
                        + "available without opening it manually."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let statusDetail = store.statusDetail {
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                "Launch automatically at login",
                isOn: Binding(
                    get: { store.isRequested },
                    set: { store.setEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: 54, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .onAppear {
            store.refresh()
        }
    }
}

private struct SystemTextSuggestionsSettingsRow: View {
    @ObservedObject var store: SystemTextSuggestionSettingsStore
    let openSettings: @MainActor () -> Void

    private var isConfigured: Bool {
        store.state.isConfiguredForStenoTab
    }

    private var statusText: String {
        if isConfigured {
            return "Disabled"
        }
        return "Still enabled: "
            + store.state.enabledSettingNames.joined(separator: " and ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(
                systemName: isConfigured
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill"
            )
            .foregroundStyle(isConfigured ? .green : .secondary)
            .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text("macOS text suggestions")
                    .font(.headline)
                Text(
                    "Turn off inline predictive text and suggested replies "
                        + "so they do not overlap StenoTab completions."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isConfigured ? .green : .secondary)
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isConfigured {
                Button("Turn Off") {
                    store.disableAll()
                }
            }
            Button("Open Settings") {
                openSettings()
            }
        }
        .padding(.vertical, 5)
        .onAppear {
            store.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            store.refresh()
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let request: @MainActor () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(
                systemName: isGranted
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill"
            )
            .foregroundStyle(isGranted ? .green : .secondary)
            .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(isGranted ? "Granted" : "Not granted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isGranted ? .green : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isGranted {
                Button("Request") {
                    request()
                }
            }
            Button("Open Settings") {
                openSettings()
            }
        }
        .padding(.vertical, 5)
    }
}

private struct RuntimeStatusRow: View {
    let status: CompletionRuntimeStatus

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(
                systemName: status.isReady
                    ? "checkmark.circle.fill"
                    : "clock.badge.exclamationmark"
            )
            .foregroundStyle(status.isReady ? .green : .secondary)
            .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.headline)
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }
}

private struct ModelsView: View {
    @ObservedObject var runtimeStore: RuntimeStatusStore
    @ObservedObject var providerStore: ProviderSettingsStore
    @State private var modelPickerSelection = ""
    @State private var customModelID = ""

    private let otherModelSelection = "__other__"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Provider") {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 12,
                        verticalSpacing: 8
                    ) {
                        GridRow {
                            Text("Provider")
                                .foregroundStyle(.secondary)
                            Picker(
                                "Provider",
                                selection: .constant("local")
                            ) {
                                Text("Local").tag("local")
                            }
                            .labelsHidden()
                            .disabled(true)
                            .frame(maxWidth: 320)
                        }
                    }

                    Text(
                        "StenoTab runs models locally with llama.cpp. Model "
                            + "files are downloaded into the standard shared "
                            + "Hugging Face cache, so an existing cached model "
                            + "is reused instead of copied."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        RuntimeStatusRow(status: runtimeStore.modelStatus)
                        Spacer()
                        Button("Open Hugging Face Cache") {
                            openHuggingFaceCache()
                        }
                    }
                }

                SettingsSection(title: "Model") {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 12,
                        verticalSpacing: 8
                    ) {
                        GridRow {
                            Text("Selected model")
                                .foregroundStyle(.secondary)
                            Picker(
                                "Selected model",
                                selection: modelSelection
                            ) {
                                Section("Recommended") {
                                    ForEach(LocalModelProfiles.all) { profile in
                                        Text(profile.displayName)
                                            .tag(profile.id)
                                    }
                                }
                                if !cachedProfiles.isEmpty {
                                    Section("Hugging Face Cache") {
                                        ForEach(cachedProfiles) { profile in
                                            Text(profile.displayName)
                                                .tag(profile.id)
                                        }
                                    }
                                }
                                Divider()
                                Text("Other…")
                                    .tag(otherModelSelection)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 560)
                        }
                    }

                    if modelPickerSelection == otherModelSelection {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hugging Face model ID")
                                .font(.headline)
                            Text(
                                "Enter owner/model or paste its huggingface.co "
                                    + "URL. StenoTab selects a single-file "
                                    + "Q4_K_M GGUF when available."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            HStack {
                                TextField(
                                    "owner/model",
                                    text: $customModelID
                                )
                                .textFieldStyle(.roundedBorder)
                                Button("Download") {
                                    providerStore.downloadCustomLocalModel(
                                        repository: customModelID
                                    )
                                }
                                .disabled(
                                    normalizedCustomModelID == nil
                                        || isDownloading
                                )
                            }
                        }
                    }

                    Divider()
                    if let profile = selectedLocalProfile {
                        HStack(alignment: .top, spacing: 12) {
                            Image(
                                systemName: localModelURL == nil
                                    ? "arrow.down.circle"
                                    : "checkmark.circle.fill"
                            )
                            .foregroundStyle(
                                localModelURL == nil
                                    ? Color.secondary
                                    : Color.green
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    localModelURL == nil
                                        ? "Model not downloaded"
                                        : "Available in the shared Hugging Face cache"
                                )
                                .font(.headline)
                                Text(profile.qualityNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if profile.minimumUnifiedMemoryGB > 0 {
                                    Text(
                                        "Recommended minimum: "
                                            + "\(profile.minimumUnifiedMemoryGB) GB "
                                            + "unified memory"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Text(localModelURL?.path ?? profile.repository)
                                    .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if let localModelURL {
                                Button("Reveal") {
                                    NSWorkspace.shared
                                        .activateFileViewerSelecting([
                                            localModelURL
                                        ])
                                }
                            } else {
                                localDownloadControls(profile: profile)
                            }
                        }
                        if case let .failed(message) =
                            providerStore.localModelDownloadStatus
                        {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        if case let .downloading(received, total) =
                            providerStore.localModelDownloadStatus
                        {
                            HStack(spacing: 10) {
                                if let total, total > 0 {
                                    ProgressView(
                                        value: Double(received),
                                        total: Double(total)
                                    )
                                } else {
                                    ProgressView()
                                }
                                Text(downloadProgressText(
                                    received: received,
                                    total: total
                                ))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                SettingsSection(title: "Local Runtime") {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 12,
                        verticalSpacing: 8
                    ) {
                        GridRow {
                            Text("Server URL")
                                .foregroundStyle(.secondary)
                            TextField(
                                "http://127.0.0.1:18473/v1",
                                text: localBaseURL
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Maximum length")
                                .foregroundStyle(.secondary)
                            Stepper(
                                "\(localConfiguration.maximumWords) words",
                                value: localMaximumWords,
                                in: 1...32
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            providerStore.refreshCachedLocalProfiles()
            providerStore.refreshLocalModelDownloadStatus()
            modelPickerSelection = localConfiguration.profileID
        }
        .onChange(of: localConfiguration.profileID) {
            _, profileID in
            modelPickerSelection = profileID
        }
    }

    private var localConfiguration: LocalCompletionConfiguration {
        providerStore.configuration.localConfiguration
    }

    private var selectedLocalProfile: LocalModelProfile? {
        localConfiguration.selectedProfile
    }

    private var localModelURL: URL? {
        selectedLocalProfile.flatMap {
            HuggingFaceModelCache.modelURL(for: $0)
        }
    }

    private var cachedProfiles: [LocalModelProfile] {
        let recommendedKeys = Set(
            LocalModelProfiles.all.map(HuggingFaceModelCache.artifactIdentity)
        )
        var profilesByID = Dictionary(
            uniqueKeysWithValues: providerStore.cachedLocalProfiles.map {
                ($0.id, $0)
            }
        )
        if let selectedLocalProfile,
           !recommendedKeys.contains(
               HuggingFaceModelCache.artifactIdentity(
                   for: selectedLocalProfile
               )
           ),
           profilesByID[selectedLocalProfile.id] == nil {
            profilesByID[selectedLocalProfile.id] = selectedLocalProfile
        }
        return profilesByID.values
            .filter {
                !recommendedKeys.contains(
                    HuggingFaceModelCache.artifactIdentity(for: $0)
                )
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { modelPickerSelection },
            set: { selection in
                modelPickerSelection = selection
                guard selection != otherModelSelection else { return }
                guard let profile = selectableProfile(id: selection) else {
                    return
                }
                providerStore.selectLocalProfile(profile)
            }
        )
    }

    private var localBaseURL: Binding<String> {
        Binding(
            get: { localConfiguration.baseURL },
            set: {
                providerStore.setLocalConfiguration(
                    LocalCompletionConfiguration(
                        profileID: localConfiguration.profileID,
                        customProfile: localConfiguration.customProfile,
                        baseURL: $0,
                        maximumWords: localConfiguration.maximumWords
                    )
                )
            }
        )
    }

    private var localMaximumWords: Binding<Int> {
        Binding(
            get: { localConfiguration.maximumWords },
            set: {
                providerStore.setLocalConfiguration(
                    LocalCompletionConfiguration(
                        profileID: localConfiguration.profileID,
                        customProfile: localConfiguration.customProfile,
                        baseURL: localConfiguration.baseURL,
                        maximumWords: $0
                    )
                )
            }
        )
    }

    private var normalizedCustomModelID: String? {
        HuggingFaceRepositorySelection.normalizedRepositoryID(
            from: customModelID
        )
    }

    private var isDownloading: Bool {
        if case .downloading = providerStore.localModelDownloadStatus {
            return true
        }
        return false
    }

    private func selectableProfile(id: String) -> LocalModelProfile? {
        LocalModelProfiles.profile(id: id)
            ?? cachedProfiles.first { $0.id == id }
    }

    private func openHuggingFaceCache() {
        let cacheURL = HuggingFaceModelCache.defaultRoot()
        try? FileManager.default.createDirectory(
            at: cacheURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(cacheURL)
    }

    @ViewBuilder
    private func localDownloadControls(
        profile: LocalModelProfile
    ) -> some View {
        switch providerStore.localModelDownloadStatus {
        case .downloading:
            Button("Cancel") {
                providerStore.cancelLocalModelDownload()
            }
        case .idle, .failed:
            VStack(alignment: .trailing, spacing: 5) {
                Button("Download") {
                    providerStore.downloadSelectedLocalModel()
                }
                Button("Model Page") {
                    guard let url = URL(
                        string:
                            "https://huggingface.co/"
                            + profile.repository
                    ) else {
                        return
                    }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .ready:
            EmptyView()
        }
    }

    private func downloadProgressText(
        received: Int64,
        total: Int64?
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let receivedText = formatter.string(fromByteCount: received)
        guard let total else { return receivedText }
        return "\(receivedText) of \(formatter.string(fromByteCount: total))"
    }
}

private struct RemoteProviderEditor: View {
    let provider: RemoteProviderConfiguration
    @ObservedObject var store: ProviderSettingsStore
    @State private var draft: RemoteProviderConfiguration
    @State private var apiKey = ""
    @State private var didLoadCredential = false
    @State private var saveError: String?
    @State private var confirmsRemoval = false

    init(
        provider: RemoteProviderConfiguration,
        store: ProviderSettingsStore
    ) {
        self.provider = provider
        self.store = store
        _draft = State(initialValue: provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Display name", text: $draft.displayName)
                    .font(.headline)
                Spacer()
                connectionStatus
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Base URL")
                        .foregroundStyle(.secondary)
                    TextField(
                        "https://example.com/v1",
                        text: $draft.baseURL
                    )
                }
                GridRow {
                    Text("Model")
                        .foregroundStyle(.secondary)
                    TextField("model-name", text: $draft.model)
                }
                GridRow {
                    Text("API style")
                        .foregroundStyle(.secondary)
                    Picker("API style", selection: $draft.apiStyle) {
                        ForEach(CompletionAPIStyle.allCases, id: \.self) {
                            style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("API key")
                        .foregroundStyle(.secondary)
                    SecureField("Optional", text: $apiKey)
                }
                GridRow {
                    Text("Maximum length")
                        .foregroundStyle(.secondary)
                    Stepper(
                        "\(draft.maximumWords) words",
                        value: $draft.maximumWords,
                        in: 1...32
                    )
                }
            }
            .textFieldStyle(.roundedBorder)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Remove", role: .destructive) {
                    confirmsRemoval = true
                }
                Spacer()
                Button("Save") {
                    save()
                }
                .disabled(!isValid)
                Button("Save & Test") {
                    saveAndTest()
                }
                .disabled(!isValid)
            }
        }
        .padding(.vertical, 7)
        .task(id: provider.id) {
            guard !didLoadCredential else { return }
            didLoadCredential = true
            do {
                apiKey = try store.credential(for: provider.id) ?? ""
            } catch {
                saveError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Remove \(provider.displayName)?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Provider", role: .destructive) {
                do {
                    try store.removeRemoteProvider(id: provider.id)
                } catch {
                    saveError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This also deletes the provider's API key from Keychain."
            )
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch store.connectionTests[provider.id] {
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: 280, alignment: .trailing)
        case nil:
            EmptyView()
        }
    }

    private var isValid: Bool {
        draft.validatedBaseURL != nil
            && !draft.displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && !draft.model.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    private func save() {
        do {
            try store.upsert(draft, apiKey: apiKey)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func saveAndTest() {
        save()
        guard saveError == nil else { return }
        Task {
            await store.testRemoteProvider(id: draft.id)
        }
    }
}

private extension CompletionAPIStyle {
    var displayName: String {
        switch self {
        case .textCompletions:
            "Text Completions"
        case .chatCompletions:
            "Chat Completions"
        case .gemmaChatPrefill:
            "Gemma Chat Prefill"
        }
    }
}

private struct AppSettingsView: View {
    @ObservedObject var store: ApplicationPolicyStore
    @State private var searchText = ""

    private var filteredApplications: [SeenApplication] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return store.seenApplications }
        return store.seenApplications.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Completion Defaults") {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Enable completions by default")
                            .font(.headline)
                        Text(
                            "Apps set to Use Global Default inherit this value."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle(
                        "Enable completions by default",
                        isOn: Binding(
                            get: {
                                store.state.globalCompletionsEnabled
                            },
                            set: {
                                store.setGlobalCompletionsEnabled($0)
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(width: 54, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }

            SettingsSection(title: "Applications") {
                TextField("Search applications", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                if store.seenApplications.isEmpty {
                    ContentUnavailableView(
                        "No Applications Seen Yet",
                        systemImage: "app.dashed",
                        description: Text(
                            "Applications appear after StenoTab encounters a "
                                + "non-secure text field in them."
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else if filteredApplications.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(
                                Array(filteredApplications.enumerated()),
                                id: \.element.id
                            ) { index, application in
                                if index > 0 {
                                    Divider()
                                }
                                ApplicationPolicyRow(
                                    application: application,
                                    policyOverride: Binding(
                                        get: {
                                            store.policyOverride(
                                                for:
                                                    application.bundleIdentifier
                                            )
                                        },
                                        set: {
                                            store.setPolicyOverride(
                                                $0,
                                                for:
                                                    application.bundleIdentifier
                                            )
                                        }
                                    )
                                )
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 28)
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ApplicationPolicyRow: View {
    let application: SeenApplication
    @Binding var policyOverride: ApplicationPolicyOverride

    private var icon: NSImage {
        if let path = application.bundleURL?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(
            for: .applicationBundle
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(application.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(application.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Last seen \(application.lastSeenAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Completion policy", selection: $policyOverride) {
                Text("Use Global Default")
                    .tag(ApplicationPolicyOverride.inherit)
                Text("Enabled")
                    .tag(ApplicationPolicyOverride.enabled)
                Text("Disabled")
                    .tag(ApplicationPolicyOverride.disabled)
            }
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.vertical, 10)
    }
}

private enum PromptPreviewStyle: String, CaseIterable, Identifiable {
    case textCompletion = "Base model"
    case chat = "Chat API"

    var id: String { rawValue }
}

private struct PromptLabView: View {
    @ObservedObject var store: PromptSettingsStore
    let clipboardEnabled: Binding<Bool>
    @State private var previewStyle = PromptPreviewStyle.textCompletion

    private var configuration: Binding<PromptConfiguration> {
        $store.configuration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                contextSection
                voiceSection
                perspectiveSection
                immediateContextSection
                finalPromptSection
                chatInstructionSection
                previewSection
                bottomControls
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var contextSection: some View {
        SettingsSection(title: "Context") {
            PromptToggleRow(
                title: "Opening instruction",
                detail: "Frame the request as text being written on this Mac.",
                isOn: configuration.base.includeOpeningInstruction,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.openingInstruction,
                dynamicValue: ""
            )
            Divider()
            PromptToggleRow(
                title: "Focused app context",
                detail:
                    "Describe the current activity, website, and application "
                    + "in the writer's first person.",
                isOn: configuration.base.includeFocusedContext,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.focusedContextHeading,
                dynamicValue: "FOCUSED_CONTEXT",
                valueOnNewLine: true
            )
            Divider()
            PromptToggleRow(
                title: "Current application",
                detail: "Include the name of the app containing the focused editor.",
                isOn: configuration.context.includeCurrentApplication,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.focusedApplicationConnector,
                dynamicValue: "CURRENT_APP"
            )
            Divider()
            PromptToggleRow(
                title: "Current website",
                detail: "Include the active website when typing in a browser.",
                badge: "Source pending",
                isOn: configuration.context.includeCurrentWebsite,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.focusedWebsiteConnector,
                dynamicValue: "CURRENT_WEBSITE"
            )
            Divider()
            PromptToggleRow(
                title: "Input kind",
                detail: "Include whether this looks like a message box, text area, or field.",
                isOn: configuration.context.includeInputKind,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.focusedActivityPrefix,
                dynamicValue: "INPUT_KIND"
            )
        }
    }

    private var voiceSection: some View {
        SettingsSection(title: "User Voice") {
            PromptToggleRow(
                title: "Frecent examples",
                detail:
                    "Include recent and frequently useful writing examples. "
                    + "Neutral bundled examples are used until history exists.",
                badge: "Source pending",
                isOn: configuration.voice.includeInputHistory,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.inputHistoryHeading,
                dynamicValue: "FRECENT_EXAMPLES",
                valueOnNewLine: true
            )
            if store.configuration.debugMode {
                DebugFramingEditor(
                    label: "Bundled seed fallback heading",
                    text: configuration.baseFraming.seedExamplesHeading,
                    dynamicValue: "SEED_EXAMPLES",
                    valueOnNewLine: true
                )
            }
            Divider()
            PromptToggleRow(
                title: "Semantically relevant examples",
                detail:
                    "Retrieve writing examples whose input context is closest "
                    + "to the current text.",
                badge: "Source pending",
                isOn: configuration.voice.includeRelevantInputHistory,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.relevantInputHistoryHeading,
                dynamicValue: "RELEVANT_EXAMPLES",
                valueOnNewLine: true
            )
            Divider()
            PromptToggleRow(
                title: "Periodic assessments",
                detail:
                    "Include a locally maintained summary of capitalization, "
                    + "formality, jargon, vocabulary, punctuation, and tone.",
                badge: "Source pending",
                isOn: configuration.voice.includePeriodicAssessments,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.assessmentHeading,
                dynamicValue: "VOICE_ASSESSMENT",
                valueOnNewLine: true
            )
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom personalization")
                            .font(.headline)
                        Text(
                            "Add durable details and preferences that should "
                                + "apply to every completion."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle(
                        "Custom personalization",
                        isOn: configuration.voice.includeCustomVoice
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(width: 54, alignment: .trailing)
                }
                TextEditor(text: configuration.voice.customVoice)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 92)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.22))
                    }
                    .disabled(!store.configuration.voice.includeCustomVoice)
                    .opacity(
                        store.configuration.voice.includeCustomVoice ? 1 : 0.55
                    )
                if store.configuration.debugMode {
                    DebugFramingEditor(
                        label: "Custom personalization heading",
                        text: configuration.baseFraming.customVoiceHeading,
                        dynamicValue: "CUSTOM_VOICE",
                        valueOnNewLine: true
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var perspectiveSection: some View {
        SettingsSection(title: "Perspective") {
            PromptToggleRow(
                title: "Writer perspective",
                detail:
                    "Keep a causal model in the user's voice instead of an "
                    + "assistant voice.",
                isOn: configuration.base.includePerspectiveFix,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.perspectiveFix,
                dynamicValue: "",
                showsToggle: store.configuration.debugMode
            )
        }
    }

    private var immediateContextSection: some View {
        SettingsSection(title: "Immediate Context") {
            PromptToggleRow(
                title: "Snapshots / OCR",
                detail:
                    "Include text recognized locally from the focused app "
                    + "window. The screenshot is discarded after local "
                    + "recognition. Completion history can retain recognized "
                    + "text in model input when collection is enabled.",
                isOn: configuration.context.includeOCR,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.ocrHeading,
                dynamicValue: "OCR_CONTENT",
                valueOnNewLine: true
            )
            Divider()
            PromptToggleRow(
                title: "Clipboard contents",
                detail:
                    "Include clipboard text as read-only model context. "
                    + "Clipboard contents are never inserted. Completion "
                    + "history can retain the model input when collection is "
                    + "enabled.",
                isOn: clipboardEnabled,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.clipboardHeading,
                dynamicValue: "CLIPBOARD_CONTENT",
                valueOnNewLine: true
            )
        }
    }

    private var finalPromptSection: some View {
        SettingsSection(title: "Final Prompt") {
            PromptToggleRow(
                title: "Real-text boundary",
                detail:
                    "Mark the point after which the model should emit only "
                    + "the user's actual writing.",
                isOn: configuration.base.includeFinalBoundary,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.finalBoundary,
                dynamicValue: ""
            )
            Divider()
            PromptToggleRow(
                title: "Writing marker",
                detail:
                    "Prefix the literal input with “My writing:” and the § "
                    + "marker used by examples.",
                isOn: configuration.base.includeWritingHeading,
                debugMode: store.configuration.debugMode,
                framing: configuration.baseFraming.writingHeading,
                dynamicValue: "§USER_INPUT",
                valueOnNewLine: true
            )
            if store.configuration.debugMode {
                DebugFramingEditor(
                    label: "Writing marker prefix",
                    text: configuration.baseFraming.examplePrefix,
                    dynamicValue: "USER_INPUT",
                    valueOnNewLine: false
                )
            }
        }
    }

    @ViewBuilder
    private var chatInstructionSection: some View {
        if store.configuration.debugMode {
            SettingsSection(title: "Chat API") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System instruction (Chat API)")
                        .font(.headline)
                    Text(
                        "Chat providers receive this separate system message "
                            + "and the same canonical user prompt shown above."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    TextEditor(text: configuration.systemInstruction)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 82)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.22))
                        }
                }
            }
        }
    }

    private var previewSection: some View {
        let composed = CompletionPrompt.previewExample(
            configuration: store.configuration
        )
        let preview = switch previewStyle {
        case .textCompletion:
            composed.textCompletionPrompt
        case .chat:
            "SYSTEM\n\(composed.systemMessage)\n\nUSER\n\(composed.userMessage)"
        }
        let approximateTokens = max(1, preview.count / 4)

        return SettingsSection(title: "Preview") {
            HStack {
                Picker("Request style", selection: $previewStyle) {
                    ForEach(PromptPreviewStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 330)

                Spacer()
                Text("≈ \(approximateTokens) tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preview, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 280, maxHeight: 430)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.22))
            }
        }
    }

    private var bottomControls: some View {
        SettingsSection(title: "Advanced") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Advanced mode", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Text(
                        "Reveal the editable framing used around every "
                            + "dynamic prompt component."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Advanced mode", isOn: configuration.debugMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(width: 54, alignment: .trailing)
            }
            .padding(.vertical, 3)

            Divider()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reset Prompt Lab")
                        .font(.headline)
                    Text("Restore every prompt component and instruction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Reset to Defaults") {
                    store.reset()
                }
            }
            .padding(.vertical, 3)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PromptToggleRow: View {
    let title: String
    let detail: String
    var badge: String?
    @Binding var isOn: Bool
    let debugMode: Bool
    @Binding var framing: String
    let dynamicValue: String
    var valueOnNewLine = false
    var showsToggle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsToggle {
                    Toggle(title, isOn: $isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .frame(width: 54, alignment: .trailing)
                }
            }

            if debugMode {
                DebugFramingEditor(
                    text: $framing,
                    dynamicValue: dynamicValue,
                    valueOnNewLine: valueOnNewLine
                )
            }
        }
        .padding(.vertical, 3)
    }
}

private struct DebugFramingEditor: View {
    var label = "Framing"
    @Binding var text: String
    let dynamicValue: String
    let valueOnNewLine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Prompt prose", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                if valueOnNewLine {
                    Image(systemName: "return")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !dynamicValue.isEmpty {
                    Text(dynamicValue)
                        .font(.system(.caption2, design: .monospaced).bold())
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.purple.opacity(0.11), in: Capsule())
                }
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}
