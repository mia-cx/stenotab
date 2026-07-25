import CompletionCore
import Foundation

struct StoredTextReference: Codable, Sendable, Equatable {
    let chunkHMACs: [Data]
    let utf8ByteCount: Int
}

struct StoredTextDelta: Codable, Sendable, Equatable {
    let retainedPrefixCount: Int
    let retainedSuffixCount: Int
    let replacement: Data

    init(from original: String, to updated: String) {
        let originalBytes = Array(original.utf8)
        let updatedBytes = Array(updated.utf8)
        var prefixCount = 0
        while
            prefixCount < originalBytes.count,
            prefixCount < updatedBytes.count,
            originalBytes[prefixCount] == updatedBytes[prefixCount]
        {
            prefixCount += 1
        }

        var suffixCount = 0
        while
            suffixCount < originalBytes.count - prefixCount,
            suffixCount < updatedBytes.count - prefixCount,
            originalBytes[originalBytes.count - suffixCount - 1]
                == updatedBytes[updatedBytes.count - suffixCount - 1]
        {
            suffixCount += 1
        }

        retainedPrefixCount = prefixCount
        retainedSuffixCount = suffixCount
        replacement = Data(
            updatedBytes[
                prefixCount..<(updatedBytes.count - suffixCount)
            ]
        )
    }

    func applying(to original: String) -> String? {
        let bytes = Array(original.utf8)
        guard
            retainedPrefixCount >= 0,
            retainedSuffixCount >= 0,
            retainedPrefixCount + retainedSuffixCount <= bytes.count
        else {
            return nil
        }
        var updated = Array(bytes.prefix(retainedPrefixCount))
        updated.append(contentsOf: replacement)
        updated.append(contentsOf: bytes.suffix(retainedSuffixCount))
        return String(bytes: updated, encoding: .utf8)
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
    let sourceEventIDs: [UUID]?
    let sourceContexts: [PersonalizationContext]?
    let collectionGeneration: UInt64?
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
    static let currentStorageVersion = 4

    let storageVersion: Int
    let id: UUID
    let invocation: StoredCompletionInvocation
    let suggestionRevisions: [StoredCompletionSuggestionRevision]
    let acceptances: [CompletionAcceptanceCapture]
    let typedThroughText: String
    let generationDidFail: Bool?
    let resolution: CompletionEpisodeResolution
    let finalFieldTextDelta: StoredTextDelta
    let finalFieldSelection: UTF16Selection
    let actualInsertedText: String?
    let endedAt: Date

    var referencedChunkHMACs: Set<Data> {
        var references = Set(invocation.field.text.chunkHMACs)
        for promptReference in [
            invocation.prompt.systemMessage,
            invocation.prompt.userMessage,
            invocation.prompt.textPrompt,
        ].compactMap({ $0 }) {
            references.formUnion(promptReference.chunkHMACs)
        }
        return references
    }

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
                sourceEventIDs: invocation.sourceEventIDs ?? [],
                sourceContexts: invocation.sourceContexts ?? [],
                collectionGeneration: invocation.collectionGeneration,
                startedAt: invocation.startedAt
            ),
            suggestionRevisions: revisions,
            acceptances: acceptances,
            typedThroughText: typedThroughText,
            generationDidFail: generationDidFail ?? false,
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
