import CompletionCore
import Foundation

struct StoredTextReference: Codable, Sendable, Equatable {
    let chunkHMACs: [Data]
    let utf8ByteCount: Int
}

struct StoredTextDelta: Codable, Sendable, Equatable {
    let retainedPrefixCount: Int
    let retainedSuffixCount: Int
    let replacement: String

    init(from original: String, to updated: String) {
        let originalCharacters = Array(original)
        let updatedCharacters = Array(updated)
        var prefixCount = 0
        while
            prefixCount < originalCharacters.count,
            prefixCount < updatedCharacters.count,
            originalCharacters[prefixCount]
                == updatedCharacters[prefixCount]
        {
            prefixCount += 1
        }

        var suffixCount = 0
        while
            suffixCount < originalCharacters.count - prefixCount,
            suffixCount < updatedCharacters.count - prefixCount,
            originalCharacters[originalCharacters.count - suffixCount - 1]
                == updatedCharacters[updatedCharacters.count - suffixCount - 1]
        {
            suffixCount += 1
        }

        retainedPrefixCount = prefixCount
        retainedSuffixCount = suffixCount
        replacement = String(
            updatedCharacters[
                prefixCount..<(updatedCharacters.count - suffixCount)
            ]
        )
    }

    func applying(to original: String) -> String? {
        let characters = Array(original)
        guard
            retainedPrefixCount >= 0,
            retainedSuffixCount >= 0,
            retainedPrefixCount + retainedSuffixCount <= characters.count
        else {
            return nil
        }
        return String(characters.prefix(retainedPrefixCount))
            + replacement
            + String(characters.suffix(retainedSuffixCount))
    }
}

struct StoredCompletionField: Codable, Sendable, Equatable {
    let text: StoredTextReference
    let selection: UTF16Selection
}

struct StoredCompletionPrompt: Codable, Sendable, Equatable {
    let transport: CompletionPromptTransport
    let systemMessage: StoredTextReference?
    let userMessage: StoredTextReference?
    let textPrompt: StoredTextReference?
}

struct StoredCompletionInvocation: Codable, Sendable, Equatable {
    let id: UUID
    let field: StoredCompletionField
    let prompt: StoredCompletionPrompt
    let generation: CompletionGenerationMetadata
    let context: PersonalizationContext
    let startedAt: Date
}

struct StoredCompletionSuggestionRevision:
    Codable,
    Sendable,
    Equatable
{
    let textDelta: StoredTextDelta
    let isFinal: Bool
    let observedAt: Date
}

struct StoredCompletionEpisode: Codable, Sendable, Equatable {
    static let currentStorageVersion = 1

    let storageVersion: Int
    let id: UUID
    let invocation: StoredCompletionInvocation
    let suggestionRevisions: [StoredCompletionSuggestionRevision]
    let acceptances: [CompletionAcceptanceCapture]
    let typedThroughText: String
    let resolution: CompletionEpisodeResolution
    let finalFieldTextDelta: StoredTextDelta
    let finalFieldSelection: UTF16Selection
    let actualInsertedText: String?
    let endedAt: Date

    func hydrated(
        loadText: (StoredTextReference) throws -> String
    ) throws -> CompletionEpisodeCapture {
        let initialText = try loadText(invocation.field.text)
        let initialField = CapturedFieldState(
            text: initialText,
            selection: invocation.field.selection
        )
        guard
            let finalText = finalFieldTextDelta.applying(to: initialText)
        else {
            throw PersonalizationPersistenceError.database(
                "Invalid completion episode final-field delta"
            )
        }

        var previousSuggestion = ""
        let revisions = try suggestionRevisions.map { stored in
            guard
                let text = stored.textDelta.applying(
                    to: previousSuggestion
                )
            else {
                throw PersonalizationPersistenceError.database(
                    "Invalid completion episode suggestion delta"
                )
            }
            previousSuggestion = text
            return CompletionSuggestionRevision(
                text: text,
                isFinal: stored.isFinal,
                observedAt: stored.observedAt
            )
        }

        return CompletionEpisodeCapture(
            id: id,
            invocation: CompletionInvocationCapture(
                id: invocation.id,
                field: initialField,
                prompt: CapturedCompletionPrompt(
                    transport: invocation.prompt.transport,
                    systemMessage: try invocation.prompt.systemMessage.map {
                        try loadText($0)
                    },
                    userMessage: try invocation.prompt.userMessage.map {
                        try loadText($0)
                    },
                    textPrompt: try invocation.prompt.textPrompt.map {
                        try loadText($0)
                    }
                ),
                generation: invocation.generation,
                context: invocation.context,
                startedAt: invocation.startedAt
            ),
            suggestionRevisions: revisions,
            acceptances: acceptances,
            acceptedText: acceptances.map(\.text).joined(),
            typedThroughText: typedThroughText,
            resolution: resolution,
            finalField: CapturedFieldState(
                text: finalText,
                selection: finalFieldSelection
            ),
            actualInsertedText: actualInsertedText,
            endedAt: endedAt
        )
    }
}

struct StoredCompletionEpisodeHeader: Decodable {
    let storageVersion: Int
}

public struct CompletionEpisodeStorageStatistics:
    Sendable,
    Equatable
{
    public let uniqueTextChunkCount: Int
    public let textChunkReferenceCount: Int
    public let encryptedTextChunkBytes: Int

    public init(
        uniqueTextChunkCount: Int,
        textChunkReferenceCount: Int,
        encryptedTextChunkBytes: Int
    ) {
        self.uniqueTextChunkCount = uniqueTextChunkCount
        self.textChunkReferenceCount = textChunkReferenceCount
        self.encryptedTextChunkBytes = encryptedTextChunkBytes
    }
}
