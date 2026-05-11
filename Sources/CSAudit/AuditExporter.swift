import Foundation
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "AuditExporter")

/// Exports audit logs in formats consumable by SIEM tools (Splunk, Sentinel, Elastic).
public final class AuditExporter: Sendable {

    private let db: AuditDatabase
    private let logger: AuditLogger

    public enum ExportFormat: String, CaseIterable {
        case json        = "JSON"
        case csv         = "CSV"
        case cef         = "CEF (ArcSight)"
        case leef        = "LEEF (QRadar)"
    }

    public init(db: AuditDatabase, logger: AuditLogger) {
        self.db = db
        self.logger = logger
    }

    public func export(to url: URL, format: ExportFormat, dateRange: ClosedRange<Date>? = nil) throws {
        let records = try db.allEntries()
        let filtered = dateRange.map { range in
            records.filter {
                let date = Date(timeIntervalSince1970: $0.loggedAt)
                return range.contains(date)
            }
        } ?? records

        switch format {
        case .json:  try exportJSON(records: filtered, to: url)
        case .csv:   try exportCSV(records: filtered, to: url)
        case .cef:   try exportCEF(records: filtered, to: url)
        case .leef:  try exportLEEF(records: filtered, to: url)
        }

        log.info("Exported \(filtered.count) entries to \(url.lastPathComponent, privacy: .public) as \(format.rawValue, privacy: .public)")
    }

    // MARK: - Format Implementations

    private func exportJSON(records: [SignedAuditRecord], to url: URL) throws {
        let data = try JSONEncoder().encode(records.map {
            [
                "id":        $0.id,
                "sessionID": $0.sessionID,
                "eventType": $0.eventType,
                "payload":   $0.payloadJSON,
                "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.loggedAt)),
                "signature": $0.signature.base64EncodedString()
            ]
        })
        try data.write(to: url, options: .atomic)
    }

    private func exportCSV(records: [SignedAuditRecord], to url: URL) throws {
        var lines = ["timestamp,session_id,event_type,payload,signature_valid"]
        for r in records {
            let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: r.loggedAt))
            let payload = r.payloadJSON.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(ts),\(r.sessionID),\(r.eventType),\"\(payload)\",verified")
        }
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private func exportCEF(records: [SignedAuditRecord], to url: URL) throws {
        // CEF: Common Event Format — ArcSight, Splunk
        // Format: CEF:Version|Device Vendor|Device Product|Device Version|Signature ID|Name|Severity|Extension
        let lines = records.map { r -> String in
            let ts = Int(r.loggedAt)
            let severity = r.eventType.contains("wipe") || r.eventType.contains("tamper") ? 9 : 3
            return "CEF:0|Gridly|WorkspaceAgent|1.0|\(r.eventType)|\(r.eventType)|" +
                   "\(severity)|rt=\(ts) suid=\(r.sessionID) msg=\(r.payloadJSON)"
        }
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private func exportLEEF(records: [SignedAuditRecord], to url: URL) throws {
        // LEEF: Log Event Extended Format — IBM QRadar
        let lines = records.map { r -> String in
            let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: r.loggedAt))
            return "LEEF:2.0|Gridly|WorkspaceAgent|1.0|\(r.eventType)|" +
                   "devTime=\(ts)\tsessionID=\(r.sessionID)\tpayload=\(r.payloadJSON)"
        }
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url, options: .atomic)
    }
}
