import Foundation
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "IntuneCompliance")

public actor IntuneComplianceEngine {

    private let graphClient: GraphClientProtocol
    private let cache: PolicyCache
    private let networkMonitor: NetworkMonitor
    private var deviceID: String?

    public init(
        graphClient: GraphClientProtocol,
        cache: PolicyCache,
        networkMonitor: NetworkMonitor
    ) {
        self.graphClient = graphClient
        self.cache = cache
        self.networkMonitor = networkMonitor
    }

    // MARK: - Compliance Check

    public func checkCompliance(userPrincipalName: String) async throws -> ComplianceReport {
        guard networkMonitor.isConnected else {
            log.warning("Offline — using cached compliance report")
            if let cached: ComplianceReport = try cache.retrieve(
                ComplianceReport.self, policyType: "compliance", tenantID: userPrincipalName
            ) { return cached }
            // Return safe default if no cache
            return ComplianceReport(
                deviceID: deviceID ?? "unknown",
                complianceState: .unknown,
                lastSyncDateTime: Date(),
                noncompliantReasons: [],
                nextCheckDateTime: Date().addingTimeInterval(3600)
            )
        }

        let report = try await fetchComplianceReport()
        try cache.store(report, type: "compliance", tenantID: userPrincipalName)
        log.info("Compliance: \(report.complianceState.rawValue, privacy: .public)")
        return report
    }

    // MARK: - Device Registration

    public func registerDevice(session: WorkspaceSession, deviceInfo: DeviceInfo) async throws -> String {
        // Check if already registered
        if let cached = try cache.retrieveDeviceRegistration(serialNumber: deviceInfo.serialNumber),
           let existingID = cached.intuneDeviceID {
            deviceID = existingID
            return existingID
        }

        let payload = DeviceRegistrationPayload(
            operatingSystem: "macOS",
            osVersion: deviceInfo.macOSVersion,
            deviceName: Host.current().name ?? "Mac",
            serialNumber: deviceInfo.serialNumber,
            model: deviceInfo.modelIdentifier,
            enrollmentType: "CorporateOwnedSingleUser",
            managementAgent: "Gridly/1.0"
        )

        let id = try await graphClient.registerDevice(payload: payload)
        deviceID = id

        try cache.storeDeviceRegistration(
            intuneDeviceID: id,
            entraDeviceID: nil,
            serialNumber: deviceInfo.serialNumber,
            complianceState: .unknown
        )

        log.info("Device registered with Intune: \(id, privacy: .public)")
        return id
    }

    // MARK: - App Protection Policy

    public func fetchAppProtectionPolicies() async throws -> [AppProtectionPolicy] {
        let policies = try await graphClient.fetchAppProtectionPolicies()
        try cache.store(policies, type: "appProtectionPolicies", tenantID: "global")
        return policies
    }

    public func cachedAppProtectionPolicies() throws -> [AppProtectionPolicy]? {
        try cache.retrieve([AppProtectionPolicy].self, policyType: "appProtectionPolicies", tenantID: "global")
    }

    /// Seed the device ID without a full registration flow — used in demo and testing.
    public func setDeviceID(_ id: String) {
        deviceID = id
    }

    // MARK: - Remote Commands

    public func pollRemoteCommands() async throws -> [RemoteCommand] {
        guard let deviceID else { return [] }
        return try await graphClient.fetchRemoteCommands(deviceID: deviceID)
    }

    // MARK: - Private

    private func fetchComplianceReport() async throws -> ComplianceReport {
        guard let deviceID else {
            return ComplianceReport(
                deviceID: "unregistered",
                complianceState: .unknown,
                lastSyncDateTime: Date(),
                noncompliantReasons: [],
                nextCheckDateTime: nil
            )
        }
        return try await graphClient.fetchComplianceReport(deviceID: deviceID)
    }
}

// MARK: - Supporting Types

public struct DeviceInfo: Sendable {
    public let serialNumber: String
    public let modelIdentifier: String
    public let macOSVersion: String
}

public struct DeviceRegistrationPayload: Codable, Sendable {
    public let operatingSystem: String
    public let osVersion: String
    public let deviceName: String
    public let serialNumber: String
    public let model: String
    public let enrollmentType: String
    public let managementAgent: String
}

public struct AppProtectionPolicy: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let allowedOutboundClipboardSharingLevel: String
    public let screenCaptureBlocked: Bool
    public let pinRequired: Bool
    public let encryptAppData: Bool
    public let periodOfflineBeforeWipeIsEnforced: String
}

public struct RemoteCommand: Codable, Sendable, Identifiable {
    public let id: String
    public let commandType: CommandType
    public let initiatedBy: String
    public let issuedAt: Date
    public let signature: String

    public enum CommandType: String, Codable, Sendable {
        case wipe = "WIPE"
        case lock = "LOCK"
        case policyUpdate = "POLICY_UPDATE"
        case syncRequest = "SYNC"
    }
}

// MARK: - GraphClientProtocol (testable abstraction)

public protocol GraphClientProtocol: Sendable {
    func registerDevice(payload: DeviceRegistrationPayload) async throws -> String
    func fetchComplianceReport(deviceID: String) async throws -> ComplianceReport
    func fetchAppProtectionPolicies() async throws -> [AppProtectionPolicy]
    func fetchRemoteCommands(deviceID: String) async throws -> [RemoteCommand]
}
