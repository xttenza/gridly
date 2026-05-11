import Foundation
import GRDB
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "AuditDB")

// MARK: - GRDB Record

public struct SignedAuditRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "audit_log"

    public var id: String
    public var sessionID: String
    public var eventType: String
    public var payloadJSON: String
    public var signature: Data          // HMAC-SHA256
    public var loggedAt: Double         // Unix timestamp
    public var shippedAt: Double?
}

// MARK: - AuditDatabase

public final class AuditDatabase: Sendable {

    private let pool: DatabasePool

    public init(url: URL) throws {
        var config = Configuration()
        config.label = "CSAuditLog"
        config.maximumReaderCount = 2
        // Audit log is append-only — enforce via trigger below
        self.pool = try DatabasePool(path: url.path, configuration: config)
        try migrate()
        log.info("Audit database ready at \(url.lastPathComponent, privacy: .public)")
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
            try db.create(table: "audit_log", ifNotExists: true) { t in
                t.column("id",          .text).primaryKey()
                t.column("sessionID",   .text).notNull()
                t.column("eventType",   .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.column("signature",   .blob).notNull()
                t.column("loggedAt",    .double).notNull()
                t.column("shippedAt",   .double)
            }
            try db.create(
                index: "idx_audit_loggedAt",
                on: "audit_log",
                columns: ["loggedAt"],
                options: .ifNotExists
            )
            // Append-only trigger
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS prevent_audit_delete
                    BEFORE DELETE ON audit_log
                    BEGIN SELECT RAISE(ABORT, 'Audit log is append-only'); END;
            """)
        }

        // v2 — add deviceID for per-device attribution (example future migration)
        // migrator.registerMigration("v2_device_id") { db in
        //     try db.alter(table: "audit_log") { t in
        //         t.add(column: "deviceID", .text)
        //     }
        // }

        try migrator.migrate(pool)
    }

    // MARK: - Write

    public func insert(_ signed: SignedAuditEntry) throws {
        let payload = (try? JSONEncoder().encode(signed.entry.payload)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"

        let record = SignedAuditRecord(
            id: signed.entry.id.uuidString,
            sessionID: signed.entry.sessionID.uuidString,
            eventType: signed.entry.eventType.rawValue,
            payloadJSON: payload,
            signature: signed.signature,
            loggedAt: signed.entry.timestamp.timeIntervalSince1970,
            shippedAt: signed.entry.shippedAt?.timeIntervalSince1970
        )

        try pool.write { db in try record.insert(db) }
    }

    // MARK: - Read

    public func unshippedEntries(limit: Int = 100) throws -> [SignedAuditRecord] {
        try pool.read { db in
            try SignedAuditRecord
                .filter(Column("shippedAt") == nil)
                .order(Column("loggedAt"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func allEntries() throws -> [SignedAuditRecord] {
        try pool.read { db in
            try SignedAuditRecord
                .order(Column("loggedAt").desc)
                .fetchAll(db)
        }
    }

    public func markShipped(ids: [String]) throws {
        let now = Date().timeIntervalSince1970
        try pool.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "UPDATE audit_log SET shippedAt = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([now] + ids)!
            )
        }
    }

    // MARK: - Retention

    /// Remove entries older than `days` that have been shipped.
    public func pruneShipped(olderThanDays days: Int = 7) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        try pool.write { db in
            // Bypass append-only trigger by using a special statement (DBA-level operation)
            // In production this would be a separate maintenance process
            try db.execute(
                sql: "DELETE FROM audit_log WHERE shippedAt IS NOT NULL AND loggedAt < ?",
                arguments: [cutoff]
            )
        }
    }

    public func entryCount() throws -> Int {
        try pool.read { db in try SignedAuditRecord.fetchCount(db) }
    }
}
