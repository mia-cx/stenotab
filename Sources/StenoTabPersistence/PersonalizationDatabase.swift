import CompletionCore
import Foundation
import SQLite3

public enum PersonalizationPersistenceError: Error, Equatable {
    case database(String)
    case encryptionFailed
    case invalidKeyLength(expected: Int, actual: Int)
    case keychain(OSStatus)
    case unsupportedEventKind(String)
}

public struct PersonalizationRetentionPolicy: Sendable, Equatable {
    public let maximumAge: TimeInterval?
    public let maximumEncryptedBytes: Int?

    public init(
        maximumAge: TimeInterval?,
        maximumEncryptedBytes: Int?
    ) {
        self.maximumAge = maximumAge
        self.maximumEncryptedBytes = maximumEncryptedBytes
    }
}

public struct PersonalizationStorageStatistics: Sendable, Equatable {
    public let eventCount: Int
    public let encryptedPayloadBytes: Int
    public let oldestEventAt: Date?
    public let newestEventAt: Date?

    public init(
        eventCount: Int,
        encryptedPayloadBytes: Int,
        oldestEventAt: Date?,
        newestEventAt: Date?
    ) {
        self.eventCount = eventCount
        self.encryptedPayloadBytes = encryptedPayloadBytes
        self.oldestEventAt = oldestEventAt
        self.newestEventAt = newestEventAt
    }
}

public struct PendingConsentReconciliationResult: Sendable, Equatable {
    public let promotedCount: Int
    public let removedCount: Int
}

public struct PersonalizationCorpusExport: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case exportedAt
        case acceptedSuggestions
        case completionFeedback
        case writingEpisodes
        case completionEpisodes
    }

    public let formatVersion: Int
    public let exportedAt: Date
    public let acceptedSuggestions: [AcceptedSuggestionCapture]
    public let completionFeedback: [CompletionFeedbackCapture]
    public let writingEpisodes: [WritingEpisodeCapture]
    public let completionEpisodes: [CompletionEpisodeCapture]

    public init(
        formatVersion: Int = 2,
        exportedAt: Date,
        acceptedSuggestions: [AcceptedSuggestionCapture],
        completionFeedback: [CompletionFeedbackCapture],
        writingEpisodes: [WritingEpisodeCapture],
        completionEpisodes: [CompletionEpisodeCapture]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.acceptedSuggestions = acceptedSuggestions
        self.completionFeedback = completionFeedback
        self.writingEpisodes = writingEpisodes
        self.completionEpisodes = completionEpisodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        acceptedSuggestions = try container.decode(
            [AcceptedSuggestionCapture].self,
            forKey: .acceptedSuggestions
        )
        completionFeedback = try container.decode(
            [CompletionFeedbackCapture].self,
            forKey: .completionFeedback
        )
        writingEpisodes = try container.decode(
            [WritingEpisodeCapture].self,
            forKey: .writingEpisodes
        )
        completionEpisodes = try container.decodeIfPresent(
            [CompletionEpisodeCapture].self,
            forKey: .completionEpisodes
        ) ?? []
    }
}

public struct StoredPersonalizationEmbedding: Sendable, Equatable {
    public let eventID: UUID
    public let modelIdentifier: String
    public let vector: [Double]
    public let createdAt: Date

    public init(
        eventID: UUID,
        modelIdentifier: String,
        vector: [Double],
        createdAt: Date
    ) {
        self.eventID = eventID
        self.modelIdentifier = modelIdentifier
        self.vector = vector
        self.createdAt = createdAt
    }
}

