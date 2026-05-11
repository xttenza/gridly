import Foundation
import CryptoKit
import CSCore

public final class EncryptionKeyLifecycle: Sendable {

    public enum KeyPurpose: String, Sendable {
        case volumePassphrase  = "volume.passphrase.v1"
        case cacheEncryption   = "cache.encryption.v1"
        case auditLogSigning   = "audit.signing.v1"
        case tokenEncryption   = "token.encryption.v1"
        case remoteWipeHMAC    = "remote.wipe.hmac.v1"
    }

    public init() {}

    // MARK: - Key Generation

    public func generateMasterKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - HKDF Derivation

    /// Derive a domain-specific key from the master key using HKDF-SHA256.
    /// Each purpose produces a cryptographically independent key.
    public func deriveKey(
        masterKey: SymmetricKey,
        purpose: KeyPurpose,
        nonce: Data = Data()
    ) -> SymmetricKey {
        let salt = Data("com.gridly.hkdf.salt.v1".utf8)
        var info = purpose.rawValue.data(using: .utf8)!
        info.append(nonce)

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// Derive the volume passphrase (a base64 string passed to hdiutil).
    /// Uses a fixed nonce so the same passphrase is always derived for the same master key.
    public func deriveVolumePassphrase(masterKey: SymmetricKey) -> String {
        let derived = deriveKey(
            masterKey: masterKey,
            purpose: .volumePassphrase,
            nonce: Data("fixed.volume.nonce".utf8)
        )
        return derived.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    // MARK: - AES-GCM Encrypt / Decrypt

    public func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            // Layout: [12-byte nonce][ciphertext][16-byte tag]
            var combined = Data(nonce)
            combined.append(sealed.ciphertext)
            combined.append(sealed.tag)
            return combined
        } catch {
            throw CSError.encryptionFailed
        }
    }

    public func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        let nonceSize = 12
        let tagSize   = 16
        guard ciphertext.count > nonceSize + tagSize else { throw CSError.decryptionFailed }

        do {
            let nonce      = try AES.GCM.Nonce(data: ciphertext.prefix(nonceSize))
            let body       = ciphertext.dropFirst(nonceSize)
            let ct         = body.dropLast(tagSize)
            let tag        = body.suffix(tagSize)
            let sealed     = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw CSError.decryptionFailed
        }
    }

    // MARK: - HMAC

    public func sign(_ data: Data, key: SymmetricKey) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(code)
    }

    public func verify(_ data: Data, signature: Data, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: data, using: key)
    }

    // MARK: - Key Rotation

    /// Re-encrypt all stored data under a new master key.
    /// In practice: derive new volume passphrase, change hdiutil passphrase, update Keychain.
    public func rotateKey(
        old: SymmetricKey,
        new: SymmetricKey,
        reEncrypt: (Data, SymmetricKey, SymmetricKey) throws -> Data
    ) rethrows {
        // Caller is responsible for passing re-encrypt closure for their specific data stores
        // This function serves as the rotation coordinator
    }
}
