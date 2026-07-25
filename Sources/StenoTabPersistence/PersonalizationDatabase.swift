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

public struct PersonalizationCorpusExport: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let exportedAt: Date
    public let acceptedSuggestions: [AcceptedSuggestionCapture]
    public let completionFeedback: [CompletionFeedbackCapture]
    public let writingEpisodes: [WritingEpisodeCapture]

    public init(
        formatVersion: Int = 1,
        exportedAt: Date,
        acceptedSuggestions: [AcceptedSuggestionCapture],
        completionFeedback: [CompletionFeedbackCapture],
        writingEpisodes: [WritingEpisodeCapture]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.acceptedSuggestions = acceptedSuggestions
        self.completionFeedback = completionFeedback
        self.writingEpisodes = writingEpisodes
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
    private static let languageModelProjection = "personal_language_model"
    private static let voiceAssessmentProjection = "voice_assessment"
    private static let keyVersion = 1

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
        try connection.execute("PRAGMA journal_mode = DELETE")
        try connection.execute(Self.schema)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
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

    public func record(_ episode: WritingEpisodeCapture) throws {
        try recordEvent(
            id: episode.id,
            kind: Self.writingEpisodeKind,
            capturedAt: episode.endedAt,
            payload: episode,
            context: episode.context
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

    private func recordEvent<Payload: Encodable>(
        id: UUID,
        kind: String,
        capturedAt: Date,
        payload value: Payload,
        context: PersonalizationContext
    ) throws {
        let payload = try encoder.encode(value)
        let sealedPayload = try PersonalizationCryptography.seal(
            payload,
            keyData: keyData
        )
        let payloadHMAC = try PersonalizationCryptography.payloadHMAC(
            for: payload,
            keyData: keyData
        )

        try connection.transaction {
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
                    .integer(Int64(Self.keyVersion))
                ]
            )

            for scope in scopes(from: context) {
                let scopeID = try upsertScope(scope)
                try connection.execute(
                    """
                    INSERT OR IGNORE INTO event_scope (event_id, scope_id)
                    VALUES (?, ?)
                    """,
                    bindings: [
                        .text(id.uuidString),
                        .integer(scopeID)
                    ]
                )
            }
        }
    }

    public func acceptedSuggestions(
        limit: Int? = nil
    ) throws -> [AcceptedSuggestionCapture] {
        try decodedEvents(
            kind: Self.acceptedSuggestionKind,
            as: AcceptedSuggestionCapture.self,
            limit: limit
        )
    }

    public func writingEpisodes(
        limit: Int? = nil
    ) throws -> [WritingEpisodeCapture] {
        try decodedEvents(
            kind: Self.writingEpisodeKind,
            as: WritingEpisodeCapture.self,
            limit: limit
        )
    }

    public func completionFeedback() throws
        -> [CompletionFeedbackCapture]
    {
        try decodedEvents(
            kind: Self.completionFeedbackKind,
            as: CompletionFeedbackCapture.self
        )
    }

    private func decodedEvents<Value: Decodable>(
        kind expectedKind: String,
        as type: Value.Type,
        limit: Int? = nil
    ) throws -> [Value] {
        let order = limit == nil ? "ASC" : "DESC"
        let limitClause = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        let rows = try connection.query(
            """
            SELECT kind, payload_sealed
            FROM personalization_event
            WHERE kind = ?
            ORDER BY sequence \(order)\(limitClause)
            """,
            bindings: [.text(expectedKind)]
        )

        let decoded = try rows.map { row in
            guard
                let kind = row.text(at: 0),
                kind == expectedKind,
                let sealedPayload = row.blob(at: 1)
            else {
                throw PersonalizationPersistenceError.unsupportedEventKind(
                    row.text(at: 0) ?? "<missing>"
                )
            }

            let payload = try PersonalizationCryptography.open(
                sealedPayload,
                keyData: keyData
            )
            return try decoder.decode(type, from: payload)
        }
        return limit == nil ? decoded : Array(decoded.reversed())
    }

    public func exportCorpus(
        at date: Date = Date()
    ) throws -> PersonalizationCorpusExport {
        PersonalizationCorpusExport(
            exportedAt: date,
            acceptedSuggestions: try acceptedSuggestions(),
            completionFeedback: try completionFeedback(),
            writingEpisodes: try writingEpisodes()
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
            try connection.execute("DELETE FROM event_scope")
            try connection.execute("DELETE FROM personalization_event")
            try connection.execute("DELETE FROM personalization_scope")
            try connection.execute("DELETE FROM projection_checkpoint")
            try connection.execute("DELETE FROM personalization_projection")
        }
    }

    public func deleteEvent(id: UUID) throws {
        try connection.transaction {
            try connection.execute(
                "DELETE FROM personalization_event WHERE id = ?",
                bindings: [.text(id.uuidString)]
            )
            try pruneUnusedScopes()
        }
    }

    @discardableResult
    public func deleteEvents(
        scopeKind: String,
        value: String
    ) throws -> Int {
        let lookupHMAC = try PersonalizationCryptography.lookupHMAC(
            for: value,
            keyData: keyData
        )
        return try connection.transaction {
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
            try pruneUnusedScopes()
            return deleted
        }
    }

    public func storageStatistics() throws
        -> PersonalizationStorageStatistics
    {
        let row = try connection.query(
            """
            SELECT
                COUNT(*),
                COALESCE(SUM(LENGTH(payload_sealed)), 0),
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
            }

            if let maximumBytes = policy.maximumEncryptedBytes {
                var payloadBytes = try encryptedPayloadBytes()
                if payloadBytes > maximumBytes {
                    let oldest = try connection.query(
                        """
                        SELECT id, LENGTH(payload_sealed)
                        FROM personalization_event
                        ORDER BY captured_at_ms ASC, sequence ASC
                        """
                    )
                    for row in oldest where payloadBytes > maximumBytes {
                        guard
                            let id = row.text(at: 0),
                            let bytes = row.integer(at: 1)
                        else {
                            continue
                        }
                        try connection.execute(
                            """
                            DELETE FROM personalization_event WHERE id = ?
                            """,
                            bindings: [.text(id)]
                        )
                        payloadBytes -= Int(bytes)
                    }
                }
            }
            try pruneUnusedScopes()
        }
        return countBefore - (try eventCount())
    }

    private func encryptedPayloadBytes() throws -> Int {
        Int(
            try connection.query(
                """
                SELECT COALESCE(SUM(LENGTH(payload_sealed)), 0)
                FROM personalization_event
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

    private func upsertScope(_ scope: PersonalizationScope) throws -> Int64 {
        let valueHMAC = try PersonalizationCryptography.lookupHMAC(
            for: scope.value,
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
