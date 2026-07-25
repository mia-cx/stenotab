import Foundation

public enum CompletionPromptTransport: String, Codable, Sendable, Equatable {
    case textCompletion = "text_completion"
    case chatCompletion = "chat_completion"
    case assistantPrefill = "assistant_prefill"
}

public struct CapturedCompletionPrompt: Codable, Sendable, Equatable {
    public let transport: CompletionPromptTransport
    public let systemMessage: String?
    public let userMessage: String?
    public let textPrompt: String?

    public init(
        transport: CompletionPromptTransport,
        systemMessage: String? = nil,
        userMessage: String? = nil,
        textPrompt: String? = nil
    ) {
        self.transport = transport
        self.systemMessage = systemMessage
        self.userMessage = userMessage
        self.textPrompt = textPrompt
    }
}

public struct CompletionGenerationMetadata:
    Codable,
    Sendable,
    Equatable
{
    public let providerKind: String
    public let modelIdentifier: String
    public let maximumTokens: Int
    public let temperature: Double
    public let stopSequences: [String]

    public init(
        providerKind: String,
        modelIdentifier: String,
        maximumTokens: Int,
        temperature: Double,
        stopSequences: [String]
    ) {
        self.providerKind = providerKind
        self.modelIdentifier = modelIdentifier
        self.maximumTokens = maximumTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
    }
}

public struct CompletionInvocationCapture:
    Codable,
    Sendable,
    Equatable
{
    public let id: UUID
    public let field: CapturedFieldState
    public let prompt: CapturedCompletionPrompt
    public let generation: CompletionGenerationMetadata
    public let context: PersonalizationContext
    public let startedAt: Date

    public init(
        id: UUID,
        field: CapturedFieldState,
        prompt: CapturedCompletionPrompt,
        generation: CompletionGenerationMetadata,
        context: PersonalizationContext,
        startedAt: Date
    ) {
        self.id = id
        self.field = field
        self.prompt = prompt
        self.generation = generation
        self.context = context
        self.startedAt = startedAt
    }
}

public struct CompletionSuggestionRevision:
    Codable,
    Sendable,
    Equatable
{
    public let text: String
    public let isFinal: Bool
    public let observedAt: Date

    public init(text: String, isFinal: Bool, observedAt: Date) {
        self.text = text
        self.isFinal = isFinal
        self.observedAt = observedAt
    }
}

public struct CompletionAcceptanceCapture:
    Codable,
    Sendable,
    Equatable
{
    public let text: String
    public let scope: SuggestionAcceptance.Scope
    public let acceptedAt: Date

    public init(
        text: String,
        scope: SuggestionAcceptance.Scope,
        acceptedAt: Date
    ) {
        self.text = text
        self.scope = scope
        self.acceptedAt = acceptedAt
    }
}

public enum CompletionEpisodeResolution:
    String,
    Codable,
    Sendable,
    Equatable
{
    case accepted
    case partiallyAccepted = "partially_accepted"
    case typedThrough = "typed_through"
    case rejected
    case superseded
    case failed
}

public struct CompletionEpisodeCapture: Codable, Sendable, Equatable {
    public let id: UUID
    public let invocation: CompletionInvocationCapture
    public let suggestionRevisions: [CompletionSuggestionRevision]
    public let acceptances: [CompletionAcceptanceCapture]
    public let acceptedText: String
    public let typedThroughText: String
    public let resolution: CompletionEpisodeResolution
    public let finalField: CapturedFieldState
    public let actualInsertedText: String?
    public let endedAt: Date

    public init(
        id: UUID,
        invocation: CompletionInvocationCapture,
        suggestionRevisions: [CompletionSuggestionRevision],
        acceptances: [CompletionAcceptanceCapture],
        acceptedText: String,
        typedThroughText: String,
        resolution: CompletionEpisodeResolution,
        finalField: CapturedFieldState,
        actualInsertedText: String?,
        endedAt: Date
    ) {
        self.id = id
        self.invocation = invocation
        self.suggestionRevisions = suggestionRevisions
        self.acceptances = acceptances
        self.acceptedText = acceptedText
        self.typedThroughText = typedThroughText
        self.resolution = resolution
        self.finalField = finalField
        self.actualInsertedText = actualInsertedText
        self.endedAt = endedAt
    }
}

