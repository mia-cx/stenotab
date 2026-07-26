import CryptoKit
import Foundation
import Security

public protocol PersonalizationKeyProviding: Sendable {
    func keyData() throws -> Data
    func authenticatedConsentSchemaVersion() throws -> Int?
    func persistAuthenticatedConsentSchemaVersion(_ version: Int) throws
}

public extension PersonalizationKeyProviding {
    func authenticatedConsentSchemaVersion() throws -> Int? {
        nil
    }

    func persistAuthenticatedConsentSchemaVersion(_ version: Int) throws {}
}

public struct StaticPersonalizationKeyProvider: PersonalizationKeyProviding {
    private let key: Data

    public init(keyData: Data) {
        key = keyData
    }

    public func keyData() throws -> Data {
        key
    }
}

public struct KeychainPersonalizationKeyProvider:
    PersonalizationKeyProviding
{
    public static let defaultService =
        "cx.mia.stenotab.personalization"
    public static let defaultAccount = "corpus-key-v1"

    private let service: String
    private let account: String

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func keyData() throws -> Data {
        if let existing = try existingKey() {
            return existing
        }

        var bytes = [UInt8](
            repeating: 0,
            count: PersonalizationCryptography.keyByteCount
        )
        let randomStatus = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        )
        guard randomStatus == errSecSuccess else {
            throw PersonalizationPersistenceError.keychain(randomStatus)
        }
        let generated = Data(bytes)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: generated
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return generated
        case errSecDuplicateItem:
            guard let existing = try existingKey() else {
                throw PersonalizationPersistenceError.keychain(addStatus)
            }
            return existing
        default:
            throw PersonalizationPersistenceError.keychain(addStatus)
        }
    }

    public func authenticatedConsentSchemaVersion() throws -> Int? {
        guard let data = try existingData(account: consentSchemaAccount) else {
            return nil
        }
        guard
            let text = String(data: data, encoding: .utf8),
            let version = Int(text),
            version >= 0
        else {
            throw PersonalizationPersistenceError.database(
                "Keychain returned an invalid consent schema version"
            )
        }
        return version
    }

    public func persistAuthenticatedConsentSchemaVersion(
        _ version: Int
    ) throws {
        let data = Data(String(version).utf8)
        let query = baseQuery(account: consentSchemaAccount)
        let addQuery = query.merging([
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw PersonalizationPersistenceError.keychain(updateStatus)
            }
        default:
            throw PersonalizationPersistenceError.keychain(addStatus)
        }
    }

    public func deleteKey() throws {
        for targetAccount in [account, consentSchemaAccount] {
            let status = SecItemDelete(
                baseQuery(account: targetAccount) as CFDictionary
            )
            guard
                status == errSecSuccess || status == errSecItemNotFound
            else {
                throw PersonalizationPersistenceError.keychain(status)
            }
        }
    }

    private func existingKey() throws -> Data? {
        guard let data = try existingData(account: account) else {
            return nil
        }
        guard data.count == PersonalizationCryptography.keyByteCount else {
            throw PersonalizationPersistenceError.invalidKeyLength(
                expected: PersonalizationCryptography.keyByteCount,
                actual: data.count
            )
        }
        return data
    }

    private func existingData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw PersonalizationPersistenceError.database(
                    "Keychain returned an invalid personalization key"
                )
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw PersonalizationPersistenceError.keychain(status)
        }
    }

    private var consentSchemaAccount: String {
        account + ".authenticated-consent-schema"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum PersonalizationCryptography {
    static let keyByteCount = 64
    private static let encryptionKeyByteCount = 32

    static func seal(_ plaintext: Data, keyData: Data) throws -> Data {
        let keys = try split(keyData)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: keys.encryption,
            authenticating: associatedData
        )
        guard let combined = sealedBox.combined else {
            throw PersonalizationPersistenceError.encryptionFailed
        }
        return combined
    }

    static func open(_ ciphertext: Data, keyData: Data) throws -> Data {
        let keys = try split(keyData)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(
            sealedBox,
            using: keys.encryption,
            authenticating: associatedData
        )
    }

    static func lookupHMAC(for value: String, keyData: Data) throws -> Data {
        let keys = try split(keyData)
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: Data(value.utf8),
                using: keys.lookup
            )
        )
    }

    static func scopeLookupHMAC(
        kind: String,
        value: String,
        keyData: Data
    ) throws -> Data {
        let keys = try split(keyData)
        var authenticatedValue = Data(
            "cx.mia.stenotab.personalization:scope:v2".utf8
        )
        authenticatedValue.append(0)
        authenticatedValue.append(contentsOf: kind.utf8)
        authenticatedValue.append(0)
        authenticatedValue.append(contentsOf: value.utf8)
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: authenticatedValue,
                using: keys.lookup
            )
        )
    }

    static func payloadHMAC(for payload: Data, keyData: Data) throws -> Data {
        let keys = try split(keyData)
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: payload,
                using: keys.lookup
            )
        )
    }

    private static let associatedData =
        Data("cx.mia.stenotab.personalization:v1".utf8)

    private static func split(
        _ keyData: Data
    ) throws -> (encryption: SymmetricKey, lookup: SymmetricKey) {
        guard keyData.count == keyByteCount else {
            throw PersonalizationPersistenceError.invalidKeyLength(
                expected: keyByteCount,
                actual: keyData.count
            )
        }

        let encryptionRange = 0..<encryptionKeyByteCount
        let lookupRange = encryptionKeyByteCount..<keyByteCount
        return (
            SymmetricKey(data: keyData.subdata(in: encryptionRange)),
            SymmetricKey(data: keyData.subdata(in: lookupRange))
        )
    }
}
