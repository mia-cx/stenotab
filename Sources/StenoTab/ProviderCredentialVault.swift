import Foundation
import Security

protocol ProviderCredentialVault {
    func credential(for providerID: String) throws -> String?
    func setCredential(_ credential: String?, for providerID: String) throws
}

struct KeychainProviderCredentialVault: ProviderCredentialVault {
    enum VaultError: LocalizedError {
        case invalidCredentialData
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidCredentialData:
                "The provider credential could not be encoded."
            case let .keychain(status):
                SecCopyErrorMessageString(status, nil) as String?
                    ?? "Keychain error \(status)"
            }
        }
    }

    private let service = "cx.mia.stenotab.providers"

    func credential(for providerID: String) throws -> String? {
        var query = baseQuery(providerID: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw VaultError.keychain(status)
        }
        guard
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw VaultError.invalidCredentialData
        }
        return value
    }

    func setCredential(
        _ credential: String?,
        for providerID: String
    ) throws {
        let normalized = credential?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let normalized, !normalized.isEmpty else {
            let status = SecItemDelete(
                baseQuery(providerID: providerID) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw VaultError.keychain(status)
            }
            return
        }
        guard let data = normalized.data(using: .utf8) else {
            throw VaultError.invalidCredentialData
        }

        let query = baseQuery(providerID: providerID)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw VaultError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VaultError.keychain(addStatus)
        }
    }

    private func baseQuery(providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