public struct CompletionEpisodeTracker: Sendable {
    private struct ActiveEpisode: Sendable {
        let invocation: CompletionInvocationCapture
        var suggestionRevisions: [CompletionSuggestionRevision]
        var acceptances: [CompletionAcceptanceCapture]
        var typedThroughText: String
    }

    private var active: ActiveEpisode?

    public init() {}

    public var activeInvocationID: UUID? {
        active?.invocation.id
    }

    public var activeInitialField: CapturedFieldState? {
        active?.invocation.field
    }

    public var hasAcceptedText: Bool {
        !(active?.acceptances.isEmpty ?? true)
    }

    public var completedSuggestionResolution:
        CompletionEpisodeResolution?
    {
        guard let active else { return nil }
        let hasAcceptedText = !active.acceptances.isEmpty
        let hasTypedThroughText = !active.typedThroughText.isEmpty

        switch (hasAcceptedText, hasTypedThroughText) {
        case (true, true):
            return .partiallyAccepted
        case (true, false):
            return .accepted
        case (false, true):
            return .typedThrough
        case (false, false):
            return .rejected
        }
    }

    public mutating func begin(_ invocation: CompletionInvocationCapture) {
        active = ActiveEpisode(
            invocation: invocation,
            suggestionRevisions: [],
            acceptances: [],
            typedThroughText: ""
        )
    }

    public mutating func discard() {
        active = nil
    }

    public mutating func observeSuggestion(
        _ text: String,
        isFinal: Bool,
        at date: Date = Date()
    ) {
        guard !text.isEmpty, var active else { return }
        let revision = CompletionSuggestionRevision(
            text: text,
            isFinal: isFinal,
            observedAt: date
        )
        if active.suggestionRevisions.last?.text == text {
            active.suggestionRevisions[
                active.suggestionRevisions.count - 1
            ] = revision
        } else {
            active.suggestionRevisions.append(revision)
        }
        self.active = active
    }

    public mutating func recordAcceptance(
        _ text: String,
        scope: SuggestionAcceptance.Scope,
        at date: Date = Date()
    ) {
        guard !text.isEmpty, var active else { return }
        active.acceptances.append(
            CompletionAcceptanceCapture(
                text: text,
                scope: scope,
                acceptedAt: date
            )
        )
        self.active = active
    }

    public mutating func recordTypedThrough(_ text: String) {
        guard !text.isEmpty, var active else { return }
        active.typedThroughText += text
        self.active = active
    }

    public mutating func finalize(
        resolution: CompletionEpisodeResolution,
        finalField: CapturedFieldState,
        at date: Date = Date()
    ) -> CompletionEpisodeCapture? {
        guard
            let active,
            !active.suggestionRevisions.isEmpty,
            finalField.selection.isValid(for: finalField.text)
        else {
            return nil
        }
        self.active = nil
        return CompletionEpisodeCapture(
            id: active.invocation.id,
            invocation: active.invocation,
            suggestionRevisions: active.suggestionRevisions,
            acceptances: active.acceptances,
            acceptedText: active.acceptances.map(\.text).joined(),
            typedThroughText: active.typedThroughText,
            resolution: resolution,
            finalField: finalField,
            actualInsertedText: insertedText(
                from: active.invocation.field,
                to: finalField
            ),
            endedAt: date
        )
    }

    private func insertedText(
        from initial: CapturedFieldState,
        to final: CapturedFieldState
    ) -> String? {
        guard initial.selection.isValid(for: initial.text) else {
            return nil
        }
        let initialUTF16 = Array(initial.text.utf16)
        let finalUTF16 = Array(final.text.utf16)
        let selectionStart = initial.selection.location
        let selectionEnd = selectionStart + initial.selection.length
        let prefix = initialUTF16[..<selectionStart]
        let suffix = initialUTF16[selectionEnd...]
        guard
            finalUTF16.starts(with: prefix),
            finalUTF16.suffix(suffix.count).elementsEqual(suffix),
            finalUTF16.count >= prefix.count + suffix.count
        else {
            return nil
        }
        let insertionEnd = finalUTF16.count - suffix.count
        return String(
            decoding: finalUTF16[selectionStart..<insertionEnd],
            as: UTF16.self
        )
    }
}