public actor PersonalizationDatabase {
    private static let acceptedSuggestionKind = "accepted_suggestion"
    private static let completionFeedbackKind = "completion_feedback"
    private static let writingEpisodeKind = "writing_episode"
    private static let completionEpisodeKind = "completion_episode"
    private static let languageModelProjection = "personal_language_model"
    private static let voiceAssessmentProjection = "voice_assessment"
    private static let keyVersion = 1
    private static let textChunkByteCount = 256
    private static let authenticatedConsentSchemaVersion = 1
    private static let authenticatedConsentSchemaMarker =
        "authenticated_consent_schema"

    private let connection: SQLiteConnection
    private let keyData: Data
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        databaseURL: URL,
        keyProvider: any PersonalizationKeyProviding
    ) throws {
        keyData = try keyProvider.keyData()
        guard keyData.count == PersonalizationCryptography.keyByteCount else {
            throw PersonalizationPersistenceError.invalidKeyLength(
                expected: PersonalizationCryptography.keyByteCount,
                actual: keyData.count
            )
        }

        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        connection = try SQLiteConnection(databaseURL: databaseURL)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA recursive_triggers = ON")
        try connection.execute("PRAGMA journal_mode = DELETE")
        try connection.execute("PRAGMA secure_delete = ON")
        let schemaVersion = Int(
            try connection.query("PRAGMA user_version")
                .first?.integer(at: 0) ?? 0
        )
        let externalSchemaVersion =
            try keyProvider.authenticatedConsentSchemaVersion()
        try connection.execute(Self.schema)
        try connection.execute(Self.remainingSchema)
        if let externalSchemaVersion {
            guard
                externalSchemaVersion
                    == Self.authenticatedConsentSchemaVersion
            else {
                throw PersonalizationPersistenceError.database(
                    "Unsupported authenticated consent schema version"
                )
            }
            try Self.validateAuthenticatedConsentSchema(
                connection: connection,
                keyData: keyData,
                schemaVersion: schemaVersion
            )
        } else if schemaVersion < Self.authenticatedConsentSchemaVersion {
            try Self.migrateAuthenticatedConsentState(
                connection: connection,
                keyData: keyData
            )
            try keyProvider.persistAuthenticatedConsentSchemaVersion(
                Self.authenticatedConsentSchemaVersion
            )
        } else {
            try Self.validateAuthenticatedConsentSchema(
                connection: connection,
                keyData: keyData,
                schemaVersion: schemaVersion
            )
            // A previous database migration may have committed before its
            // Keychain anchor was written. Validate the authenticated in-DB
            // marker first, then repair only the missing external anchor.
            try keyProvider.persistAuthenticatedConsentSchemaVersion(
                Self.authenticatedConsentSchemaVersion
            )
        }
        try Self.migrateScopeLookupHMACs(
            connection: connection,
            keyData: keyData
        )
        try Self.removeLegacyCompletionEpisodesWithoutLineage(
            connection: connection,
            keyData: keyData,
            decoder: decoder
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
    }

    private static func migrateAuthenticatedConsentState(
        connection: SQLiteConnection,
        keyData: Data
    ) throws {
        try connection.transaction {
            try connection.execute(Self.authenticatedConsentSchema)
            let rows = try connection.query(
                """
                SELECT
                    event.id,
                    pending.rowid,
                    pending.collection_generation,
                    pending.direct_typing_generation
                FROM personalization_event AS event
                LEFT JOIN personalization_event_consent AS consent
                    ON consent.event_id = event.id
                LEFT JOIN pending_consent_event AS pending
                    ON pending.event_id = event.id
                WHERE consent.event_id IS NULL
                """
            )
            for row in rows {
                guard let eventID = row.text(at: 0) else { continue }
                let hasPendingMarker = row.integer(at: 1) != nil
                let collectionGeneration: String
                let directTypingGeneration: String
                let status: String
                if hasPendingMarker {
                    guard
                        let storedCollection = row.text(at: 2),
                        UInt64(storedCollection) != nil,
                        let storedDirect = row.text(at: 3),
                        storedDirect.isEmpty || UInt64(storedDirect) != nil
                    else {
                        try connection.execute(
                            """
                            DELETE FROM completion_episode_source
                            WHERE source_event_id = ?
                            """,
                            bindings: [.text(eventID)]
                        )
                        try connection.execute(
                            """
                            DELETE FROM personalization_event
                            WHERE id = ?
                            """,
                            bindings: [.text(eventID)]
                        )
                        continue
                    }
                    status = "pending"
                    collectionGeneration = storedCollection
                    directTypingGeneration = storedDirect
                } else {
                    status = "finalized"
                    collectionGeneration = ""
                    directTypingGeneration = ""
                }
                let stateHMAC = try consentStateHMAC(
                    eventID: eventID,
                    status: status,
                    collectionGeneration: collectionGeneration,
                    directTypingGeneration: directTypingGeneration,
                    keyData: keyData
                )
                try connection.execute(
                    """
                    INSERT INTO personalization_event_consent (
                        event_id,
                        status,
                        collection_generation,
                        direct_typing_generation,
                        state_hmac
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(eventID),
                        .text(status),
                        .text(collectionGeneration),
                        .text(directTypingGeneration),
                        .blob(stateHMAC),
                    ]
                )
            }
            let markerValue = String(authenticatedConsentSchemaVersion)
            let markerHMAC = try schemaStateHMAC(
                name: authenticatedConsentSchemaMarker,
                value: markerValue,
                keyData: keyData
            )
            try connection.execute(
                """
                INSERT INTO personalization_schema_state (
                    name,
                    value,
                    state_hmac
                ) VALUES (?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET
                    value = excluded.value,
                    state_hmac = excluded.state_hmac
                """,
                bindings: [
                    .text(authenticatedConsentSchemaMarker),
                    .text(markerValue),
                    .blob(markerHMAC),
                ]
            )
            try connection.execute(
                "PRAGMA user_version = \(authenticatedConsentSchemaVersion)"
            )
        }
    }

    private static func validateAuthenticatedConsentSchema(
        connection: SQLiteConnection,
        keyData: Data,
        schemaVersion: Int
    ) throws {
        guard schemaVersion == authenticatedConsentSchemaVersion else {
            throw PersonalizationPersistenceError.database(
                "Invalid authenticated consent schema version"
            )
        }
        let requiredTables = [
            "personalization_event_consent",
            "personalization_schema_state",
        ]
        for table in requiredTables {
            let exists = try connection.query(
                """
                SELECT 1
                FROM sqlite_master
                WHERE type = 'table' AND name = ?
                LIMIT 1
                """,
                bindings: [.text(table)]
            ).first != nil
            guard exists else {
                throw PersonalizationPersistenceError.database(
                    "Missing authenticated consent schema"
                )
            }
        }
        let row = try connection.query(
            """
            SELECT value, state_hmac
            FROM personalization_schema_state
            WHERE name = ?
            """,
            bindings: [.text(authenticatedConsentSchemaMarker)]
        ).first
        let expectedValue = String(authenticatedConsentSchemaVersion)
        let expectedHMAC = try schemaStateHMAC(
            name: authenticatedConsentSchemaMarker,
            value: expectedValue,
            keyData: keyData
        )
        guard
            row?.text(at: 0) == expectedValue,
            row?.blob(at: 1) == expectedHMAC
        else {
            throw PersonalizationPersistenceError.database(
                "Invalid authenticated consent schema marker"
            )
        }
    }

    private static func schemaStateHMAC(
        name: String,
        value: String,
        keyData: Data
    ) throws -> Data {
        try PersonalizationCryptography.scopeLookupHMAC(
            kind: "personalization_schema_state_v1",
            value: name + "\u{0}" + value,
            keyData: keyData
        )
    }

    private static func consentStateHMAC(
        eventID: String,
        status: String,
        collectionGeneration: String,
        directTypingGeneration: String,
        keyData: Data
    ) throws -> Data {
        try PersonalizationCryptography.scopeLookupHMAC(
            kind: "personalization_event_consent_v1",
            value:
                eventID + "\u{0}" + status + "\u{0}"
                + collectionGeneration + "\u{0}"
                + directTypingGeneration,
            keyData: keyData
        )
    }

    private static func removeLegacyCompletionEpisodesWithoutLineage(
        connection: SQLiteConnection,
        keyData: Data,
        decoder: JSONDecoder
    ) throws {
        struct EventIdentity: Decodable {
            let id: UUID
        }
        let rows = try connection.query(
            """
            SELECT id, kind, payload_sealed, payload_hmac
            FROM personalization_event
            """
        )
        var legacyIDs: [String] = []
        var currentEpisodes: [StoredCompletionEpisode] = []
        for row in rows {
            guard
                let id = row.text(at: 0),
                let kind = row.text(at: 1),
                let sealedPayload = row.blob(at: 2),
                let storedHMAC = row.blob(at: 3)
            else {
                return
            }
            guard
                let payload = try? PersonalizationCryptography.open(
                    sealedPayload,
                    keyData: keyData
                )
            else {
                // Leave unreadable rows untouched. The database must still
                // attach so the user can inspect the error or use Delete All.
                return
            }
            guard
                let expectedHMAC =
                    try? PersonalizationCryptography.payloadHMAC(
                        for: payload,
                        keyData: keyData
                    ),
                storedHMAC == expectedHMAC,
                let identity = try? decoder.decode(
                    EventIdentity.self,
                    from: payload
                ),
                identity.id.uuidString == id
            else {
                // Never make a destructive migration decision from a payload
                // that is not authenticated to this row.
                return
            }
            guard
                let header = try? decoder.decode(
                    StoredCompletionEpisodeHeader.self,
                    from: payload
                )
            else {
                if
                    let legacy = try? decoder.decode(
                        CompletionEpisodeCapture.self,
                        from: payload
                    ),
                    legacy.id.uuidString == id
                {
                    legacyIDs.append(id)
                } else if kind == Self.completionEpisodeKind {
                    // A row claiming to be a completion episode could be
                    // corrupt or a different event with a substituted kind.
                    // Leave the database untouched rather than using that
                    // unauthenticated index value destructively.
                    return
                } else {
                    continue
                }
                continue
            }
            if
                header.storageVersion
                    == StoredCompletionEpisode.currentStorageVersion
            {
                guard
                    let stored = try? decoder.decode(
                        StoredCompletionEpisode.self,
                        from: payload
                    ),
                    stored.id.uuidString == id
                else {
                    return
                }
                currentEpisodes.append(stored)
            } else if
                header.storageVersion
                    < StoredCompletionEpisode.currentStorageVersion
            {
                if
                    let stored = try? decoder.decode(
                        StoredCompletionEpisode.self,
                        from: payload
                    ),
                    stored.id.uuidString == id
                {
                    legacyIDs.append(id)
                }
            } else {
                // A newer build owns this storage version. Leave the database
                // untouched so Delete All remains available.
                return
            }
        }
        guard !legacyIDs.isEmpty else { return }

        for episode in currentEpisodes {
            for chunkHMAC in episode.referencedChunkHMACs {
                let row = try connection.query(
                    """
                    SELECT payload_sealed, plaintext_byte_count
                    FROM personalization_text_chunk
                    WHERE chunk_hmac = ?
                    """,
                    bindings: [.blob(chunkHMAC)]
                ).first
                guard
                    let sealed = row?.blob(at: 0),
                    let expectedByteCount = row?.integer(at: 1),
                    let chunk = try? PersonalizationCryptography.open(
                        sealed,
                        keyData: keyData
                    ),
                    chunk.count == Int(expectedByteCount),
                    let authenticatedHMAC =
                        try? PersonalizationCryptography.payloadHMAC(
                            for: chunk,
                            keyData: keyData
                        ),
                    authenticatedHMAC == chunkHMAC
                else {
                    // Do not run a destructive migration when a surviving
                    // current episode cannot be authenticated completely.
                    return
                }
            }
            let sourceEventIDs =
                (episode.invocation.sourceEventIDs ?? []).reduce(
                    into: [UUID]()
                ) { result, id in
                    if !result.contains(id) {
                        result.append(id)
                    }
                }
            let allSourcesExist = try sourceEventIDs.allSatisfy { id in
                try connection.query(
                    """
                    SELECT 1
                    FROM personalization_event
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(id.uuidString)]
                ).first != nil
            }
            guard allSourcesExist else { return }
        }

        try connection.transaction {
            // These are derived indexes. Rebuild them globally from
            // authenticated current payloads before legacy deletes can fire
            // source-cascade triggers or chunk garbage collection.
            try connection.execute("DELETE FROM completion_episode_source")
            try connection.execute("DELETE FROM event_text_chunk")
            for episode in currentEpisodes {
                for chunkHMAC in episode.referencedChunkHMACs {
                    try connection.execute(
                        """
                        INSERT INTO event_text_chunk (event_id, chunk_hmac)
                        VALUES (?, ?)
                        """,
                        bindings: [
                            .text(episode.id.uuidString),
                            .blob(chunkHMAC),
                        ]
                    )
                }
                let sourceEventIDs =
                    (episode.invocation.sourceEventIDs ?? []).reduce(
                        into: [UUID]()
                    ) { result, id in
                        if !result.contains(id) {
                            result.append(id)
                        }
                    }
                for sourceEventID in sourceEventIDs {
                    try connection.execute(
                        """
                        INSERT INTO completion_episode_source (
                            completion_event_id,
                            source_event_id
                        ) VALUES (?, ?)
                        """,
                        bindings: [
                            .text(episode.id.uuidString),
                            .text(sourceEventID.uuidString),
                        ]
                    )
                }
            }
            for id in legacyIDs {
                try connection.execute(
                    "DELETE FROM personalization_event WHERE id = ?",
                    bindings: [.text(id)]
                )
            }
            try connection.execute(
                """
                DELETE FROM personalization_scope
                WHERE id NOT IN (SELECT DISTINCT scope_id FROM event_scope)
                """
            )
            try connection.execute(
                """
                DELETE FROM personalization_text_chunk
                WHERE chunk_hmac NOT IN (
                    SELECT DISTINCT chunk_hmac
                    FROM event_text_chunk
                )
                """
            )
        }
    }

    private static func migrateScopeLookupHMACs(
        connection: SQLiteConnection,
        keyData: Data
    ) throws {
        try connection.transaction {
            let rows = try connection.query(
                """
                SELECT id, kind, value_sealed
                FROM personalization_scope
                ORDER BY id ASC
                """
            )
            for row in rows {
                guard
                    let id = row.integer(at: 0),
                    let kind = row.text(at: 1),
                    let sealedValue = row.blob(at: 2),
                    let opened = try? PersonalizationCryptography.open(
                        sealedValue,
                        keyData: keyData
                    ),
                    let value = String(data: opened, encoding: .utf8),
                    let migratedHMAC =
                        try? PersonalizationCryptography.scopeLookupHMAC(
                            kind: kind,
                            value: value,
                            keyData: keyData
                        )
                else {
                    throw PersonalizationPersistenceError.database(
                        "Unable to migrate encrypted personalization scope"
                    )
                }
                let existingID = try connection.query(
                    """
                    SELECT id
                    FROM personalization_scope
                    WHERE kind = ? AND lookup_hmac = ?
                    LIMIT 1
                    """,
                    bindings: [
                        .text(kind),
                        .blob(migratedHMAC),
                    ]
                ).first?.integer(at: 0)
                if let existingID, existingID != id {
                    try connection.execute(
                        """
                        INSERT OR IGNORE INTO event_scope (
                            event_id,
                            scope_id
                        )
                        SELECT event_id, ?
                        FROM event_scope
                        WHERE scope_id = ?
                        """,
                        bindings: [
                            .integer(existingID),
                            .integer(id),
                        ]
                    )
                    try connection.execute(
                        "DELETE FROM event_scope WHERE scope_id = ?",
                        bindings: [.integer(id)]
                    )
                    try connection.execute(
                        "DELETE FROM personalization_scope WHERE id = ?",
                        bindings: [.integer(id)]
                    )
                } else {
                    try connection.execute(
                        """
                        UPDATE personalization_scope
                        SET lookup_hmac = ?
                        WHERE id = ?
                        """,
                        bindings: [
                            .blob(migratedHMAC),
                            .integer(id),
                        ]
                    )
                }
            }
        }
    }

    public func record(_ capture: AcceptedSuggestionCapture) throws {
        try recordEvent(
            id: capture.id,
            kind: Self.acceptedSuggestionKind,
            capturedAt: capture.capturedAt,
            payload: capture,
            context: capture.context
        )
    }

    public func recordPendingConsent(
        _ capture: AcceptedSuggestionCapture,
        collectionGeneration: UInt64
    ) throws {
        try recordEvent(
            id: capture.id,
            kind: Self.acceptedSuggestionKind,
            capturedAt: capture.capturedAt,
            payload: capture,
            context: capture.context,
            pendingConsent: (collectionGeneration, nil)
        )
    }

    public func record(_ episode: WritingEpisodeCapture) throws {
        try recordEvent(
            id: episode.id,
            kind: Self.writingEpisodeKind,
            capturedAt: episode.endedAt,
            payload: episode,
            context: episode.context
        )
    }

    public func recordPendingConsent(
        _ episode: WritingEpisodeCapture,
        collectionGeneration: UInt64,
        directTypingGeneration: UInt64
    ) throws {
        try recordEvent(
            id: episode.id,
            kind: Self.writingEpisodeKind,
            capturedAt: episode.endedAt,
            payload: episode,
            context: episode.context,
            pendingConsent: (
                collectionGeneration,
                directTypingGeneration
            )
        )
    }

    public func record(_ feedback: CompletionFeedbackCapture) throws {
        try recordEvent(
            id: feedback.id,
            kind: Self.completionFeedbackKind,
            capturedAt: feedback.capturedAt,
            payload: feedback,
            context: feedback.context
        )
    }

    public func recordPendingConsent(
        _ feedback: CompletionFeedbackCapture,
        collectionGeneration: UInt64
    ) throws {
        try recordEvent(
            id: feedback.id,
            kind: Self.completionFeedbackKind,
            capturedAt: feedback.capturedAt,
            payload: feedback,
            context: feedback.context,
            pendingConsent: (collectionGeneration, nil)
        )
    }

    public func record(_ episode: CompletionEpisodeCapture) throws {
        try record(
            episode,
            storageVersion: StoredCompletionEpisode.currentStorageVersion,
            generationDidFail: episode.generationDidFail,
            pendingConsent: nil
        )
    }

    public func recordPendingConsent(
        _ episode: CompletionEpisodeCapture,
        collectionGeneration: UInt64
    ) throws {
        try record(
            episode,
            storageVersion: StoredCompletionEpisode.currentStorageVersion,
            generationDidFail: episode.generationDidFail,
            pendingConsent: (collectionGeneration, nil)
        )
    }

#if DEBUG
    func recordVersionTwoCompletionEpisodeForTesting(
        _ episode: CompletionEpisodeCapture
    ) throws {
        try record(
            episode,
            storageVersion: 2,
            generationDidFail: nil,
            pendingConsent: nil
        )
    }
#endif

    private func record(
        _ episode: CompletionEpisodeCapture,
        storageVersion: Int,
        generationDidFail: Bool?,
        pendingConsent: (
            collection: UInt64,
            directTyping: UInt64?
        )?
    ) throws {
        try connection.transaction {
            let sourceEventIDs = episode.invocation.sourceEventIDs.reduce(
                into: [UUID]()
            ) { result, id in
                if !result.contains(id) {
                    result.append(id)
                }
            }
            for sourceEventID in sourceEventIDs {
                let sourceExists = try connection.query(
                    "SELECT 1 FROM personalization_event WHERE id = ? LIMIT 1",
                    bindings: [.text(sourceEventID.uuidString)]
                ).first != nil
                guard sourceExists else {
                    throw PersonalizationPersistenceError.database(
                        "Missing completion episode source event "
                            + sourceEventID.uuidString
                    )
                }
            }
            var referencedChunks = Set<Data>()
            let initialText = episode.invocation.field.text
            let initialTextReference = try storedTextReference(
                forUTF8: Data(initialText.utf8),
                referencedChunks: &referencedChunks
            )
            let promptInput = textBeforeSelection(
                in: episode.invocation.field
            )
            let providerInput = promptInput.map {
                String($0.suffix(1_500))
            }
            let providerInputReference = try providerInput.map { input in
                let fieldBytes = Data(initialText.utf8)
                let inputBytes = Data(input.utf8)
                let inputEnd = Data((promptInput ?? "").utf8).count
                return try storedTextReference(
                    forUTF8Subrange:
                        (inputEnd - inputBytes.count)..<inputEnd,
                    in: fieldBytes,
                    fullReference: initialTextReference,
                    referencedChunks: &referencedChunks
                )
            }
            let storedPrompt = try storedPrompt(
                episode.invocation.prompt,
                promptInput: providerInput,
                promptInputReference: providerInputReference,
                referencedChunks: &referencedChunks
            )
            var previousSuggestion = ""
            let storedRevisions = episode.suggestionRevisions.map {
                let stored = StoredCompletionSuggestionRevision(
                    textDelta: StoredTextDelta(
                        from: previousSuggestion,
                        to: $0.text
                    ),
                    isFinal: $0.isFinal,
                    observedAt: $0.observedAt
                )
                previousSuggestion = $0.text
                return stored
            }
            let storedEpisode = StoredCompletionEpisode(
                storageVersion: storageVersion,
                id: episode.id,
                invocation: StoredCompletionInvocation(
                    id: episode.invocation.id,
                    field: StoredCompletionField(
                        text: initialTextReference,
                        selection: episode.invocation.field.selection
                    ),
                    prompt: storedPrompt,
                    generation: episode.invocation.generation,
                    context: episode.invocation.context,
                    sourceEventIDs: sourceEventIDs,
                    sourceContexts: episode.invocation.sourceContexts,
                    collectionGeneration:
                        episode.invocation.collectionGeneration,
                    startedAt: episode.invocation.startedAt
                ),
                suggestionRevisions: storedRevisions,
                acceptances: episode.acceptances,
                typedThroughText: episode.typedThroughText,
                generationDidFail: generationDidFail,
                resolution: episode.resolution,
                finalFieldTextDelta: StoredTextDelta(
                    from: initialText,
                    to: episode.finalField.text
                ),
                finalFieldSelection: episode.finalField.selection,
                actualInsertedText: episode.actualInsertedText,
                endedAt: episode.endedAt
            )
            let payload = try encoder.encode(storedEpisode)
            try insertEvent(
                id: episode.id,
                kind: Self.completionEpisodeKind,
                capturedAt: episode.endedAt,
                payload: payload,
                context: episode.invocation.context,
                additionalContexts: episode.invocation.sourceContexts
            )
            for chunkHMAC in referencedChunks {
                try connection.execute(
                    """
                    INSERT OR IGNORE INTO event_text_chunk (
                        event_id,
                        chunk_hmac
                    ) VALUES (?, ?)
                    """,
                    bindings: [
                        .text(episode.id.uuidString),
                        .blob(chunkHMAC),
                    ]
                )
            }
            for sourceEventID in sourceEventIDs {
                try connection.execute(
                    """
                    INSERT INTO completion_episode_source (
                        completion_event_id,
                        source_event_id
                    ) VALUES (?, ?)
                    """,
                    bindings: [
                        .text(episode.id.uuidString),
                        .text(sourceEventID.uuidString),
                    ]
                )
            }
            if let pendingConsent {
                try insertPendingConsentMarker(
                    eventID: episode.id,
                    collectionGeneration: pendingConsent.collection,
                    directTypingGeneration:
                        pendingConsent.directTyping
                )
            }
        }
    }

    func foreignKeyEnforcementEnabled() throws -> Bool {
        try connection.query("PRAGMA foreign_keys").first?
            .integer(at: 0) == 1
    }

    func recursiveTriggersEnabled() throws -> Bool {
        try connection.query("PRAGMA recursive_triggers").first?
            .integer(at: 0) == 1
    }

    func secureDeletionEnabled() throws -> Bool {
        try connection.query("PRAGMA secure_delete").first?
            .integer(at: 0) == 1
    }

#if DEBUG
    func replaceEventTimestampForTesting(
        eventID: UUID,
        capturedAt: Date
    ) throws {
        try connection.execute(
            """
            UPDATE personalization_event
            SET captured_at_ms = ?
            WHERE id = ?
            """,
            bindings: [
                .integer(
                    Int64(capturedAt.timeIntervalSince1970 * 1_000)
                ),
                .text(eventID.uuidString),
            ]
        )
    }

    func removeEventScopeIndexForTesting(eventID: UUID) throws {
        try connection.execute(
            "DELETE FROM event_scope WHERE event_id = ?",
            bindings: [.text(eventID.uuidString)]
        )
    }

    func removeEventTextChunkIndexForTesting(eventID: UUID) throws {
        try connection.execute(
            "DELETE FROM event_text_chunk WHERE event_id = ?",
            bindings: [.text(eventID.uuidString)]
        )
    }

    func deleteFirstTextChunkForTesting() throws -> Bool {
        guard
            let chunkHMAC = try connection.query(
                """
                SELECT chunk_hmac
                FROM personalization_text_chunk
                ORDER BY rowid ASC
                LIMIT 1
                """
            ).first?.blob(at: 0)
        else {
            return false
        }
        try connection.execute(
            """
            DELETE FROM personalization_text_chunk
            WHERE chunk_hmac = ?
            """,
            bindings: [.blob(chunkHMAC)]
        )
        return true
    }

    func removeCompletionEpisodeSourceIndexForTesting(
        completionEventID: UUID
    ) throws {
        try connection.execute(
            """
            DELETE FROM completion_episode_source
            WHERE completion_event_id = ?
            """,
            bindings: [.text(completionEventID.uuidString)]
        )
    }

    func attachFirstTextChunkForTesting(eventID: UUID) throws -> Bool {
        guard
            let chunkHMAC = try connection.query(
                """
                SELECT chunk_hmac
                FROM personalization_text_chunk
                ORDER BY rowid ASC
                LIMIT 1
                """
            ).first?.blob(at: 0)
        else {
            return false
        }
        try connection.execute(
            """
            INSERT OR IGNORE INTO event_text_chunk (event_id, chunk_hmac)
            VALUES (?, ?)
            """,
            bindings: [.text(eventID.uuidString), .blob(chunkHMAC)]
        )
        return true
    }

    func insertCompletionEpisodeSourceIndexForTesting(
        completionEventID: UUID,
        sourceEventID: UUID
    ) throws {
        try connection.execute(
            """
            INSERT INTO completion_episode_source (
                completion_event_id,
                source_event_id
            ) VALUES (?, ?)
            """,
            bindings: [
                .text(completionEventID.uuidString),
                .text(sourceEventID.uuidString),
            ]
        )
    }

    func replaceScopeLookupHMACWithLegacyForTesting(
        kind: String,
        value: String
    ) throws {
        let currentHMAC =
            try PersonalizationCryptography.scopeLookupHMAC(
                kind: kind,
                value: value,
                keyData: keyData
            )
        let legacyHMAC = try PersonalizationCryptography.lookupHMAC(
            for: value,
            keyData: keyData
        )
        try connection.execute(
            """
            UPDATE personalization_scope
            SET lookup_hmac = ?
            WHERE kind = ? AND lookup_hmac = ?
            """,
            bindings: [
                .blob(legacyHMAC),
                .text(kind),
                .blob(currentHMAC),
            ]
        )
    }

    func corruptScopeCiphertextForTesting(
        kind: String,
        value: String
    ) throws {
        let lookupHMAC =
            try PersonalizationCryptography.scopeLookupHMAC(
                kind: kind,
                value: value,
                keyData: keyData
            )
        try connection.execute(
            """
            UPDATE personalization_scope
            SET value_sealed = ?
            WHERE kind = ? AND lookup_hmac = ?
            """,
            bindings: [
                .blob(Data(repeating: 0xA5, count: 32)),
                .text(kind),
                .blob(lookupHMAC),
            ]
        )
    }

    func scopeUsesDomainSeparatedHMACForTesting(
        kind: String,
        value: String
    ) throws -> Bool {
        let expected =
            try PersonalizationCryptography.scopeLookupHMAC(
                kind: kind,
                value: value,
                keyData: keyData
            )
        return try connection.query(
            """
            SELECT 1
            FROM personalization_scope
            WHERE kind = ? AND lookup_hmac = ?
            LIMIT 1
            """,
            bindings: [
                .text(kind),
                .blob(expected),
            ]
        ).first != nil
    }

    func firstCompletionFieldPromptChunkOverlapForTesting() throws -> Int {
        guard let episode = try supportedStoredCompletionEpisodes().first else {
            return 0
        }
        let promptChunks = [
            episode.invocation.prompt.systemMessage,
            episode.invocation.prompt.userMessage,
            episode.invocation.prompt.textPrompt,
        ]
        .compactMap { $0 }
        .flatMap(\.chunkHMACs)
        return Set(episode.invocation.field.text.chunkHMACs)
            .intersection(Set(promptChunks))
            .count
    }

    func replaceEventKindForTesting(
        eventID: UUID,
        kind: String
    ) throws {
        try connection.execute(
            """
            UPDATE personalization_event
            SET kind = ?
            WHERE id = ?
            """,
            bindings: [.text(kind), .text(eventID.uuidString)]
        )
    }

    func swapFirstTwoCompletionEventPayloadsForTesting() throws -> Bool {
        let rows = try connection.query(
            """
            SELECT id, payload_sealed, payload_hmac
            FROM personalization_event
            WHERE kind = ?
            ORDER BY sequence ASC
            LIMIT 2
            """,
            bindings: [.text(Self.completionEpisodeKind)]
        )
        guard
            rows.count == 2,
            let firstID = rows[0].text(at: 0),
            let firstPayload = rows[0].blob(at: 1),
            let firstHMAC = rows[0].blob(at: 2),
            let secondID = rows[1].text(at: 0),
            let secondPayload = rows[1].blob(at: 1),
            let secondHMAC = rows[1].blob(at: 2)
        else {
            return false
        }
        try connection.transaction {
            try connection.execute(
                """
                UPDATE personalization_event
                SET payload_sealed = ?, payload_hmac = ?
                WHERE id = ?
                """,
                bindings: [
                    .blob(secondPayload),
                    .blob(secondHMAC),
                    .text(firstID),
                ]
            )
            try connection.execute(
                """
                UPDATE personalization_event
                SET payload_sealed = ?, payload_hmac = ?
                WHERE id = ?
                """,
                bindings: [
                    .blob(firstPayload),
                    .blob(firstHMAC),
                    .text(secondID),
                ]
            )
        }
        return true
    }

    func corruptFirstCompletionEventPayloadForTesting() throws -> Bool {
        let row = try connection.query(
            """
            SELECT id, payload_sealed
            FROM personalization_event
            WHERE kind = ?
            ORDER BY sequence ASC
            LIMIT 1
            """,
            bindings: [.text(Self.completionEpisodeKind)]
        ).first
        guard
            let id = row?.text(at: 0),
            var payload = row?.blob(at: 1),
            !payload.isEmpty
        else {
            return false
        }
        payload[payload.startIndex] ^= 0x01
        try connection.execute(
            """
            UPDATE personalization_event
            SET payload_sealed = ?
            WHERE id = ?
            """,
            bindings: [.blob(payload), .text(id)]
        )
        return true
    }

    func corruptFirstAcceptedSuggestionPayloadForTesting() throws -> Bool {
        let row = try connection.query(
            """
            SELECT id, payload_sealed
            FROM personalization_event
            WHERE kind = ?
            ORDER BY sequence ASC
            LIMIT 1
            """,
            bindings: [.text(Self.acceptedSuggestionKind)]
        ).first
        guard
            let id = row?.text(at: 0),
            var payload = row?.blob(at: 1),
            !payload.isEmpty
        else {
            return false
        }
        payload[payload.startIndex] ^= 0x01
        try connection.execute(
            """
            UPDATE personalization_event
            SET payload_sealed = ?
            WHERE id = ?
            """,
            bindings: [.blob(payload), .text(id)]
        )
        return true
    }

    func swapFirstTwoTextChunkPayloadsForTesting() throws -> Bool {
        let rows = try connection.query(
            """
            SELECT chunk_hmac, payload_sealed
            FROM personalization_text_chunk
            ORDER BY rowid ASC
            LIMIT 2
            """
        )
        guard
            rows.count == 2,
            let firstHMAC = rows[0].blob(at: 0),
            let firstPayload = rows[0].blob(at: 1),
            let secondHMAC = rows[1].blob(at: 0),
            let secondPayload = rows[1].blob(at: 1)
        else {
            return false
        }
        try connection.transaction {
            try connection.execute(
                """
                UPDATE personalization_text_chunk
                SET payload_sealed = ?
                WHERE chunk_hmac = ?
                """,
                bindings: [.blob(secondPayload), .blob(firstHMAC)]
            )
            try connection.execute(
                """
                UPDATE personalization_text_chunk
                SET payload_sealed = ?
                WHERE chunk_hmac = ?
                """,
                bindings: [.blob(firstPayload), .blob(secondHMAC)]
            )
        }
        return true
    }

    func recordUnsupportedCompletionEpisodeForTesting(
        id: UUID,
        storageVersion: Int,
        capturedAt: Date
    ) throws {
        struct UnsupportedHeader: Encodable {
            let id: UUID
            let storageVersion: Int
        }
        try connection.transaction {
            try insertEvent(
                id: id,
                kind: Self.completionEpisodeKind,
                capturedAt: capturedAt,
                payload: try encoder.encode(
                    UnsupportedHeader(
                        id: id,
                        storageVersion: storageVersion
                    )
                ),
                context: PersonalizationContext(
                    editorIdentifier: "unsupported"
                )
            )
        }
    }

    func corruptPendingConsentGenerationForTesting(
        eventID: UUID
    ) throws {
        try connection.execute(
            """
            UPDATE pending_consent_event
            SET collection_generation = 'invalid'
            WHERE event_id = ?
            """,
            bindings: [.text(eventID.uuidString)]
        )
    }

    func deletePendingConsentMarkerForTesting(
        eventID: UUID
    ) throws {
        try connection.execute(
            "DELETE FROM pending_consent_event WHERE event_id = ?",
            bindings: [.text(eventID.uuidString)]
        )
    }

    func corruptAuthenticatedConsentStateForTesting(
        eventID: UUID
    ) throws {
        try connection.execute(
            """
            UPDATE personalization_event_consent
            SET collection_generation = 'tampered'
            WHERE event_id = ?
            """,
            bindings: [.text(eventID.uuidString)]
        )
    }

    func deleteAuthenticatedConsentStateForTesting(
        eventID: UUID
    ) throws {
        try connection.execute(
            """
            DELETE FROM personalization_event_consent
            WHERE event_id = ?
            """,
            bindings: [.text(eventID.uuidString)]
        )
    }

    func dropAuthenticatedConsentSchemaForTesting() throws {
        try connection.execute(
            "DROP TABLE personalization_event_consent"
        )
        try connection.execute(
            "DROP TABLE personalization_schema_state"
        )
    }

    func rollBackAuthenticatedConsentSchemaForTesting() throws {
        try connection.transaction {
            try connection.execute(
                "DROP TABLE personalization_event_consent"
            )
            try connection.execute(
                "DROP TABLE personalization_schema_state"
            )
            try connection.execute("PRAGMA user_version = 0")
        }
    }

    func prepareMalformedLegacyPendingConsentForTesting(
        eventID: UUID
    ) throws {
        try connection.transaction {
            try connection.execute(
                "DROP TABLE personalization_event_consent"
            )
            try connection.execute(
                "DROP TABLE personalization_schema_state"
            )
            try connection.execute(
                "PRAGMA user_version = 0"
            )
            try connection.execute(
                """
                UPDATE pending_consent_event
                SET collection_generation = X'00FF'
                WHERE event_id = ?
                """,
                bindings: [.text(eventID.uuidString)]
            )
        }
    }

    func insertOrphanedEmbeddingForTesting() throws {
        let vector = [0.25, 0.75]
        let sealed = try PersonalizationCryptography.seal(
            try encoder.encode(vector),
            keyData: keyData
        )
        try connection.execute("PRAGMA foreign_keys = OFF")
        defer {
            try? connection.execute("PRAGMA foreign_keys = ON")
        }
        try connection.execute(
            """
            INSERT INTO personalization_embedding (
                event_id,
                model_identifier,
                dimension,
                vector_sealed,
                created_at_ms
            ) VALUES (?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(UUID().uuidString),
                .text("orphaned-test-model"),
                .integer(Int64(vector.count)),
                .blob(sealed),
                .integer(0),
            ]
        )
    }
#endif

    private func recordEvent<Payload: Encodable>(
        id: UUID,
        kind: String,
        capturedAt: Date,
        payload value: Payload,
        context: PersonalizationContext,
        pendingConsent: (
            collection: UInt64,
            directTyping: UInt64?
        )? = nil
    ) throws {
        let payload = try encoder.encode(value)
        try connection.transaction {
            try insertEvent(
                id: id,
                kind: kind,
                capturedAt: capturedAt,
                payload: payload,
                context: context
            )
            if let pendingConsent {
                try insertPendingConsentMarker(
                    eventID: id,
                    collectionGeneration: pendingConsent.collection,
                    directTypingGeneration:
                        pendingConsent.directTyping
                )
            }
        }
    }

    private func insertPendingConsentMarker(
        eventID: UUID,
        collectionGeneration: UInt64,
        directTypingGeneration: UInt64?
    ) throws {
        try connection.execute(
            """
            INSERT INTO pending_consent_event (
                event_id,
                collection_generation,
                direct_typing_generation
            ) VALUES (?, ?, ?)
            """,
            bindings: [
                .text(eventID.uuidString),
                .text(String(collectionGeneration)),
                .text(directTypingGeneration.map(String.init) ?? ""),
            ]
        )
        try writeConsentState(
            eventID: eventID.uuidString,
            status: "pending",
            collectionGeneration: String(collectionGeneration),
            directTypingGeneration:
                directTypingGeneration.map(String.init) ?? ""
        )
    }

    private func writeConsentState(
        eventID: String,
        status: String,
        collectionGeneration: String,
        directTypingGeneration: String
    ) throws {
        let stateHMAC = try Self.consentStateHMAC(
            eventID: eventID,
            status: status,
            collectionGeneration: collectionGeneration,
            directTypingGeneration: directTypingGeneration,
            keyData: keyData
        )
        try connection.execute(
            """
            INSERT INTO personalization_event_consent (
                event_id,
                status,
                collection_generation,
                direct_typing_generation,
                state_hmac
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET
                status = excluded.status,
                collection_generation = excluded.collection_generation,
                direct_typing_generation =
                    excluded.direct_typing_generation,
                state_hmac = excluded.state_hmac
            """,
            bindings: [
                .text(eventID),
                .text(status),
                .text(collectionGeneration),
                .text(directTypingGeneration),
                .blob(stateHMAC),
            ]
        )
    }

    private func validatedConsentState(
        eventID: String,
        status: String?,
        collectionGeneration: String?,
        directTypingGeneration: String?,
        stateHMAC: Data?
    ) throws -> (
        status: String,
        collectionGeneration: String,
        directTypingGeneration: String
    )? {
        guard
            let status,
            let collectionGeneration,
            let directTypingGeneration,
            let stateHMAC,
            status == "pending" || status == "finalized"
        else {
            return nil
        }
        let expectedHMAC = try Self.consentStateHMAC(
            eventID: eventID,
            status: status,
            collectionGeneration: collectionGeneration,
            directTypingGeneration: directTypingGeneration,
            keyData: keyData
        )
        guard stateHMAC == expectedHMAC else { return nil }
        return (
            status,
            collectionGeneration,
            directTypingGeneration
        )
    }

    private func validateFinalizedConsentState(
        eventID: String
    ) throws {
        let row = try connection.query(
            """
            SELECT
                status,
                collection_generation,
                direct_typing_generation,
                state_hmac
            FROM personalization_event_consent
            WHERE event_id = ?
            """,
            bindings: [.text(eventID)]
        ).first
        let state = try validatedConsentState(
            eventID: eventID,
            status: row?.text(at: 0),
            collectionGeneration: row?.text(at: 1),
            directTypingGeneration: row?.text(at: 2),
            stateHMAC: row?.blob(at: 3)
        )
        guard state?.status == "finalized" else {
            throw PersonalizationPersistenceError.database(
                "Invalid or pending authenticated consent state"
            )
        }
    }

    private func validatePendingConsentState(
        eventID: String,
        collectionGeneration: UInt64,
        directTypingGeneration: UInt64?
    ) throws {
        let row = try connection.query(
            """
            SELECT
                status,
                collection_generation,
                direct_typing_generation,
                state_hmac
            FROM personalization_event_consent
            WHERE event_id = ?
            """,
            bindings: [.text(eventID)]
        ).first
        let state = try validatedConsentState(
            eventID: eventID,
            status: row?.text(at: 0),
            collectionGeneration: row?.text(at: 1),
            directTypingGeneration: row?.text(at: 2),
            stateHMAC: row?.blob(at: 3)
        )
        guard
            state?.status == "pending",
            state?.collectionGeneration == String(collectionGeneration),
            state?.directTypingGeneration
                == (directTypingGeneration.map(String.init) ?? "")
        else {
            throw PersonalizationPersistenceError.database(
                "Invalid authenticated pending consent state"
            )
        }
    }

    private func finalizeAuthenticatedPendingConsentState(
        eventID: UUID,
        collectionGeneration: UInt64,
        directTypingGeneration: UInt64?
    ) throws -> Bool {
        try connection.transaction {
            let storedEventID = eventID.uuidString
            let eventExists = try connection.query(
                """
                SELECT 1
                FROM personalization_event
                WHERE id = ?
                LIMIT 1
                """,
                bindings: [.text(storedEventID)]
            ).first != nil
            guard eventExists else {
                // Retention may have already removed this just-recorded event.
                // With no canonical row, there is no consent state to expose.
                return true
            }
            try validatePendingConsentState(
                eventID: storedEventID,
                collectionGeneration: collectionGeneration,
                directTypingGeneration: directTypingGeneration
            )
            try writeConsentState(
                eventID: storedEventID,
                status: "finalized",
                collectionGeneration: "",
                directTypingGeneration: ""
            )
            try connection.execute(
                """
                DELETE FROM pending_consent_event
                WHERE event_id = ?
                """,
                bindings: [.text(storedEventID)]
            )
            return true
        }
    }

    private func insertEvent(
        id: UUID,
        kind: String,
        capturedAt: Date,
        payload: Data,
        context: PersonalizationContext,
        additionalContexts: [PersonalizationContext] = []
    ) throws {
        let sealedPayload = try PersonalizationCryptography.seal(
            payload,
            keyData: keyData
        )
        let payloadHMAC = try PersonalizationCryptography.payloadHMAC(
            for: payload,
            keyData: keyData
        )
        try connection.execute(
            """
            INSERT INTO personalization_event (
                id,
                kind,
                captured_at_ms,
                payload_sealed,
                payload_hmac,
                key_version
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(id.uuidString),
                .text(kind),
                .integer(
                    Int64(capturedAt.timeIntervalSince1970 * 1_000)
                ),
                .blob(sealedPayload),
                .blob(payloadHMAC),
                .integer(Int64(Self.keyVersion)),
            ]
        )
        try writeConsentState(
            eventID: id.uuidString,
            status: "finalized",
            collectionGeneration: "",
            directTypingGeneration: ""
        )

        let eventScopes = ([context] + additionalContexts)
            .flatMap(scopes)
        for scope in eventScopes {
            let scopeID = try upsertScope(scope)
            try connection.execute(
                """
                INSERT OR IGNORE INTO event_scope (event_id, scope_id)
                VALUES (?, ?)
                """,
                bindings: [
                    .text(id.uuidString),
                    .integer(scopeID),
                ]
            )
        }
    }

    private func storedPrompt(
        _ prompt: CapturedCompletionPrompt,
        promptInput: String?,
        promptInputReference: StoredTextReference?,
        referencedChunks: inout Set<Data>
    ) throws -> StoredCompletionPrompt {
        StoredCompletionPrompt(
            transport: prompt.transport,
            systemMessage: try storedPromptTextReference(
                for: prompt.systemMessage,
                promptInput: promptInput,
                promptInputReference: promptInputReference,
                referencedChunks: &referencedChunks
            ),
            userMessage: try storedPromptTextReference(
                for: prompt.userMessage,
                promptInput: promptInput,
                promptInputReference: promptInputReference,
                referencedChunks: &referencedChunks
            ),
            textPrompt: try storedPromptTextReference(
                for: prompt.textPrompt,
                promptInput: promptInput,
                promptInputReference: promptInputReference,
                referencedChunks: &referencedChunks
            )
        )
    }

    private func storedPromptTextReference(
        for text: String?,
        promptInput: String?,
        promptInputReference: StoredTextReference?,
        referencedChunks: inout Set<Data>
    ) throws -> StoredTextReference? {
        guard let text else { return nil }
        let reusableSuffix: (String, StoredTextReference)?
        if
            let promptInput,
            !promptInput.isEmpty,
            let promptInputReference
        {
            reusableSuffix = (promptInput, promptInputReference)
        } else {
            reusableSuffix = nil
        }
        return try storedTextReference(
            for: text,
            reusingSuffix: reusableSuffix,
            referencedChunks: &referencedChunks
        )
    }

    private func storedTextReference(
        for text: String,
        reusingSuffix: (String, StoredTextReference)? = nil,
        referencedChunks: inout Set<Data>
    ) throws -> StoredTextReference {
        if
            let (suffix, suffixReference) = reusingSuffix,
            !suffix.isEmpty
        {
            let textBytes = Data(text.utf8)
            let suffixBytes = Data(suffix.utf8)
            if Data(textBytes.suffix(suffixBytes.count)) == suffixBytes {
                let prefixBytes = Data(
                    textBytes.dropLast(suffixBytes.count)
                )
                let prefixReference = try storedTextReference(
                    forUTF8: prefixBytes,
                    referencedChunks: &referencedChunks
                )
                referencedChunks.formUnion(suffixReference.chunkHMACs)
                return StoredTextReference(
                    chunkHMACs:
                        prefixReference.chunkHMACs
                        + suffixReference.chunkHMACs,
                    utf8ByteCount: textBytes.count
                )
            }
        }

        var chunkHMACs: [Data] = []
        let components = text.components(separatedBy: "\n\n")
        for (index, component) in components.enumerated() {
            chunkHMACs.append(
                contentsOf: try storeTextBytes(
                    Data(component.utf8),
                    referencedChunks: &referencedChunks
                )
            )
            if index < components.count - 1 {
                chunkHMACs.append(
                    contentsOf: try storeTextBytes(
                        Data("\n\n".utf8),
                        referencedChunks: &referencedChunks
                    )
                )
            }
        }
        return StoredTextReference(
            chunkHMACs: chunkHMACs,
            utf8ByteCount: text.utf8.count
        )
    }

    private func storedTextReference(
        forUTF8 bytes: Data,
        referencedChunks: inout Set<Data>
    ) throws -> StoredTextReference {
        StoredTextReference(
            chunkHMACs: try storeTextBytes(
                bytes,
                referencedChunks: &referencedChunks
            ),
            utf8ByteCount: bytes.count
        )
    }

    private func storedTextReference(
        forUTF8Subrange range: Range<Int>,
        in fullBytes: Data,
        fullReference: StoredTextReference,
        referencedChunks: inout Set<Data>
    ) throws -> StoredTextReference {
        guard
            range.lowerBound >= 0,
            range.upperBound <= fullBytes.count,
            range.lowerBound <= range.upperBound
        else {
            throw PersonalizationPersistenceError.database(
                "Invalid completion episode provider-input range"
            )
        }
        guard !range.isEmpty else {
            return StoredTextReference(chunkHMACs: [], utf8ByteCount: 0)
        }

        var chunkHMACs: [Data] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            let fullChunkIndex = offset / Self.textChunkByteCount
            let fullChunkStart =
                fullChunkIndex * Self.textChunkByteCount
            let fullChunkEnd = min(
                fullChunkStart + Self.textChunkByteCount,
                fullBytes.count
            )
            if
                offset == fullChunkStart,
                fullChunkEnd <= range.upperBound,
                fullChunkIndex < fullReference.chunkHMACs.count
            {
                let chunkHMAC = fullReference.chunkHMACs[fullChunkIndex]
                chunkHMACs.append(chunkHMAC)
                referencedChunks.insert(chunkHMAC)
                offset = fullChunkEnd
                continue
            }

            let partialEnd = min(fullChunkEnd, range.upperBound)
            let partial = Data(fullBytes[offset..<partialEnd])
            chunkHMACs.append(
                contentsOf: try storeTextBytes(
                    partial,
                    referencedChunks: &referencedChunks
                )
            )
            offset = partialEnd
        }
        return StoredTextReference(
            chunkHMACs: chunkHMACs,
            utf8ByteCount: range.count
        )
    }

    private func storeTextBytes(
        _ bytes: Data,
        referencedChunks: inout Set<Data>
    ) throws -> [Data] {
        guard !bytes.isEmpty else { return [] }
        var chunkHMACs: [Data] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(
                offset + Self.textChunkByteCount,
                bytes.count
            )
            let chunk = Data(bytes[offset..<end])
            let chunkHMAC = try PersonalizationCryptography.payloadHMAC(
                for: chunk,
                keyData: keyData
            )
            let sealed = try PersonalizationCryptography.seal(
                chunk,
                keyData: keyData
            )
            try connection.execute(
                """
                INSERT OR IGNORE INTO personalization_text_chunk (
                    chunk_hmac,
                    payload_sealed,
                    plaintext_byte_count,
                    key_version
                ) VALUES (?, ?, ?, ?)
                """,
                bindings: [
                    .blob(chunkHMAC),
                    .blob(sealed),
                    .integer(Int64(chunk.count)),
                    .integer(Int64(Self.keyVersion)),
                ]
            )
            if
                connection.changedRowCount == 0,
                !referencedChunks.contains(chunkHMAC)
            {
                var chunkCache: [Data: Data] = [:]
                let authenticatedChunk = try loadTextChunk(
                    chunkHMAC,
                    chunkCache: &chunkCache
                )
                guard authenticatedChunk == chunk else {
                    throw PersonalizationPersistenceError.database(
                        "Completion episode text chunk content mismatch"
                    )
                }
            }
            chunkHMACs.append(chunkHMAC)
            referencedChunks.insert(chunkHMAC)
            offset = end
        }
        return chunkHMACs
    }

    private func loadText(
        _ reference: StoredTextReference,
        chunkCache: inout [Data: Data]
    ) throws -> String {
        var bytes = Data()
        for chunkHMAC in reference.chunkHMACs {
            let chunk = try loadTextChunk(
                chunkHMAC,
                chunkCache: &chunkCache
            )
            bytes.append(chunk)
        }
        guard
            bytes.count == reference.utf8ByteCount,
            let text = String(data: bytes, encoding: .utf8)
        else {
            throw PersonalizationPersistenceError.database(
                "Invalid completion episode text reference"
            )
        }
        return text
    }

    private func loadTextChunk(
        _ chunkHMAC: Data,
        chunkCache: inout [Data: Data],
        missingChunkMessage: String =
            "Missing completion episode text chunk"
    ) throws -> Data {
        try Task.checkCancellation()
        if let cached = chunkCache[chunkHMAC] {
            return cached
        }
        let row = try connection.query(
            """
            SELECT payload_sealed, plaintext_byte_count
            FROM personalization_text_chunk
            WHERE chunk_hmac = ?
            """,
            bindings: [.blob(chunkHMAC)]
        ).first
        guard
            let sealed = row?.blob(at: 0),
            let expectedByteCount = row?.integer(at: 1)
        else {
            throw PersonalizationPersistenceError.database(
                missingChunkMessage
            )
        }
        let chunk = try PersonalizationCryptography.open(
            sealed,
            keyData: keyData
        )
        guard chunk.count == Int(expectedByteCount) else {
            throw PersonalizationPersistenceError.database(
                "Completion episode text chunk size mismatch"
            )
        }
        let hydratedHMAC = try PersonalizationCryptography.payloadHMAC(
            for: chunk,
            keyData: keyData
        )
        guard hydratedHMAC == chunkHMAC else {
            throw PersonalizationPersistenceError.database(
                "Completion episode text chunk HMAC mismatch"
            )
        }
        chunkCache[chunkHMAC] = chunk
        return chunk
    }

    private func textBeforeSelection(
        in field: CapturedFieldState
    ) -> String? {
        guard field.selection.isValid(for: field.text) else {
            return nil
        }
        let utf16 = Array(field.text.utf16)
        return String(
            decoding: utf16[..<field.selection.location],
            as: UTF16.self
        )
    }

    public func acceptedSuggestions(
        limit: Int? = nil,
        excludingPendingConsent: Bool = false
    ) throws -> [AcceptedSuggestionCapture] {
        try decodedEvents(
            kind: Self.acceptedSuggestionKind,
            as: AcceptedSuggestionCapture.self,
            limit: limit,
            excludingPendingConsent: excludingPendingConsent
        )
    }

    public func writingEpisodes(
        limit: Int? = nil,
        excludingPendingConsent: Bool = false
    ) throws -> [WritingEpisodeCapture] {
        try decodedEvents(
            kind: Self.writingEpisodeKind,
            as: WritingEpisodeCapture.self,
            limit: limit,
            excludingPendingConsent: excludingPendingConsent
        )
    }

    public func completionFeedback(
        excludingPendingConsent: Bool = false
    ) throws
        -> [CompletionFeedbackCapture]
    {
        try decodedEvents(
            kind: Self.completionFeedbackKind,
            as: CompletionFeedbackCapture.self,
            excludingPendingConsent: excludingPendingConsent
        )
    }

    public func completionEpisodes(
        limit: Int? = nil,
        excludingPendingConsent: Bool = false
    ) throws -> [CompletionEpisodeCapture] {
        var chunkCache: [Data: Data] = [:]
        func decode(
            _ row: SQLiteRow,
            idIndex: Int,
            kindIndex: Int,
            payloadIndex: Int,
            hmacIndex: Int
        ) throws -> CompletionEpisodeCapture? {
            if excludingPendingConsent,
               let eventID = row.text(at: idIndex) {
                try validateFinalizedConsentState(eventID: eventID)
            }
            let payload = try validatedEventPayload(
                row,
                idIndex: idIndex,
                kindIndex: kindIndex,
                payloadIndex: payloadIndex,
                hmacIndex: hmacIndex,
                expectedKind: Self.completionEpisodeKind
            )
            if
                let header = try? decoder.decode(
                    StoredCompletionEpisodeHeader.self,
                    from: payload
                )
            {
                guard header.storageVersion
                    == StoredCompletionEpisode.currentStorageVersion
                else {
                    return nil
                }
                let stored = try decoder.decode(
                    StoredCompletionEpisode.self,
                    from: payload
                )
                return try stored.hydrated { reference in
                    try loadText(
                        reference,
                        chunkCache: &chunkCache
                    )
                }
            }
            return try decoder.decode(
                CompletionEpisodeCapture.self,
                from: payload
            )
        }

        let pendingPredicate =
            excludingPendingConsent
            ? """
             AND EXISTS (
                SELECT 1
                FROM personalization_event_consent AS consent
                WHERE consent.event_id = event.id
                    AND consent.status = 'finalized'
             )
            """
            : ""
        guard let limit else {
            let rows = try connection.query(
                """
                SELECT id, kind, payload_sealed, payload_hmac
                FROM personalization_event AS event
                WHERE kind = ?
                \(pendingPredicate)
                ORDER BY sequence ASC
                """,
                bindings: [.text(Self.completionEpisodeKind)]
            )
            return try rows.compactMap {
                try Task.checkCancellation()
                return try decode(
                    $0,
                    idIndex: 0,
                    kindIndex: 1,
                    payloadIndex: 2,
                    hmacIndex: 3
                )
            }
        }

        let requestedCount = max(0, limit)
        guard requestedCount > 0 else { return [] }
        let pageSize = max(20, requestedCount)
        var episodes: [CompletionEpisodeCapture] = []
        var sequenceBefore: Int64?

        while episodes.count < requestedCount {
            let cursorPredicate =
                sequenceBefore == nil ? "" : " AND sequence < ?"
            var bindings: [SQLiteBinding] = [
                .text(Self.completionEpisodeKind)
            ]
            if let sequenceBefore {
                bindings.append(.integer(sequenceBefore))
            }
            bindings.append(.integer(Int64(pageSize)))
            let rows = try connection.query(
                """
                SELECT sequence, id, kind, payload_sealed, payload_hmac
                FROM personalization_event AS event
                WHERE kind = ?\(cursorPredicate)
                \(pendingPredicate)
                ORDER BY sequence DESC
                LIMIT ?
                """,
                bindings: bindings
            )
            guard !rows.isEmpty else { break }

            for row in rows {
                try Task.checkCancellation()
                if let episode = try decode(
                    row,
                    idIndex: 1,
                    kindIndex: 2,
                    payloadIndex: 3,
                    hmacIndex: 4
                ) {
                    episodes.append(episode)
                    if episodes.count == requestedCount {
                        break
                    }
                }
            }
            guard
                rows.count == pageSize,
                let oldestSequence = rows.last?.integer(at: 0)
            else {
                break
            }
            sequenceBefore = oldestSequence
        }
        return Array(episodes.reversed())
    }

    private func decodedEvents<Value: Decodable>(
        kind expectedKind: String,
        as type: Value.Type,
        limit: Int? = nil,
        excludingPendingConsent: Bool = false
    ) throws -> [Value] {
        let order = limit == nil ? "ASC" : "DESC"
        let limitClause = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        let pendingPredicate =
            excludingPendingConsent
            ? """
             AND EXISTS (
                SELECT 1
                FROM personalization_event_consent AS consent
                WHERE consent.event_id = event.id
                    AND consent.status = 'finalized'
             )
            """
            : ""
        let rows = try connection.query(
            """
            SELECT id, kind, payload_sealed, payload_hmac
            FROM personalization_event AS event
            WHERE kind = ?
            \(pendingPredicate)
            ORDER BY sequence \(order)\(limitClause)
            """,
            bindings: [.text(expectedKind)]
        )

        let decoded = try rows.map { row in
            try Task.checkCancellation()
            if excludingPendingConsent,
               let eventID = row.text(at: 0) {
                try validateFinalizedConsentState(eventID: eventID)
            }
            let payload = try validatedEventPayload(
                row,
                idIndex: 0,
                kindIndex: 1,
                payloadIndex: 2,
                hmacIndex: 3,
                expectedKind: expectedKind
            )
            return try decoder.decode(type, from: payload)
        }
        return limit == nil ? decoded : Array(decoded.reversed())
    }

    private func validatedEventPayload(
        _ row: SQLiteRow,
        idIndex: Int,
        kindIndex: Int,
        payloadIndex: Int,
        hmacIndex: Int,
        expectedKind: String
    ) throws -> Data {
        struct EventIdentity: Decodable {
            let id: UUID
        }
        try Task.checkCancellation()
        guard
            let rowID = row.text(at: idIndex),
            let kind = row.text(at: kindIndex),
            kind == expectedKind,
            let sealedPayload = row.blob(at: payloadIndex),
            let storedHMAC = row.blob(at: hmacIndex)
        else {
            throw PersonalizationPersistenceError.database(
                "Invalid \(expectedKind) event row"
            )
        }
        let payload = try PersonalizationCryptography.open(
            sealedPayload,
            keyData: keyData
        )
        let expectedHMAC = try PersonalizationCryptography.payloadHMAC(
            for: payload,
            keyData: keyData
        )
        guard
            storedHMAC == expectedHMAC,
            let identity = try? decoder.decode(
                EventIdentity.self,
                from: payload
            ),
            identity.id.uuidString == rowID
        else {
            throw PersonalizationPersistenceError.database(
                "Personalization event identity or integrity mismatch"
            )
        }
        return payload
    }

    public func exportCorpus(
        at date: Date = Date()
    ) throws -> PersonalizationCorpusExport {
        PersonalizationCorpusExport(
            exportedAt: date,
            acceptedSuggestions:
                try acceptedSuggestions(excludingPendingConsent: true),
            completionFeedback:
                try completionFeedback(excludingPendingConsent: true),
            writingEpisodes:
                try writingEpisodes(excludingPendingConsent: true),
            completionEpisodes:
                try completionEpisodes(excludingPendingConsent: true)
        )
    }

    public func saveLanguageModel(
        _ model: PersonalLanguageModel,
        at date: Date = Date()
    ) throws {
        let payload = try encoder.encode(model)
        let sealed = try PersonalizationCryptography.seal(
            payload,
            keyData: keyData
        )
        try connection.execute(
            """
            INSERT INTO personalization_projection (
                name,
                version,
                payload_sealed,
                updated_at_ms
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
                version = excluded.version,
                payload_sealed = excluded.payload_sealed,
                updated_at_ms = excluded.updated_at_ms
            """,
            bindings: [
                .text(Self.languageModelProjection),
                .integer(1),
                .blob(sealed),
                .integer(Int64(date.timeIntervalSince1970 * 1_000))
            ]
        )
    }

    public func loadLanguageModel() throws -> PersonalLanguageModel? {
        let row = try connection.query(
            """
            SELECT payload_sealed
            FROM personalization_projection
            WHERE name = ?
            """,
            bindings: [.text(Self.languageModelProjection)]
        ).first
        guard let sealed = row?.blob(at: 0) else { return nil }
        let payload = try PersonalizationCryptography.open(
            sealed,
            keyData: keyData
        )
        return try decoder.decode(
            PersonalLanguageModel.self,
            from: payload
        )
    }

    public func saveVoiceAssessment(
        _ assessment: VoiceAssessment,
        at date: Date = Date()
    ) throws {
        let payload = try encoder.encode(assessment)
        let sealed = try PersonalizationCryptography.seal(
            payload,
            keyData: keyData
        )
        try connection.execute(
            """
            INSERT INTO personalization_projection (
                name,
                version,
                payload_sealed,
                updated_at_ms
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
                version = excluded.version,
                payload_sealed = excluded.payload_sealed,
                updated_at_ms = excluded.updated_at_ms
            """,
            bindings: [
                .text(Self.voiceAssessmentProjection),
                .integer(1),
                .blob(sealed),
                .integer(Int64(date.timeIntervalSince1970 * 1_000))
            ]
        )
    }

    public func loadVoiceAssessment() throws -> VoiceAssessment? {
        let row = try connection.query(
            """
            SELECT payload_sealed
            FROM personalization_projection
            WHERE name = ?
            """,
            bindings: [.text(Self.voiceAssessmentProjection)]
        ).first
        guard let sealed = row?.blob(at: 0) else { return nil }
        let payload = try PersonalizationCryptography.open(
            sealed,
            keyData: keyData
        )
        return try decoder.decode(VoiceAssessment.self, from: payload)
    }

    public func deleteVoiceAssessment() throws {
        try connection.execute(
            """
            DELETE FROM personalization_projection
            WHERE name = ?
            """,
            bindings: [.text(Self.voiceAssessmentProjection)]
        )
    }

    public func saveEmbedding(
        eventID: UUID,
        modelIdentifier: String,
        vector: [Double],
        at date: Date = Date()
    ) throws {
        guard !vector.isEmpty else { return }
        let payload = try encoder.encode(vector)
        let sealed = try PersonalizationCryptography.seal(
            payload,
            keyData: keyData
        )
        try connection.execute(
            """
            INSERT INTO personalization_embedding (
                event_id,
                model_identifier,
                dimension,
                vector_sealed,
                created_at_ms
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET
                model_identifier = excluded.model_identifier,
                dimension = excluded.dimension,
                vector_sealed = excluded.vector_sealed,
                created_at_ms = excluded.created_at_ms
            """,
            bindings: [
                .text(eventID.uuidString),
                .text(modelIdentifier),
                .integer(Int64(vector.count)),
                .blob(sealed),
                .integer(Int64(date.timeIntervalSince1970 * 1_000))
            ]
        )
    }

    public func embeddings(
        modelIdentifier: String? = nil
    ) throws -> [StoredPersonalizationEmbedding] {
        let predicate = modelIdentifier == nil
            ? ""
            : " WHERE model_identifier = ?"
        let bindings = modelIdentifier.map { [SQLiteBinding.text($0)] } ?? []
        let rows = try connection.query(
            """
            SELECT event_id, model_identifier, dimension,
                   vector_sealed, created_at_ms
            FROM personalization_embedding\(predicate)
            ORDER BY created_at_ms ASC
            """,
            bindings: bindings
        )
        return try rows.map { row in
            guard
                let eventIDText = row.text(at: 0),
                let eventID = UUID(uuidString: eventIDText),
                let storedModel = row.text(at: 1),
                let dimension = row.integer(at: 2),
                let sealed = row.blob(at: 3),
                let milliseconds = row.integer(at: 4)
            else {
                throw PersonalizationPersistenceError.database(
                    "Invalid personalization embedding row"
                )
            }
            let payload = try PersonalizationCryptography.open(
                sealed,
                keyData: keyData
            )
            let vector = try decoder.decode([Double].self, from: payload)
            guard vector.count == Int(dimension) else {
                throw PersonalizationPersistenceError.database(
                    "Personalization embedding dimension mismatch"
                )
            }
            return StoredPersonalizationEmbedding(
                eventID: eventID,
                modelIdentifier: storedModel,
                vector: vector,
                createdAt: Date(
                    timeIntervalSince1970:
                        TimeInterval(milliseconds) / 1_000
                )
            )
        }
    }

    public func eventCount() throws -> Int {
        let rows = try connection.query(
            "SELECT COUNT(*) FROM personalization_event"
        )
        return Int(rows.first?.integer(at: 0) ?? 0)
    }

    public func deleteAll() throws {
        try connection.transaction {
            try connection.execute("DELETE FROM pending_consent_event")
            try connection.execute("DELETE FROM personalization_embedding")
            try connection.execute("DELETE FROM event_text_chunk")
            try connection.execute("DELETE FROM event_scope")
            // This index is rebuilt from authenticated payloads for targeted
            // operations, but Delete All must also recover from an attacker-
            // supplied cycle that would recurse through the delete trigger.
            try connection.execute("DELETE FROM completion_episode_source")
            try connection.execute("DELETE FROM personalization_event")
            try connection.execute("DELETE FROM personalization_scope")
            try connection.execute(
                "DELETE FROM personalization_text_chunk"
            )
            try connection.execute("DELETE FROM projection_checkpoint")
            try connection.execute("DELETE FROM personalization_projection")
        }
    }

    public func deleteEvent(id: UUID) throws {
        try connection.transaction {
            try rebuildCompletionEpisodeIndexes()
            try connection.execute(
                "DELETE FROM personalization_event WHERE id = ?",
                bindings: [.text(id.uuidString)]
            )
            try invalidateDerivedProjections()
            try pruneUnusedScopes()
            try pruneUnusedTextChunks()
        }
    }

    @discardableResult
    public func discardMostRecentlyRecordedEvent(id: UUID) throws -> Bool {
        try connection.transaction {
            let targetExists = try connection.query(
                """
                SELECT 1
                FROM personalization_event
                WHERE id = ?
                LIMIT 1
                """,
                bindings: [.text(id.uuidString)]
            ).first != nil
            guard targetExists else { return false }
            let newestID = try connection.query(
                """
                SELECT id
                FROM personalization_event
                ORDER BY sequence DESC
                LIMIT 1
                """
            ).first?.text(at: 0)
            guard let newestID else { return false }
            guard newestID == id.uuidString else {
                throw PersonalizationPersistenceError.database(
                    "Consent-revoked event is no longer the newest record"
                )
            }

            // No later event can legitimately depend on this just-recorded
            // source. Remove untrusted incoming index edges first so the
            // recursive deletion trigger cannot cascade through a forged
            // derived edge, then discard only the known record.
            try connection.execute(
                """
                DELETE FROM completion_episode_source
                WHERE source_event_id = ?
                """,
                bindings: [.text(id.uuidString)]
            )
            try connection.execute(
                "DELETE FROM personalization_event WHERE id = ?",
                bindings: [.text(id.uuidString)]
            )
            try pruneUnusedScopes()
            try pruneUnusedTextChunks()
            return true
        }
    }

    public func finalizePendingConsentEvent(
        id: UUID,
        collectionEpoch: PersonalizationConsentEpoch,
        collectionGeneration: UInt64,
        directTypingEpoch: PersonalizationConsentEpoch? = nil,
        directTypingGeneration: UInt64? = nil
    ) throws -> Bool {
        var didFinalize = false
        let collectionIsCurrent =
            try collectionEpoch.performIfCurrent(collectionGeneration) {
                if
                    let directTypingEpoch,
                    let directTypingGeneration
                {
                    let directTypingIsCurrent =
                        try directTypingEpoch.performIfCurrent(
                            directTypingGeneration
                        ) {
                            didFinalize =
                                try finalizeAuthenticatedPendingConsentState(
                                    eventID: id,
                                    collectionGeneration:
                                        collectionGeneration,
                                    directTypingGeneration:
                                        directTypingGeneration
                                )
                        }
                    if !directTypingIsCurrent {
                        didFinalize = false
                    }
                } else {
                    didFinalize =
                        try finalizeAuthenticatedPendingConsentState(
                            eventID: id,
                            collectionGeneration: collectionGeneration,
                            directTypingGeneration: nil
                        )
                }
            }
        return collectionIsCurrent && didFinalize
    }

    @discardableResult
    public func reconcilePendingConsentEvents(
        collectionEpoch: PersonalizationConsentEpoch,
        directTypingEpoch: PersonalizationConsentEpoch
    ) throws -> PendingConsentReconciliationResult {
        while true {
            let collectionGeneration = collectionEpoch.current
            let directTypingGeneration = directTypingEpoch.current
            var result: PendingConsentReconciliationResult?
            let collectionIsCurrent =
                try collectionEpoch.performIfCurrent(
                    collectionGeneration
                ) {
                    let directTypingIsCurrent =
                        try directTypingEpoch.performIfCurrent(
                            directTypingGeneration
                        ) {
                            result =
                                try reconcilePendingConsentEventsLocked(
                                    collectionGeneration:
                                        collectionGeneration,
                                    directTypingGeneration:
                                        directTypingGeneration
                                )
                        }
                    if !directTypingIsCurrent {
                        result = nil
                    }
                }
            if collectionIsCurrent, let result {
                return result
            }
        }
    }

    @discardableResult
    public func reconcilePendingConsentEvents(
        collectionGeneration: UInt64,
        directTypingGeneration: UInt64
    ) throws -> Int {
        try reconcilePendingConsentEventsLocked(
            collectionGeneration: collectionGeneration,
            directTypingGeneration: directTypingGeneration
        ).removedCount
    }

    private func reconcilePendingConsentEventsLocked(
        collectionGeneration _: UInt64,
        directTypingGeneration _: UInt64
    ) throws -> PendingConsentReconciliationResult {
        try connection.transaction {
            let rows = try connection.query(
                """
                SELECT
                    event.id,
                    consent.status,
                    consent.collection_generation,
                    consent.direct_typing_generation,
                    consent.state_hmac
                FROM personalization_event AS event
                LEFT JOIN personalization_event_consent AS consent
                    ON consent.event_id = event.id
                ORDER BY event.sequence ASC
                """
            )
            var removedCount = 0
            var encounteredUnfinalizedState = false
            for row in rows {
                guard let eventID = row.text(at: 0) else { continue }
                let state = try validatedConsentState(
                    eventID: eventID,
                    status: row.text(at: 1),
                    collectionGeneration: row.text(at: 2),
                    directTypingGeneration: row.text(at: 3),
                    stateHMAC: row.blob(at: 4)
                )
                if state?.status == "finalized" {
                    continue
                }
                encounteredUnfinalizedState = true
                // A pending row means the process ended before consent
                // finalization completed. Startup cannot prove whether a
                // persisted preference generation was rolled back, so never
                // promote crash-interrupted data; discard it fail closed.
                try deleteCompletionEpisodesDependingOnSource(eventID)
                try connection.execute(
                    """
                    DELETE FROM completion_episode_source
                    WHERE source_event_id = ?
                    """,
                    bindings: [.text(eventID)]
                )
                try connection.execute(
                    "DELETE FROM personalization_event WHERE id = ?",
                    bindings: [.text(eventID)]
                )
                removedCount += 1
            }
            if encounteredUnfinalizedState {
                try invalidateDerivedProjections()
            }
            if removedCount > 0 {
                try pruneUnusedScopes()
                try pruneUnusedTextChunks()
            }
            return PendingConsentReconciliationResult(
                promotedCount: 0,
                removedCount: removedCount
            )
        }
    }

    private func deleteCompletionEpisodesDependingOnSource(
        _ sourceEventID: String
    ) throws {
        let rows = try connection.query(
            """
            SELECT id, kind, payload_sealed, payload_hmac
            FROM personalization_event
            WHERE kind = ?
            ORDER BY sequence ASC
            """,
            bindings: [.text(Self.completionEpisodeKind)]
        )
        for row in rows {
            guard let completionEventID = row.text(at: 0) else {
                continue
            }
            let storedEpisode: StoredCompletionEpisode
            do {
                let payload = try validatedEventPayload(
                    row,
                    idIndex: 0,
                    kindIndex: 1,
                    payloadIndex: 2,
                    hmacIndex: 3,
                    expectedKind: Self.completionEpisodeKind
                )
                guard
                    let header = try? decoder.decode(
                        StoredCompletionEpisodeHeader.self,
                        from: payload
                    ),
                    header.storageVersion
                        == StoredCompletionEpisode.currentStorageVersion
                else {
                    continue
                }
                storedEpisode = try decoder.decode(
                    StoredCompletionEpisode.self,
                    from: payload
                )
            } catch {
                // A separately corrupt episode is not exportable and cannot
                // provide authenticated lineage. Leave it for its own recovery
                // path instead of blocking unrelated consent cleanup.
                continue
            }
            guard
                storedEpisode.invocation.sourceEventIDs?.contains(
                    where: { $0.uuidString == sourceEventID }
                ) == true
            else {
                continue
            }
            try connection.execute(
                """
                DELETE FROM completion_episode_source
                WHERE source_event_id = ?
                """,
                bindings: [.text(completionEventID)]
            )
            try connection.execute(
                "DELETE FROM personalization_event WHERE id = ?",
                bindings: [.text(completionEventID)]
            )
        }
    }

    @discardableResult
    public func deleteEvents(
        scopeKind: String,
        value: String
    ) throws -> Int {
        let lookupHMAC =
            try PersonalizationCryptography.scopeLookupHMAC(
                kind: scopeKind,
                value: value,
                keyData: keyData
            )
        return try connection.transaction {
            try rebuildCompletionEpisodeIndexes()
            try rebuildSupportedEventScopeIndex()
            try connection.execute(
                """
                DELETE FROM personalization_event
                WHERE id IN (
                    SELECT event_scope.event_id
                    FROM event_scope
                    JOIN personalization_scope
                        ON personalization_scope.id = event_scope.scope_id
                    WHERE personalization_scope.kind = ?
                        AND personalization_scope.lookup_hmac = ?
                )
                """,
                bindings: [.text(scopeKind), .blob(lookupHMAC)]
            )
            let deleted = connection.changedRowCount
            try invalidateDerivedProjections()
            try pruneUnusedScopes()
            try pruneUnusedTextChunks()
            return deleted
        }
    }

    public func completionEpisodeStorageStatistics() throws
        -> CompletionEpisodeStorageStatistics
    {
        let uniqueChunks = try connection.query(
            "SELECT COUNT(*) FROM personalization_text_chunk"
        ).first?.integer(at: 0) ?? 0
        let references = try connection.query(
            "SELECT COUNT(*) FROM event_text_chunk"
        ).first?.integer(at: 0) ?? 0
        let bytes = try connection.query(
            """
            SELECT COALESCE(SUM(LENGTH(payload_sealed)), 0)
            FROM personalization_text_chunk
            """
        ).first?.integer(at: 0) ?? 0
        return CompletionEpisodeStorageStatistics(
            uniqueTextChunkCount: Int(uniqueChunks),
            textChunkReferenceCount: Int(references),
            encryptedTextChunkBytes: Int(bytes)
        )
    }

    public func storageStatistics() throws
        -> PersonalizationStorageStatistics
    {
        let row = try connection.query(
            """
            SELECT
                COUNT(*),
                (
                    COALESCE(SUM(LENGTH(payload_sealed)), 0)
                    + (
                        SELECT COALESCE(
                            SUM(LENGTH(vector_sealed)),
                            0
                        )
                        FROM personalization_embedding
                    )
                    + (
                        SELECT COALESCE(
                            SUM(LENGTH(payload_sealed)),
                            0
                        )
                        FROM personalization_projection
                    )
                    + (
                        SELECT COALESCE(
                            SUM(LENGTH(payload_sealed)),
                            0
                        )
                        FROM personalization_text_chunk
                    )
                ),
                MIN(captured_at_ms),
                MAX(captured_at_ms)
            FROM personalization_event
            """
        ).first
        let oldestMilliseconds = row?.integer(at: 2)
        let newestMilliseconds = row?.integer(at: 3)
        return PersonalizationStorageStatistics(
            eventCount: Int(row?.integer(at: 0) ?? 0),
            encryptedPayloadBytes: Int(row?.integer(at: 1) ?? 0),
            oldestEventAt: oldestMilliseconds.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
            },
            newestEventAt: newestMilliseconds.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
            }
        )
    }

    @discardableResult
    public func enforceRetention(
        _ policy: PersonalizationRetentionPolicy,
        now: Date = Date()
    ) throws -> Int {
        let countBefore = try eventCount()
        try connection.transaction {
            try rebuildCompletionEpisodeIndexes()
            try rebuildSupportedEventTimestamps()
            var removedCanonicalEvents =
                try eventCount() < countBefore
            if let maximumAge = policy.maximumAge {
                let cutoff = now.addingTimeInterval(-maximumAge)
                try connection.execute(
                    """
                    DELETE FROM personalization_event
                    WHERE captured_at_ms < ?
                    """,
                    bindings: [
                        .integer(
                            Int64(cutoff.timeIntervalSince1970 * 1_000)
                        )
                    ]
                )
                removedCanonicalEvents =
                    removedCanonicalEvents || connection.changedRowCount > 0
            }

            if removedCanonicalEvents {
                try invalidateDerivedProjections()
                try pruneUnusedTextChunks()
            }
            if let maximumBytes = policy.maximumEncryptedBytes {
                var payloadBytes = try encryptedPayloadBytes()
                if payloadBytes > maximumBytes {
                    // Derived projections are reproducible. Drop them before
                    // evicting canonical events to meet a storage cap.
                    try invalidateDerivedProjections()
                    payloadBytes = try encryptedPayloadBytes()
                }
                while payloadBytes > maximumBytes {
                    let oldestID = try connection.query(
                        """
                        SELECT id
                        FROM personalization_event
                        ORDER BY captured_at_ms ASC, sequence ASC
                        LIMIT 1
                        """
                    ).first?.text(at: 0)
                    guard let oldestID else { break }
                    try connection.execute(
                        "DELETE FROM personalization_event WHERE id = ?",
                        bindings: [.text(oldestID)]
                    )
                    try pruneUnusedTextChunks()
                    payloadBytes = try encryptedPayloadBytes()
                }
            }
            try pruneUnusedScopes()
            try pruneUnusedTextChunks()
        }
        return countBefore - (try eventCount())
    }

    private func rebuildCompletionEpisodeIndexes() throws {
        try validateEventRowsForDestructiveOperation()
        let episodes = try supportedStoredCompletionEpisodes()
        var chunkCache: [Data: Data] = [:]
        for episode in episodes {
            for chunkHMAC in episode.referencedChunkHMACs {
                _ = try loadTextChunk(
                    chunkHMAC,
                    chunkCache: &chunkCache,
                    missingChunkMessage:
                        "Missing authenticated completion episode text chunk"
                )
            }
        }
        try connection.execute("DELETE FROM completion_episode_source")
        try connection.execute("DELETE FROM event_text_chunk")
        for episode in episodes {
            let sourceEventIDs = (episode.invocation.sourceEventIDs ?? [])
                .reduce(
                    into: [UUID]()
                ) { result, id in
                    if !result.contains(id) {
                        result.append(id)
                    }
                }
            let allSourcesExist = try sourceEventIDs.allSatisfy { id in
                try connection.query(
                    """
                    SELECT 1
                    FROM personalization_event
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(id.uuidString)]
                ).first != nil
            }
            guard allSourcesExist else {
                try connection.execute(
                    "DELETE FROM personalization_event WHERE id = ?",
                    bindings: [.text(episode.id.uuidString)]
                )
                continue
            }
            for chunkHMAC in episode.referencedChunkHMACs {
                try connection.execute(
                    """
                    INSERT INTO event_text_chunk (event_id, chunk_hmac)
                    VALUES (?, ?)
                    """,
                    bindings: [
                        .text(episode.id.uuidString),
                        .blob(chunkHMAC),
                    ]
                )
            }
            for sourceEventID in sourceEventIDs {
                try connection.execute(
                    """
                    INSERT INTO completion_episode_source (
                        completion_event_id,
                        source_event_id
                    ) VALUES (?, ?)
                    """,
                    bindings: [
                        .text(episode.id.uuidString),
                        .text(sourceEventID.uuidString),
                    ]
                )
            }
        }
    }

    private func validateEventRowsForDestructiveOperation() throws {
        let rows = try connection.query(
            """
            SELECT id, kind, payload_sealed, payload_hmac
            FROM personalization_event
            ORDER BY sequence ASC
            """
        )
        for row in rows {
            guard let kind = row.text(at: 1) else {
                throw PersonalizationPersistenceError.database(
                    "Invalid personalization event row"
                )
            }
            let payload = try validatedEventPayload(
                row,
                idIndex: 0,
                kindIndex: 1,
                payloadIndex: 2,
                hmacIndex: 3,
                expectedKind: kind
            )
            switch kind {
            case Self.acceptedSuggestionKind:
                _ = try decoder.decode(
                    AcceptedSuggestionCapture.self,
                    from: payload
                )
            case Self.completionFeedbackKind:
                _ = try decoder.decode(
                    CompletionFeedbackCapture.self,
                    from: payload
                )
            case Self.writingEpisodeKind:
                _ = try decoder.decode(
                    WritingEpisodeCapture.self,
                    from: payload
                )
            case Self.completionEpisodeKind:
                if
                    let header = try? decoder.decode(
                        StoredCompletionEpisodeHeader.self,
                        from: payload
                    )
                {
                    guard
                        header.storageVersion
                            == StoredCompletionEpisode.currentStorageVersion
                    else {
                        throw PersonalizationPersistenceError.database(
                            "Unsupported completion episode storage version "
                                + "\(header.storageVersion)"
                        )
                    }
                    _ = try decoder.decode(
                        StoredCompletionEpisode.self,
                        from: payload
                    )
                } else {
                    _ = try decoder.decode(
                        CompletionEpisodeCapture.self,
                        from: payload
                    )
                }
            default:
                throw PersonalizationPersistenceError
                    .unsupportedEventKind(kind)
            }
        }
    }

    private func supportedStoredCompletionEpisodes() throws
        -> [StoredCompletionEpisode]
    {
        let rows = try connection.query(
            """
            SELECT id, kind, payload_sealed, payload_hmac
            FROM personalization_event
            WHERE kind = ?
            ORDER BY sequence ASC
            """,
            bindings: [.text(Self.completionEpisodeKind)]
        )
        return try rows.compactMap { row in
            let payload = try validatedEventPayload(
                row,
                idIndex: 0,
                kindIndex: 1,
                payloadIndex: 2,
                hmacIndex: 3,
                expectedKind: Self.completionEpisodeKind
            )
            guard let header = try? decoder.decode(
                StoredCompletionEpisodeHeader.self,
                from: payload
            ) else {
                throw PersonalizationPersistenceError.database(
                    "Invalid completion episode storage header"
                )
            }
            guard
                header.storageVersion
                    == StoredCompletionEpisode.currentStorageVersion
            else {
                throw PersonalizationPersistenceError.database(
                    "Unsupported completion episode storage version "
                        + "\(header.storageVersion)"
                )
            }
            return try decoder.decode(
                StoredCompletionEpisode.self,
                from: payload
            )
        }
    }

    private func rebuildSupportedEventScopeIndex() throws {
        for event in try acceptedSuggestions() {
            try replaceScopes(for: event.id, contexts: [event.context])
        }
        for event in try writingEpisodes() {
            try replaceScopes(for: event.id, contexts: [event.context])
        }
        for event in try completionFeedback() {
            try replaceScopes(for: event.id, contexts: [event.context])
        }
        for event in try supportedStoredCompletionEpisodes() {
            try replaceScopes(
                for: event.id,
                contexts:
                    [event.invocation.context]
                    + (event.invocation.sourceContexts ?? [])
            )
        }
    }

    private func rebuildSupportedEventTimestamps() throws {
        for event in try acceptedSuggestions() {
            try replaceTimestamp(
                for: event.id,
                capturedAt: event.capturedAt
            )
        }
        for event in try writingEpisodes() {
            try replaceTimestamp(for: event.id, capturedAt: event.endedAt)
        }
        for event in try completionFeedback() {
            try replaceTimestamp(
                for: event.id,
                capturedAt: event.capturedAt
            )
        }
        for event in try supportedStoredCompletionEpisodes() {
            try replaceTimestamp(for: event.id, capturedAt: event.endedAt)
        }
    }

    private func replaceTimestamp(
        for eventID: UUID,
        capturedAt: Date
    ) throws {
        try connection.execute(
            """
            UPDATE personalization_event
            SET captured_at_ms = ?
            WHERE id = ?
            """,
            bindings: [
                .integer(
                    Int64(capturedAt.timeIntervalSince1970 * 1_000)
                ),
                .text(eventID.uuidString),
            ]
        )
    }

    private func invalidateDerivedProjections() throws {
        try connection.execute("DELETE FROM personalization_embedding")
        try connection.execute(
            """
            DELETE FROM personalization_projection
            WHERE name IN (?, ?)
            """,
            bindings: [
                .text(Self.languageModelProjection),
                .text(Self.voiceAssessmentProjection),
            ]
        )
    }

    private func replaceScopes(
        for eventID: UUID,
        contexts: [PersonalizationContext]
    ) throws {
        try connection.execute(
            "DELETE FROM event_scope WHERE event_id = ?",
            bindings: [.text(eventID.uuidString)]
        )
        for scope in contexts.flatMap(scopes) {
            let scopeID = try upsertScope(scope)
            try connection.execute(
                """
                INSERT OR IGNORE INTO event_scope (event_id, scope_id)
                VALUES (?, ?)
                """,
                bindings: [
                    .text(eventID.uuidString),
                    .integer(scopeID),
                ]
            )
        }
    }

    private func encryptedPayloadBytes() throws -> Int {
        Int(
            try connection.query(
                """
                SELECT
                    (
                        SELECT COALESCE(
                            SUM(LENGTH(payload_sealed)),
                            0
                        )
                        FROM personalization_event
                    )
                    + (
                        SELECT COALESCE(
                            SUM(LENGTH(vector_sealed)),
                            0
                        )
                        FROM personalization_embedding
                    )
                    + (
                        SELECT COALESCE(
                            SUM(LENGTH(payload_sealed)),
                            0
                        )
                        FROM personalization_projection
                    )
                    + (
                        SELECT COALESCE(
                            SUM(LENGTH(payload_sealed)),
                            0
                        )
                        FROM personalization_text_chunk
                    )
                """
            ).first?.integer(at: 0) ?? 0
        )
    }

    private func pruneUnusedScopes() throws {
        try connection.execute(
            """
            DELETE FROM personalization_scope
            WHERE id NOT IN (SELECT DISTINCT scope_id FROM event_scope)
            """
        )
    }

    private func pruneUnusedTextChunks() throws {
        try connection.execute(
            """
            DELETE FROM personalization_text_chunk
            WHERE chunk_hmac NOT IN (
                SELECT DISTINCT chunk_hmac
                FROM event_text_chunk
            )
            """
        )
    }

    private func upsertScope(_ scope: PersonalizationScope) throws -> Int64 {
        let valueHMAC =
            try PersonalizationCryptography.scopeLookupHMAC(
                kind: scope.kind,
                value: scope.value,
                keyData: keyData
            )
        let sealedValue = try PersonalizationCryptography.seal(
            Data(scope.value.utf8),
            keyData: keyData
        )
        try connection.execute(
            """
            INSERT OR IGNORE INTO personalization_scope (
                kind,
                lookup_hmac,
                value_sealed,
                key_version,
                created_at_ms
            ) VALUES (?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(scope.kind),
                .blob(valueHMAC),
                .blob(sealedValue),
                .integer(Int64(Self.keyVersion)),
                .integer(Int64(Date().timeIntervalSince1970 * 1_000))
            ]
        )

        let rows = try connection.query(
            """
            SELECT id
            FROM personalization_scope
            WHERE kind = ? AND lookup_hmac = ?
            """,
            bindings: [.text(scope.kind), .blob(valueHMAC)]
        )
        guard let id = rows.first?.integer(at: 0) else {
            throw PersonalizationPersistenceError.database(
                "Failed to resolve inserted personalization scope"
            )
        }
        return id
    }

    private func scopes(
        from context: PersonalizationContext
    ) -> [PersonalizationScope] {
        [
            context.applicationBundleIdentifier.map {
                PersonalizationScope(kind: "application", value: $0)
            },
            context.website.map {
                PersonalizationScope(kind: "website", value: $0)
            },
            context.inputKind.map {
                PersonalizationScope(kind: "input_kind", value: $0)
            },
            context.detectedLanguage.map {
                PersonalizationScope(kind: "language", value: $0)
            }
        ].compactMap(\.self)
    }

    private static let schema =
        """
        CREATE TABLE IF NOT EXISTS personalization_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS personalization_scope (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,
            lookup_hmac BLOB NOT NULL,
            value_sealed BLOB NOT NULL,
            key_version INTEGER NOT NULL,
            created_at_ms INTEGER NOT NULL,
            UNIQUE(kind, lookup_hmac)
        );

        CREATE TABLE IF NOT EXISTS personalization_event (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            captured_at_ms INTEGER NOT NULL,
            payload_sealed BLOB NOT NULL,
            payload_hmac BLOB NOT NULL,
            key_version INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS personalization_event_kind_time
        ON personalization_event(kind, captured_at_ms DESC);

        CREATE TABLE IF NOT EXISTS pending_consent_event (
            event_id TEXT PRIMARY KEY
                REFERENCES personalization_event(id) ON DELETE CASCADE,
            collection_generation TEXT NOT NULL,
            direct_typing_generation TEXT NOT NULL
        );

        """

    private static let authenticatedConsentSchema = """
        CREATE TABLE IF NOT EXISTS personalization_event_consent (
            event_id TEXT PRIMARY KEY
                REFERENCES personalization_event(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            collection_generation TEXT NOT NULL,
            direct_typing_generation TEXT NOT NULL,
            state_hmac BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS personalization_schema_state (
            name TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            state_hmac BLOB NOT NULL
        );
        """

    private static let remainingSchema = """
        CREATE TABLE IF NOT EXISTS personalization_text_chunk (
            chunk_hmac BLOB PRIMARY KEY,
            payload_sealed BLOB NOT NULL,
            plaintext_byte_count INTEGER NOT NULL,
            key_version INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS event_text_chunk (
            event_id TEXT NOT NULL
                REFERENCES personalization_event(id) ON DELETE CASCADE,
            chunk_hmac BLOB NOT NULL
                REFERENCES personalization_text_chunk(chunk_hmac)
                    ON DELETE CASCADE,
            PRIMARY KEY(event_id, chunk_hmac)
        );

        CREATE INDEX IF NOT EXISTS event_text_chunk_chunk
        ON event_text_chunk(chunk_hmac);

        CREATE TABLE IF NOT EXISTS completion_episode_source (
            completion_event_id TEXT NOT NULL
                REFERENCES personalization_event(id) ON DELETE CASCADE,
            source_event_id TEXT NOT NULL
                REFERENCES personalization_event(id) ON DELETE CASCADE,
            PRIMARY KEY(completion_event_id, source_event_id)
        );

        CREATE INDEX IF NOT EXISTS completion_episode_source_source
        ON completion_episode_source(source_event_id);

        CREATE TRIGGER IF NOT EXISTS delete_completion_episode_with_source
        BEFORE DELETE ON personalization_event
        BEGIN
            DELETE FROM personalization_event
            WHERE id IN (
                SELECT completion_event_id
                FROM completion_episode_source
                WHERE source_event_id = OLD.id
            );
        END;

        CREATE TABLE IF NOT EXISTS event_scope (
            event_id TEXT NOT NULL
                REFERENCES personalization_event(id) ON DELETE CASCADE,
            scope_id INTEGER NOT NULL
                REFERENCES personalization_scope(id) ON DELETE CASCADE,
            PRIMARY KEY(event_id, scope_id)
        );

        CREATE TABLE IF NOT EXISTS projection_checkpoint (
            name TEXT PRIMARY KEY,
            version INTEGER NOT NULL,
            last_event_sequence INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS personalization_projection (
            name TEXT PRIMARY KEY,
            version INTEGER NOT NULL,
            payload_sealed BLOB NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS personalization_embedding (
            event_id TEXT PRIMARY KEY
                REFERENCES personalization_event(id) ON DELETE CASCADE,
            model_identifier TEXT NOT NULL,
            dimension INTEGER NOT NULL,
            vector_sealed BLOB NOT NULL,
            created_at_ms INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS personalization_embedding_model
        ON personalization_embedding(model_identifier);
        """
}

private struct PersonalizationScope {
    let kind: String
    let value: String
}

private enum SQLiteBinding {
    case blob(Data)
    case integer(Int64)
    case text(String)
}

private struct SQLiteRow {
    private let values: [SQLiteValue]

    init(statement: OpaquePointer) {
        values = (0..<sqlite3_column_count(statement)).map { index in
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                return .integer(sqlite3_column_int64(statement, index))
            case SQLITE_TEXT:
                guard let text = sqlite3_column_text(statement, index) else {
                    return .null
                }
                return .text(String(cString: text))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                guard
                    count > 0,
                    let bytes = sqlite3_column_blob(statement, index)
                else {
                    return .blob(Data())
                }
                return .blob(Data(bytes: bytes, count: count))
            default:
                return .null
            }
        }
    }

    func blob(at index: Int) -> Data? {
        guard case let .blob(value) = values[index] else { return nil }
        return value
    }

    func integer(at index: Int) -> Int64? {
        guard case let .integer(value) = values[index] else { return nil }
        return value
    }

    func text(at index: Int) -> String? {
        guard case let .text(value) = values[index] else { return nil }
        return value
    }
}

