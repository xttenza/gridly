import Foundation
import CryptoKit
import CSCore
import CSCrypto

public actor TokenManager {

    private let keychainManager: KeychainManager
    private let crypto: EncryptionKeyLifecycle

    public init(keychainManager: KeychainManager, crypto: EncryptionKeyLifecycle = EncryptionKeyLifecycle()) {
        self.keychainManager = keychainManager
        self.crypto = crypto
    }

    // MARK: - Token Storage

    public func storeTokens(
        accessToken: String,
        idToken: String,
        expiresOn: Date,
        accountID: String
    ) throws {
        try keychainManager.storeAccessToken(accessToken, accountID: accountID, expiresAt: expiresOn)

        if !idToken.isEmpty, let idData = idToken.data(using: .utf8) {
            try keychainManager.store(data: idData, key: "idToken.\(accountID)")
        }

        let expData = withUnsafeBytes(of: expiresOn.timeIntervalSince1970) { Data($0) }
        try keychainManager.store(data: expData, key: "tokenExpiry.\(accountID)")
    }

    public func getValidAccessToken(accountID: String) async throws -> String {
        guard let (token, expiresAt) = try keychainManager.retrieveAccessToken(accountID: accountID) else {
            throw CSError.keychainItemNotFound
        }

        // Add 5-minute buffer before actual expiry to proactively refresh
        if expiresAt.timeIntervalSinceNow < 300 {
            throw CSError.tokenExpired
        }

        return token
    }

    public func isTokenValid(accountID: String) -> Bool {
        guard let (_, expiresAt) = try? keychainManager.retrieveAccessToken(accountID: accountID) else {
            return false
        }
        return expiresAt.timeIntervalSinceNow > 300
    }

    public func deleteAllTokens(accountID: String) throws {
        try? keychainManager.delete(key: "idToken.\(accountID)")
        try? keychainManager.delete(key: "tokenExpiry.\(accountID)")
        // Access token stored by MSAL internally; also remove our copy
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gridly.workspace.accessToken",
            kSecAttrAccount as String: accountID,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - JWT Claims (no signature verification — Entra ID tokens are verified server-side)

    public func extractClaims(from idToken: String) -> [String: Any] {
        let parts = idToken.components(separatedBy: ".")
        guard parts.count >= 2 else { return [:] }

        var payload = parts[1]
        // Base64url → base64
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padLen = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padLen)

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}
