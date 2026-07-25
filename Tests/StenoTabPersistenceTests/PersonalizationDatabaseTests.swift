import CompletionCore
import Foundation
@testable import StenoTabPersistence
import XCTest

final class PersonalizationDatabaseTests: XCTestCase {
    func testKeychainProviderReturnsStable64ByteKey() throws {
        let provider = KeychainPersonalizationKeyProvider(
            service: "cx.mia.stenotab.tests.\(UUID().uuidString)",
            account: "corpus-key"
        )
        defer { try? provider.deleteKeyForTesting() }

        let first = try provider.keyData()
        let second = try provider.keyData()

        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(second, first)
        XCTAssertNotEqual(first, Data(repeating: 0, count: 64))
    }

    func testAcceptedCaptureRoundTripsEncryptedAndCanBeDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appending(path: "personalization.sqlite")
        let database = try PersonalizationDatabase(
            databaseURL: databaseURL,
            keyProvider: StaticPersonalizationKeyProvider(
                keyData: Data(repeating: 0x42, count: 64)
            )
        )
        let capture = try XCTUnwrap(
            PersonalizationCapture.acceptedSuggestion(
                id: UUID(uuidString: "86AE8A8C-9705-4D35-AEAB-A97603580366")!,
                fieldText: "private complete field text",
                selection: UTF16Selection(location: 27, length: 0),
                insertion: " with literal space",
                acceptanceScope: .nextWord,
                context: PersonalizationContext(
                    applicationBundleIdentifier: "com.example.Editor",
                    website: "example.com",
                    inputKind: "comment",
                    detectedLanguage: "en",
                    editorIdentifier: "editor-1"
                ),
                capturedAt: Date(timeIntervalSince1970: 123)
            )
        )

        try await database.record(capture)

        let storedCaptures = try await database.acceptedSuggestions()
        let storedEventCount = try await database.eventCount()
        XCTAssertEqual(storedCaptures, [capture])
        XCTAssertEqual(storedEventCount, 1)

        let bytes = try Data(contentsOf: databaseURL)
        XCTAssertNil(
            bytes.range(of: Data("private complete field text".utf8))
        )
        XCTAssertNil(
            bytes.range(of: Data(" with literal space".utf8))
        )
        XCTAssertNil(bytes.range(of: Data("example.com".utf8)))

        try await database.deleteAll()

        let deletedEventCount = try await database.eventCount()
        let deletedCaptures = try await database.acceptedSuggestions()
        XCTAssertEqual(deletedEventCount, 0)
        XCTAssertEqual(deletedCaptures, [])
    }
}