private enum SQLiteValue {
    case blob(Data)
    case integer(Int64)
    case null
    case text(String)
}

private final class SQLiteConnection: @unchecked Sendable {
    private let database: OpaquePointer

    init(databaseURL: URL) throws {
        var openedDatabase: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "Unable to open database"
            if let openedDatabase {
                sqlite3_close(openedDatabase)
            }
            throw PersonalizationPersistenceError.database(message)
        }
        database = openedDatabase
        sqlite3_busy_timeout(database, 2_000)
    }

    deinit {
        sqlite3_close(database)
    }

    func execute(
        _ sql: String,
        bindings: [SQLiteBinding] = []
    ) throws {
        if bindings.isEmpty {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(
                database,
                sql,
                nil,
                nil,
                &errorMessage
            )
            guard result == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) }
                    ?? errorDescription
                sqlite3_free(errorMessage)
                throw PersonalizationPersistenceError.database(message)
            }
            return
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersonalizationPersistenceError.database(errorDescription)
        }
    }

    func query(
        _ sql: String,
        bindings: [SQLiteBinding] = []
    ) throws -> [SQLiteRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [SQLiteRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(SQLiteRow(statement: statement))
            case SQLITE_DONE:
                return rows
            default:
                throw PersonalizationPersistenceError.database(
                    errorDescription
                )
            }
        }
    }

    @discardableResult
    func transaction<Value>(_ work: () throws -> Value) throws -> Value {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try work()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var changedRowCount: Int {
        Int(sqlite3_changes(database))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw PersonalizationPersistenceError.database(errorDescription)
        }
        return statement
    }

    private func bind(
        _ bindings: [SQLiteBinding],
        to statement: OpaquePointer
    ) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .blob(value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(value.count),
                        sqliteTransient
                    )
                }
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .text(value):
                result = value.withCString { text in
                    sqlite3_bind_text(
                        statement,
                        index,
                        text,
                        -1,
                        sqliteTransient
                    )
                }
            }
            guard result == SQLITE_OK else {
                throw PersonalizationPersistenceError.database(
                    errorDescription
                )
            }
        }
    }

    private var errorDescription: String {
        String(cString: sqlite3_errmsg(database))
    }
}

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
