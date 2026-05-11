import Foundation

public struct WorkspaceSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public var userPrincipalName: String
    public var displayName: String
    public var tenantID: String
    public var accessTokenExpiresAt: Date
    public var isAuthenticated: Bool
    public var complianceStatus: ComplianceState
    public var sessionStartedAt: Date
    public var lastActiveAt: Date
    public var deviceID: String?

    public init(
        id: UUID = UUID(),
        userPrincipalName: String,
        displayName: String,
        tenantID: String,
        accessTokenExpiresAt: Date,
        isAuthenticated: Bool,
        complianceStatus: ComplianceState,
        sessionStartedAt: Date = Date(),
        lastActiveAt: Date = Date(),
        deviceID: String? = nil
    ) {
        self.id = id
        self.userPrincipalName = userPrincipalName
        self.displayName = displayName
        self.tenantID = tenantID
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.isAuthenticated = isAuthenticated
        self.complianceStatus = complianceStatus
        self.sessionStartedAt = sessionStartedAt
        self.lastActiveAt = lastActiveAt
        self.deviceID = deviceID
    }

    public var isTokenExpired: Bool {
        accessTokenExpiresAt < Date()
    }

    public var sessionDuration: TimeInterval {
        Date().timeIntervalSince(sessionStartedAt)
    }
}
