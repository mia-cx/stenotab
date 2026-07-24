import AppKit
import CompletionCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        promptStore: PromptSettingsStore,
        applicationPolicyStore: ApplicationPolicyStore
    ) {
        let rootView = SettingsRootView(
            promptStore: promptStore,
            applicationPolicyStore: applicationPolicyStore
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
    case promptLab
    case appSettings

    var id: String { rawValue }
}

private struct SettingsRootView: View {
    @ObservedObject var promptStore: PromptSettingsStore
    @ObservedObject var applicationPolicyStore: ApplicationPolicyStore
    @State private var selection: SettingsPage? = .promptLab

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Prompt Lab", systemImage: "text.badge.sparkles")
                    .tag(SettingsPage.promptLab)
                Label("App Settings", systemImage: "app.badge.checkmark")
                    .tag(SettingsPage.appSettings)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            switch selection ?? .promptLab {
            case .promptLab:
                PromptLabView(store: promptStore)
            case .appSettings:
                AppSettingsView(store: applicationPolicyStore)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
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
    @State private var previewStyle = PromptPreviewStyle.textCompletion

    private var configuration: Binding<PromptConfiguration> {
        $store.configuration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                contextSection
                voiceSection
                instructionSection
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
            if store.configuration.debugMode {
                DebugFramingEditor(
                    label: "Section heading",
                    text: configuration.framing.contextHeading,
                    dynamicValue: "CONTEXT_COMPONENTS",
                    valueOnNewLine: true
                )
                Divider()
            }
            PromptToggleRow(
                title: "Current application",
                detail: "Include the name of the app containing the focused editor.",
                isOn: configuration.context.includeCurrentApplication,
                debugMode: store.configuration.debugMode,
                framing: configuration.framing.applicationPrefix,
                dynamicValue: "CURRENT_APP"
            )
            Divider()
            PromptToggleRow(
                title: "Current website",
                detail: "Include the active website when typing in a browser.",
                badge: "Source pending",
                isOn: configuration.context.includeCurrentWebsite,
                debugMode: store.configuration.debugMode,
                framing: configuration.framing.websitePrefix,
                dynamicValue: "CURRENT_WEBSITE"
            )
            Divider()
            PromptToggleRow(
                title: "Input kind",
                detail: "Include whether this looks like a message box, text area, or field.",
                isOn: configuration.context.includeInputKind,
                debugMode: store.configuration.debugMode,
                framing: configuration.framing.inputKindPrefix,
                dynamicValue: "INPUT_KIND"
            )
            Divider()
            PromptToggleRow(
                title: "Snapshots / OCR",
                detail: "Include locally extracted text surrounding the current input.",
                badge: "Source pending",
                isOn: configuration.context.includeOCR,
                debugMode: store.configuration.debugMode,
                framing: configuration.framing.ocrHeading,
                dynamicValue: "OCR_CONTENT",
                valueOnNewLine: true
            )
            Divider()
            PromptToggleRow(
                title: "Clipboard contents",
                detail: "Include text currently on the clipboard. Off by default.",
                isOn: configuration.context.includeClipboard,
                debugMode: store.configuration.debugMode,
                framing: configuration.framing.clipboardHeading,
                dynamicValue: "CLIPBOARD_CONTENT",
                valueOnNewLine: true
            )
        }
    }

    private var voiceSection: some View {
        SettingsSection(title: "User Voice") {
            PromptToggleRow(
                title: "Input history",
                detail:
                    "Retrieve relevant passages from encrypted local history "
                    + "using embeddings and full-text storage.",
                badge: "Source pending",
                isOn: configuration.voice.includeInputHistory,
                debugMode: store.configuration.debugMode,
                framing: configuration.framing.inputHistoryHeading,
                dynamicValue: "RELEVANT_HISTORY",
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
                framing: configuration.framing.assessmentHeading,
                dynamicValue: "VOICE_ASSESSMENT",
                valueOnNewLine: true
            )
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom voice")
                    .font(.headline)
                Text(
                    "Add durable preferences that should apply to every completion."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                if store.configuration.debugMode {
                    DebugFramingEditor(
                        text: configuration.framing.customVoiceHeading,
                        dynamicValue: "CUSTOM_VOICE",
                        valueOnNewLine: true
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var instructionSection: some View {
        SettingsSection(title: "Completion Instruction") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Tell the model how to continue the text. Keep this short "
                        + "and describe only what should be inserted."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                TextEditor(text: configuration.completionInstruction)
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

            if store.configuration.debugMode {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("System instruction (Chat API)")
                        .font(.headline)
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

                    DebugFramingEditor(
                        label: "Text heading (Chat API)",
                        text: configuration.framing.textHeading,
                        dynamicValue: "USER_TEXT",
                        valueOnNewLine: true
                    )
                    DebugFramingEditor(
                        label: "Suffix heading",
                        text: configuration.framing.suffixHeading,
                        dynamicValue: "TEXT_AFTER_CURSOR",
                        valueOnNewLine: true
                    )
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
                    Label("Debug mode", systemImage: "ladybug")
                        .font(.headline)
                    Text(
                        "Reveal the editable framing used around every "
                            + "dynamic prompt component."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Debug mode", isOn: configuration.debugMode)
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

                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(width: 54, alignment: .trailing)
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
                Text(dynamicValue)
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.purple.opacity(0.11), in: Capsule())
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}
