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
    public let endpointOrigin: String?
    public let maximumTokens: Int
    public let temperature: Double
    public let stopSequences: [String]

    public init(
        providerKind: String,
        modelIdentifier: String,
        endpointOrigin: String? = nil,
        maximumTokens: Int,
        temperature: Double,
        stopSequences: [String]
    ) {
        self.providerKind = providerKind
        self.modelIdentifier = modelIdentifier
        self.endpointOrigin = endpointOrigin
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
    public let sourceEventIDs: [UUID]
    public let sourceContexts: [PersonalizationContext]
    public let startedAt: Date

    public init(
        id: UUID,
        field: CapturedFieldState,
        prompt: CapturedCompletionPrompt,
        generation: CompletionGenerationMetadata,
        context: PersonalizationContext,
        sourceEventIDs: [UUID] = [],
        sourceContexts: [PersonalizationContext] = [],
        startedAt: Date
    ) {
        self.id = id
        self.field = field
        self.prompt = prompt
        self.generation = generation
        self.context = context
        self.sourceEventIDs = sourceEventIDs
        self.sourceContexts = sourceContexts
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case field
        case prompt
        case generation
        case context
        case sourceEventIDs
        case sourceContexts
        case startedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        field = try container.decode(CapturedFieldState.self, forKey: .field)
        prompt = try container.decode(
            CapturedCompletionPrompt.self,
            forKey: .prompt
        )
        generation = try container.decode(
            CompletionGenerationMetadata.self,
            forKey: .generation
        )
        context = try container.decode(
            PersonalizationContext.self,
            forKey: .context
        )
        sourceEventIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .sourceEventIDs
        ) ?? []
        sourceContexts = try container.decodeIfPresent(
            [PersonalizationContext].self,
            forKey: .sourceContexts
        ) ?? []
        startedAt = try container.decode(Date.self, forKey: .startedAt)
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
    public var acceptedText: String {
        acceptances.map(\.text).joined()
    }
    public let typedThroughText: String
    public let generationDidFail: Bool
    public let resolution: CompletionEpisodeResolution
    public let finalField: CapturedFieldState
    public let actualInsertedText: String?
    public let endedAt: Date

    public init(
        id: UUID,
        invocation: CompletionInvocationCapture,
        suggestionRevisions: [CompletionSuggestionRevision],
        acceptances: [CompletionAcceptanceCapture],
        typedThroughText: String,
        generationDidFail: Bool = false,
        resolution: CompletionEpisodeResolution,
        finalField: CapturedFieldState,
        actualInsertedText: String?,
        endedAt: Date
    ) {
        self.id = id
        self.invocation = invocation
        self.suggestionRevisions = suggestionRevisions
        self.acceptances = acceptances
        self.typedThroughText = typedThroughText
        self.generationDidFail = generationDidFail
        self.resolution = resolution
        self.finalField = finalField
        self.actualInsertedText = actualInsertedText
        self.endedAt = endedAt
    }
}

public enum CompletionEpisodeReconciliationDecision:
    Sendable,
    Equatable
{
    case waitForAuthoritativeChange
    case reconcile
    case finalizeFromAuthoritativeBaselineAndReconcile
}

public enum CompletionEpisodeReconciliationPolicy {
    public static func decision(
        previousEditorIdentifier: String?,
        observedEditorIdentifier: String,
        authoritativeBaselineField: CapturedFieldState?,
        expectedField: CapturedFieldState?,
        observedField: CapturedFieldState,
        requiresPostEventObservation: Bool = false,
        observationDeadlineExceeded: Bool = false
    ) -> CompletionEpisodeReconciliationDecision {
        guard
            let authoritativeBaselineField,
            let expectedField
        else {
            return .reconcile
        }
        let focusChanged =
            previousEditorIdentifier != observedEditorIdentifier
        if
            !focusChanged,
            observedField == authoritativeBaselineField,
            (
                expectedField != authoritativeBaselineField
                    || requiresPostEventObservation
            ),
            !observationDeadlineExceeded
        {
            return .waitForAuthoritativeChange
        }
        if focusChanged {
            return .finalizeFromAuthoritativeBaselineAndReconcile
        }
        return .reconcile
    }
}

