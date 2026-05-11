import Foundation
import GRDB
import CryptoKit
import os.log
import CSCore
import CSCrypto

private let log = Logger(subsystem: "com.gridly", category: "PolicyCache")

// MARK: - GRDB Records

public struct PolicyCacheRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "policy_cache"
    public var id: String
    public var policyType: String
    public var tenantID: String
    public var fetchedAt: Double       // Unix timestamp
    public var expiresAt: Double
    public var payload: Data           // AES-GCM encrypted JSON
    public var signature: Data         // HMAC-SHA256 of payload
}

public struct DeviceRegistrationRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "device_registration"
    public var id: String
    public var intuneDeviceID: String?
    public var entraDeviceID: String?
    public var serialNumber: String
    public var registeredAt: Double
    public var lastCheckIn: Double
    public var complianceState: String
}

// MARK: - PolicyCache

public final class PolicyCache: Sendable {

    private let dbPool: DatabasePool
    private let crypto: EncryptionKeyLifecycle
    private let cacheKey: SymmetricKey

    public static let defaultTTL: TimeInterval = 4 * 3600   // 4 hours

    public init(databaseURL: URL, cacheKey: SymmetricKey, crypto: EncryptionKeyLifecycle = EncryptionKeyLifecycle()) throws {
        var config = Configuration()
        config.label = "CSPolicyCache"
        config.maximumReaderCount = 4
        self.dbPool = try DatabasePool(path: databaseURL.path, configuration: config)
        self.cacheKey = cacheKey
        self.crypto = crypto
        try migrate()
    }

    // MARK: - Versioned Migrations
    //
    // Rule: never edit an existing migration block — always add a new one.
    // GRDB tracks which migrations have run in the `grdb_migrations` table
    // and skips them on subsequent launches. This guarantees safe upgrades
    // from any previously installed version.

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        // v1 — initial schema (shipped with 1.0)
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "policy_cache", ifNotExists: true) { t in
                t.column("id",         .text).primaryKey()
                t.column("policyType", .text).notNull()
                t.column("tenantID",   .text).notNull()
                t.column("fetchedAt",  .double).notNull()
                t.column("expiresAt",  .double).notNull()
                t.column("payload",    .blob).notNull()
                t.column("signature",  .blob).notNull()
            }
            try db.create(table: "device_registration", ifNotExists: true) { t in
                t.column("id",              .text).primaryKey()
                t.column("intuneDeviceID",  .text).unique()
                t.column("entraDeviceID",   .text).unique()
                t.column("serialNumber",    .text).notNull()
                t.column("registeredAt",    .double).notNull()
                t.column("lastCheckIn",     .double).notNull()
                t.column("complianceState", .text).notNull().defaults(to: "unknown")
            }
        }

        // v2 example: add managed app list cache table
        // migrator.registerMigration("v2_app_cache") { db in
        //     try db.create(table: "managed_apps") { t in
        //         t.column("bundleID", .text).primaryKey()
        //         t.column("version",  .text).notNull()
        //         t.column("fetchedAt", .double).notNull()
        //     }
        // }

        try migrator.migrate(dbPool)
    }

    // MARK: - Store / Retrieve

    public func store<T: Encodable>(_ value: T, type policyType: String, tenantID: String, ttl: TimeInterval = defaultTTL) throws {
        let json = try JSONEncoder().encode(value)
        let encrypted = try crypto.encrypt(json, key: cacheKey)
        let sig = crypto.sign(encrypted, key: cacheKey)

        let record = PolicyCacheRecord(
            id: "\(policyType).\(tenantID)",
            policyType: policyType,
            tenantID: tenantID,
            fetchedAt: Date().timeIntervalSince1970,
            expiresAt: Date().addingTimeInterval(ttl).timeIntervalSince1970,
            payload: encrypted,
            signature: sig
        )

        try dbPool.write { db in try record.upsert(db) }
        log.info("Cached policy '\(policyType, privacy: .public)' TTL \(Int(ttl))s")
    }

    public func retrieve<T: Decodable>(_ type: T.Type, policyType: String, tenantID: String) throws -> T? {
        let now = Date().timeIntervalSince1970

        let record = try dbPool.read { db in
            try PolicyCacheRecord
                .filter(Column("policyType") == policyType &&
                        Column("tenantID")   == tenantID   &&
                        Column("expiresAt")  >  now)
                .fetchOne(db)
        }

        guard let record else { return nil }

        // Verify HMAC integrity before decrypting
        guard crypto.verify(record.payload, signature: record.signature, key: cacheKey) else {
            log.fault("Policy cache HMAC mismatch for '\(policyType, privacy: .public)' — possible tampering")
            throw CSError.policyTampered
        }

        let decrypted = try crypto.decrypt(record.payload, key: cacheKey)
        return try JSONDecoder().decode(T.self, from: decrypted)
    }

    public func invalidate(policyType: String, tenantID: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM policy_cache WHERE policyType = ? AND tenantID = ?",
                arguments: [policyType, tenantID]
            )
        }
    }

    public func invalidateAll() throws {
        try dbPool.write { db in try db.execute(sql: "DELETE FROM policy_cache") }
    }

    // MARK: - Device Registration

    public func storeDeviceRegistration(
        intuneDeviceID: String?,
        entraDeviceID: String?,
        serialNumber: String,
        complianceState: ComplianceState
    ) throws {
        let record = DeviceRegistrationRecord(
            id: serialNumber,
            intuneDeviceID: intuneDeviceID,
            entraDeviceID: entraDeviceID,
            serialNumber: serialNumber,
            registeredAt: Date().timeIntervalSince1970,
            lastCheckIn: Date().timeIntervalSince1970,
            complianceState: complianceState.rawValue
        )
        try dbPool.write { db in try record.upsert(db) }
    }

    public func retrieveDeviceRegistration(serialNumber: String) throws -> DeviceRegistrationRecord? {
        try dbPool.read { db in
            try DeviceRegistrationRecord
                .filter(Column("serialNumber") == serialNumber)
                .fetchOne(db)
        }
    }

    public func updateComplianceState(_ state: ComplianceState, serialNumber: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE device_registration SET complianceState = ?, lastCheckIn = ? WHERE serialNumber = ?",
                arguments: [state.rawValue, Date().timeIntervalSince1970, serialNumber]
            )
        }
    }
}
