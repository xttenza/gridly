import Foundation
import CryptoKit
import CSCore

/// Thin wrapper providing encrypted read/write to any URL using AES-GCM.
public final class SecureStorage: Sendable {

    private let crypto: EncryptionKeyLifecycle
    private let key: SymmetricKey

    public init(key: SymmetricKey, crypto: EncryptionKeyLifecycle = EncryptionKeyLifecycle()) {
        self.key = key
        self.crypto = crypto
    }

    public func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        let encrypted = try crypto.encrypt(data, key: key)
        try encrypted.write(to: url, options: [.atomic])
    }

    public func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let encrypted = try Data(contentsOf: url)
        let data = try crypto.decrypt(encrypted, key: key)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func writeData(_ data: Data, to url: URL) throws {
        let encrypted = try crypto.encrypt(data, key: key)
        try encrypted.write(to: url, options: [.atomic])
    }

    public func readData(from url: URL) throws -> Data {
        let encrypted = try Data(contentsOf: url)
        return try crypto.decrypt(encrypted, key: key)
    }
}
