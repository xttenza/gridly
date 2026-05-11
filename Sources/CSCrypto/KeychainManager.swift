import Foundation
import Security
import CryptoKit
import CSCore

public final class KeychainManager: Sendable {

    private let service: String
    private let accessGroup: String?

    public init(
        service: String = "com.gridly.workspace",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Workspace DEK (Data Encryption Key)

    /// Stores the workspace DEK, protected by biometric + Secure Enclave ACL.
    /// This key never leaves the device. Destroying it = cryptographic wipe.
    public func storeWorkspaceDEK(_ dek: SymmetricKey, accountID: String) throws {
        let keyData = dek.withUnsafeBytes { Data($0) }

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &accessError
        ) else {
            if let err = accessError?.takeRetainedValue() { throw err as Error }
            throw CSError.keyGenerationFailed
        }

        var query = baseQuery(service: "\(service).dek", account: accountID)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessControl as String] = access

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var updateAttrs: [String: Any] = [kSecValueData as String: keyData]
            updateAttrs[kSecAttrAccessControl as String] = access
            let findQuery = baseQuery(service: "\(service).dek", account: accountID)
            let updateStatus = SecItemUpdate(findQuery as CFDictionary, updateAttrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CSError.keychainInsertFailed(updateStatus)
            }
        } else if status != errSecSuccess {
            throw CSError.keychainInsertFailed(status)
        }
    }

    public func retrieveWorkspaceDEK(accountID: String) throws -> SymmetricKey {
        var query = baseQuery(service: "\(service).dek", account: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Prompt presented by the OS via Biometry
        query[kSecUseOperationPrompt as String] = "Authenticate to unlock your corporate workspace"

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw status == errSecItemNotFound ? CSError.keychainItemNotFound : CSError.keychainReadFailed(status)
        }
        return SymmetricKey(data: data)
    }

    /// Cryptographic erasure — deleting the DEK makes the entire encrypted volume permanently unreadable
    public func destroyWorkspaceDEK(accountID: String) throws {
        let query = baseQuery(service: "\(service).dek", account: accountID)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CSError.keychainDeleteFailed(status)
        }
    }

    // MARK: - Access Token

    public func storeAccessToken(_ token: String, accountID: String, expiresAt: Date) throws {
        guard let tokenData = token.data(using: .utf8) else { throw CSError.keychainEncodingFailed }

        var query = baseQuery(service: "\(service).accessToken", account: accountID)
        query[kSecValueData as String] = tokenData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrLabel as String] = ISO8601DateFormatter().string(from: expiresAt)

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttrs: [String: Any] = [
                kSecValueData as String: tokenData,
                kSecAttrLabel as String: ISO8601DateFormatter().string(from: expiresAt)
            ]
            SecItemUpdate(baseQuery(service: "\(service).accessToken", account: accountID) as CFDictionary,
                          updateAttrs as CFDictionary)
        } else if status != errSecSuccess {
            throw CSError.keychainInsertFailed(status)
        }
    }

    public func retrieveAccessToken(accountID: String) throws -> (token: String, expiresAt: Date)? {
        var query = baseQuery(service: "\(service).accessToken", account: accountID)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let tokenData = attrs[kSecValueData as String] as? Data,
              let token = String(data: tokenData, encoding: .utf8) else {
            if status == errSecItemNotFound { return nil }
            throw CSError.keychainReadFailed(status)
        }

        var expiresAt = Date.distantFuture
        if let label = attrs[kSecAttrLabel as String] as? String {
            expiresAt = ISO8601DateFormatter().date(from: label) ?? .distantFuture
        }

        return (token, expiresAt)
    }

    // MARK: - Generic Secure Storage

    public func store(data: Data, key: String) throws {
        var query = baseQuery(service: service, account: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(
                baseQuery(service: service, account: key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } else if status != errSecSuccess {
            throw CSError.keychainInsertFailed(status)
        }
    }

    public func retrieve(key: String) throws -> Data? {
        var query = baseQuery(service: service, account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CSError.keychainReadFailed(status) }
        return result as? Data
    }

    public func delete(key: String) throws {
        let query = baseQuery(service: service, account: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CSError.keychainDeleteFailed(status)
        }
    }

    /// Wipe all workspace-related keychain items for this service
    public func deleteAllWorkspaceItems() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CSError.keychainDeleteFailed(status)
        }
    }

    // MARK: - Private Helpers

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let group = accessGroup {
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }
}