public enum CompletionEpisodeDeletionBoundaryPolicy {
    public static func allowsCapture(
        invocationStartedAt: Date,
        deleteAllAt: Date?,
        applicationDeletedAt: Date?
    ) -> Bool {
        if let deleteAllAt, invocationStartedAt <= deleteAllAt {
            return false
        }
        if
            let applicationDeletedAt,
            invocationStartedAt <= applicationDeletedAt
        {
            return false
        }
        return true
    }
}

public enum CompletionEpisodePendingResolutionPolicy {
    public static func resolve(
        existing: CompletionEpisodeResolution?,
        proposed: CompletionEpisodeResolution
    ) -> CompletionEpisodeResolution {
        existing ?? proposed
    }
}

public enum CompletionEpisodeLiveEditorPolicy {
    public static func allowsCapture(
        activeEditorIdentifier: String?,
        liveEditorIdentifier: String?
    ) -> Bool {
        guard
            let activeEditorIdentifier,
            let liveEditorIdentifier
        else {
            return false
        }
        return activeEditorIdentifier == liveEditorIdentifier
    }
}

public struct CompletionEpisodeTracker: Sendable {
    // OpenAICompatibleCompletionProvider stops after 4,096 sanitized
    // characters. A cumulative stream can therefore expose at most this many
    // distinct growing revisions in production.
    private static let maximumRecordedSuggestionRevisions = 4_096

    private struct ActiveEpisode: Sendable {
        let invocation: CompletionInvocationCapture
        var suggestionRevisions: [CompletionSuggestionRevision]
        var acceptances: [CompletionAcceptanceCapture]
        var typedThroughText: String
        var generationDidFail: Bool
        var acceptedCharacterRanges: [Range<Int>]
        var confirmedConsumedCharacterCount: Int
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

    public var hasSuggestionRevisions: Bool {
        !(active?.suggestionRevisions.isEmpty ?? true)
    }

    public var abandonedSuggestionResolution:
        CompletionEpisodeResolution
    {
        hasAcceptedText ? .partiallyAccepted : .rejected
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
            typedThroughText: "",
            generationDidFail: false,
            acceptedCharacterRanges: [],
            confirmedConsumedCharacterCount: 0
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
        } else if
            active.suggestionRevisions.count
                < Self.maximumRecordedSuggestionRevisions
        {
            active.suggestionRevisions.append(revision)
        } else {
            active.suggestionRevisions[
                active.suggestionRevisions.count - 1
            ] = revision
        }
        self.active = active
    }

    public mutating func recordAcceptance(
        _ text: String,
        scope: SuggestionAcceptance.Scope,
        at date: Date = Date()
    ) {
        guard !text.isEmpty, var active else { return }
        let rangeStart = active.confirmedConsumedCharacterCount
        let rangeEnd = rangeStart + text.count
        active.acceptedCharacterRanges.append(rangeStart..<rangeEnd)
        active.confirmedConsumedCharacterCount = rangeEnd
        active.acceptances.append(
            CompletionAcceptanceCapture(
                text: text,
                scope: scope,
                acceptedAt: date
            )
        )
        self.active = active
    }

    public mutating func synchronizeTypedThrough(
        consumedSuggestionText: String
    ) {
        guard var active else { return }
        let consumedCharacters = Array(consumedSuggestionText)
        active.confirmedConsumedCharacterCount = consumedCharacters.count
        active.typedThroughText = String(
            consumedCharacters.enumerated().compactMap { index, character in
                active.acceptedCharacterRanges.contains {
                    $0.contains(index)
                } ? nil : character
            }
        )
        self.active = active
    }

    public mutating func recordGenerationFailure() {
        guard var active else { return }
        active.generationDidFail = true
        self.active = active
    }

    public mutating func markSuggestionFinalIfObserved(
        _ text: String,
        at date: Date = Date()
    ) {
        guard
            var active,
            active.suggestionRevisions.last?.text == text
        else {
            return
        }
        active.suggestionRevisions[
            active.suggestionRevisions.count - 1
        ] = CompletionSuggestionRevision(
            text: text,
            isFinal: true,
            observedAt: date
        )
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
            typedThroughText: active.typedThroughText,
            generationDidFail: active.generationDidFail,
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
