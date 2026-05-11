import Foundation

public enum AuditEventType: String, Codable, Sendable {
    // Session lifecycle
    case workspaceOpened
    case workspaceLocked
    case workspaceUnlocked
    case workspaceWiped
    case sessionExpired

    // Authentication
    case authenticationSuccess
    case authenticationFailure
    case tokenRefreshed
    case tokenExpired
    case mfaCompleted

    // Applications
    case appLaunched
    case appTerminated

    // Clipboard
    case clipboardCopied
    case clipboardCleared
    case clipboardBlocked

    // Files
    case fileRead
    case fileWritten
    case fileCopied
    case fileMoved
    case fileDeleted
    case fileAccessBlocked

    // Policy
    case policyUpdated
    case policyViolation
    case complianceChecked
    case complianceChanged

    // Profile lifecycle (Knox-style multi-workspace isolation)
    case profileCreated
    case profileMounted
    case profileUnmounted
    case profileDeleted
    case profileAppLaunched

    // Security
    case remoteWipeReceived
    case tamperDetected
    case vpnConnected
    case vpnDisconnected
    case screenshotDetected
}

public struct AuditEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let eventType: AuditEventType
    public let payload: [String: String]
    public let timestamp: Date
    public var shippedAt: Date?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        eventType: AuditEventType,
        payload: [String: String] = [:],
        timestamp: Date = Date(),
        shippedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.eventType = eventType
        self.payload = payload
        self.timestamp = timestamp
        self.shippedAt = shippedAt
    }
}

public struct SignedAuditEntry: Codable, Sendable {
    public let entry: AuditEntry
    public let signature: Data  // HMAC-SHA256 over canonical JSON of entry

    public init(entry: AuditEntry, signature: Data) {
        self.entry = entry
        self.signature = signature
    }
}

public struct PolicyManifest: Codable, Sendable {
    public let version: String
    public let tenantID: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let lockTimeoutSeconds: Int
    public let clipboardPolicy: ClipboardPolicyConfig
    public let dlpEnabled: Bool
    public let watermarkEnabled: Bool
    public let remoteWipeEnabled: Bool
    public let auditShippingEndpointURL: String?
    public let allowedNetworkDomains: [String]
    public let blockedNetworkDomains: [String]
    public let requiredApps: [String]         // bundle IDs
    public let workspaceStorageQuotaGB: Int

    public struct ClipboardPolicyConfig: Codable, Sendable {
        public let blockCorporateToPersonal: Bool
        public let blockPersonalToCorporate: Bool
        public let watermarkCopiedText: Bool
    }

    public static let `default` = PolicyManifest(
        version: "1.0",
        tenantID: "",
        issuedAt: Date(),
        expiresAt: Date().addingTimeInterval(4 * 3600),
        lockTimeoutSeconds: 900,
        clipboardPolicy: .init(
            blockCorporateToPersonal: true,
            blockPersonalToCorporate: false,
            watermarkCopiedText: true
        ),
        dlpEnabled: true,
        watermarkEnabled: true,
        remoteWipeEnabled: true,
        auditShippingEndpointURL: nil,
        allowedNetworkDomains: [],
        blockedNetworkDomains: [],
        requiredApps: [],
        workspaceStorageQuotaGB: 50
    )
}
