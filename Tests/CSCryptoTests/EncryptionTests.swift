import XCTest
import CryptoKit
@testable import CSCrypto

final class EncryptionKeyLifecycleTests: XCTestCase {

    private let crypto = EncryptionKeyLifecycle()

    // MARK: - Round-trip encrypt/decrypt

    func testEncryptDecryptRoundTrip() throws {
        let masterKey = crypto.generateMasterKey()
        let plaintext = "Gridly test payload 🔒".data(using: .utf8)!

        let ciphertext = try crypto.encrypt(plaintext, key: masterKey)
        let decrypted  = try crypto.decrypt(ciphertext, key: masterKey)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptProducesDifferentCiphertextEachTime() throws {
        let key       = crypto.generateMasterKey()
        let plaintext = Data("same plaintext".utf8)

        let ct1 = try crypto.encrypt(plaintext, key: key)
        let ct2 = try crypto.encrypt(plaintext, key: key)
        XCTAssertNotEqual(ct1, ct2, "Each encryption must use a fresh random nonce")
    }

    func testDecryptWithWrongKeyFails() throws {
        let key1 = crypto.generateMasterKey()
        let key2 = crypto.generateMasterKey()
        let ct   = try crypto.encrypt(Data("secret".utf8), key: key1)

        XCTAssertThrowsError(try crypto.decrypt(ct, key: key2))
    }

    func testDecryptTruncatedCiphertextFails() throws {
        let key = crypto.generateMasterKey()
        let ct  = try crypto.encrypt(Data("data".utf8), key: key)
        let truncated = ct.prefix(10)
        XCTAssertThrowsError(try crypto.decrypt(Data(truncated), key: key))
    }

    // MARK: - HKDF Derivation

    func testDeriveKeyProducesDifferentKeysPerPurpose() {
        let master = crypto.generateMasterKey()
        let k1 = crypto.deriveKey(masterKey: master, purpose: .volumePassphrase)
        let k2 = crypto.deriveKey(masterKey: master, purpose: .cacheEncryption)

        let bytes1 = k1.withUnsafeBytes { Data($0) }
        let bytes2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(bytes1, bytes2)
    }

    func testDeriveKeyIsDeterministicForSameInput() {
        let master = crypto.generateMasterKey()
        let k1 = crypto.deriveKey(masterKey: master, purpose: .volumePassphrase)
        let k2 = crypto.deriveKey(masterKey: master, purpose: .volumePassphrase)

        let bytes1 = k1.withUnsafeBytes { Data($0) }
        let bytes2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertEqual(bytes1, bytes2, "Same input must produce same derived key")
    }

    func testDeriveVolumePassphraseIsBase64() {
        let master     = crypto.generateMasterKey()
        let passphrase = crypto.deriveVolumePassphrase(masterKey: master)
        XCTAssertNotNil(Data(base64Encoded: passphrase))
        XCTAssertFalse(passphrase.isEmpty)
    }

    // MARK: - HMAC

    func testHMACSigns() {
        let key  = crypto.generateMasterKey()
        let data = Data("sign me".utf8)
        let sig  = crypto.sign(data, key: key)
        XCTAssertFalse(sig.isEmpty)
        XCTAssertTrue(crypto.verify(data, signature: sig, key: key))
    }

    func testHMACFailsOnTamperedData() {
        let key  = crypto.generateMasterKey()
        let data = Data("sign me".utf8)
        let sig  = crypto.sign(data, key: key)
        let tampered = Data("sign ME".utf8)
        XCTAssertFalse(crypto.verify(tampered, signature: sig, key: key))
    }

    func testHMACFailsOnTamperedSignature() {
        let key  = crypto.generateMasterKey()
        let data = Data("sign me".utf8)
        var sig  = crypto.sign(data, key: key)
        sig[0]  ^= 0xFF  // Flip first byte
        XCTAssertFalse(crypto.verify(data, signature: sig, key: key))
    }

    // MARK: - Performance

    func testEncryptPerformance() throws {
        let key  = crypto.generateMasterKey()
        let data = Data(repeating: 0xAB, count: 1024 * 1024)  // 1 MB
        measure {
            _ = try? self.crypto.encrypt(data, key: key)
        }
    }
}
