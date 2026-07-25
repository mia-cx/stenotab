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

public actor PersonalizationDatabase {
    private static let acceptedSuggestionKind = "accepted_suggestion"
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
        let payload = try encoder.encode(capture)
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
                    .text(capture.id.uuidString),
                    .text(Self.acceptedSuggestionKind),
                    .integer(
                        Int64(capture.capturedAt.timeIntervalSince1970 * 1_000)
                    ),
                    .blob(sealedPayload),
                    .blob(payloadHMAC),
                    .integer(Int64(Self.keyVersion))
                ]
            )

            for scope in scopes(from: capture.context) {
                let scopeID = try upsertScope(scope)
                try connection.execute(
                    """
                    INSERT OR IGNORE INTO event_scope (event_id, scope_id)
                    VALUES (?, ?)
                    """,
                    bindings: [
                        .text(capture.id.uuidString),
                        .integer(scopeID)
                    ]
                )
            }
        }
    }

    public func acceptedSuggestions() throws -> [AcceptedSuggestionCapture] {
        let rows = try connection.query(
            """
            SELECT kind, payload_sealed
            FROM personalization_event
            WHERE kind = ?
            ORDER BY sequence ASC
            """,
            bindings: [.text(Self.acceptedSuggestionKind)]
        )

        return try rows.map { row in
            guard
                let kind = row.text(at: 0),
                kind == Self.acceptedSuggestionKind,
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
            return try decoder.decode(
                AcceptedSuggestionCapture.self,
                from: payload
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
        }
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

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
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
