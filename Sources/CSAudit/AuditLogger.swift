import Foundation
import CryptoKit
import os.log
import CSCore
import CSCrypto

private let logger = Logger(subsystem: "com.gridly", category: "AuditLogger")

public actor AuditLogger {

    private let db: AuditDatabase
    private let signingKey: SymmetricKey
    private let crypto: EncryptionKeyLifecycle
    private var shippingEndpointURL: URL?
    private let session = URLSession.shared

    public init(db: AuditDatabase, signingKey: SymmetricKey) {
        self.db = db
        self.signingKey = signingKey
        self.crypto = EncryptionKeyLifecycle()
    }

    public func configure(shippingEndpoint: URL?) {
        self.shippingEndpointURL = shippingEndpoint
    }

    // MARK: - Log Entry

    public func log(_ entry: AuditEntry) async {
        do {
            let signed = try sign(entry)
            try db.insert(signed)

            // Non-blocking background ship attempt
            Task.detached(priority: .background) { [weak self] in
                await self?.shipPending()
            }
        } catch {
            // Never let audit logging fail silently — write to unified log as fallback
            os_log(.fault, "AuditLogger: Failed to persist entry: %{public}s — %{public}s",
                   entry.eventType.rawValue, error.localizedDescription)
        }
    }

    // Convenience: log with explicit fields
    public func log(
        eventType: AuditEventType,
        sessionID: UUID,
        payload: [String: String] = [:]
    ) async {
        await log(AuditEntry(sessionID: sessionID, eventType: eventType, payload: payload))
    }

    // MARK: - Integrity Verification

    public func verifyIntegrity() throws -> LogIntegrityReport {
        let records = try db.allEntries()
        var verified = 0
        var tampered = 0

        for record in records {
            let canonical = canonicalString(
                id: record.id,
                sessionID: record.sessionID,
                eventType: record.eventType,
                payloadJSON: record.payloadJSON,
                loggedAt: record.loggedAt
            )
            guard let messageData = canonical.data(using: .utf8) else { tampered += 1; continue }

            if crypto.verify(messageData, signature: record.signature, key: signingKey) {
                verified += 1
            } else {
                tampered += 1
                logger.fault("Audit entry \(record.id, privacy: .public) FAILED integrity check")
            }
        }

        return LogIntegrityReport(
            totalEntries: records.count,
            verifiedEntries: verified,
            tamperedEntries: tampered,
            verifiedAt: Date()
        )
    }

    // MARK: - Query

    /// Returns the most recent audit records for display in the UI.
    public func fetchRecent(limit: Int = 200) throws -> [SignedAuditRecord] {
        try db.allEntries().prefix(limit).map { $0 }
    }

    // MARK: - Export

    public func exportSigned(outputURL: URL) throws {
        let records = try db.allEntries()
        let exportData = try JSONEncoder().encode(records.map { r in
            ["id": r.id,
             "sessionID": r.sessionID,
             "eventType": r.eventType,
             "payload": r.payloadJSON,
             "signature": r.signature.base64EncodedString(),
             "loggedAt": String(r.loggedAt)]
        })
        try exportData.write(to: outputURL, options: .atomic)
        logger.info("Exported \(records.count) audit entries to \(outputURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Shipping

    private func shipPending() async {
        guard let endpoint = shippingEndpointURL else { return }
        guard let unshipped = try? db.unshippedEntries(limit: 50), !unshipped.isEmpty else { return }

        do {
            let payload = try JSONEncoder().encode(unshipped.map {
                ["id": $0.id, "eventType": $0.eventType, "payload": $0.payloadJSON,
                 "signature": $0.signature.base64EncodedString(), "loggedAt": String($0.loggedAt)]
            })

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload

            let (_, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                try? db.markShipped(ids: unshipped.map(\.id))
                logger.info("Shipped \(unshipped.count) audit entries")
            }
        } catch {
            logger.warning("Audit shipping failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func sign(_ entry: AuditEntry) throws -> SignedAuditEntry {
        let payload = (try? JSONEncoder().encode(entry.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let canonical = canonicalString(
            id: entry.id.uuidString,
            sessionID: entry.sessionID.uuidString,
            eventType: entry.eventType.rawValue,
            payloadJSON: payload,
            loggedAt: entry.timestamp.timeIntervalSince1970
        )
        guard let message = canonical.data(using: .utf8) else { throw CSError.auditLogWriteFailed }
        let sig = crypto.sign(message, key: signingKey)
        return SignedAuditEntry(entry: entry, signature: sig)
    }

    private func canonicalString(id: String, sessionID: String, eventType: String, payloadJSON: String, loggedAt: Double) -> String {
        // Deterministic canonical form — all verifiers must produce identical bytes
        "\(id)|\(sessionID)|\(eventType)|\(payloadJSON)|\(loggedAt)"
    }
}

// MARK: - Supporting Types

public struct LogIntegrityReport: Sendable {
    public let totalEntries: Int
    public let verifiedEntries: Int
    public let tamperedEntries: Int
    public let verifiedAt: Date

    public var isClean: Bool { tamperedEntries == 0 }
}
