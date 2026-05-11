import Foundation
import CSCore

/// Evaluates Conditional Access signals locally before attempting token acquisition.
/// If signals indicate the device is blocked, we can show a friendly error before
/// the user sees a cryptic Entra ID denial.
public actor ConditionalAccessEvaluator {

    public enum CAResult: Sendable {
        case allowed
        case blocked(reason: String, remediationURL: URL?)
        case requiresMFA
        case requiresCompliantDevice
        case requiresPasswordChange
    }

    private let deviceTrust: DeviceTrustVerifier

    public init(deviceTrust: DeviceTrustVerifier) {
        self.deviceTrust = deviceTrust
    }

    public func evaluate(tenantID: String) async -> CAResult {
        let deviceInfo = await deviceTrust.collectDeviceInfo()
        let deviceIntegrity = await deviceTrust.verifyDeviceIntegrity()

        // Check OS version requirement (Intune typically requires macOS 12+)
        if !meetsMinOSRequirement(deviceInfo.macOSVersion) {
            return .blocked(
                reason: "macOS version \(deviceInfo.macOSVersion) does not meet the minimum requirement.",
                remediationURL: URL(string: "https://support.apple.com/en-us/HT201475")
            )
        }

        if !deviceIntegrity {
            return .requiresCompliantDevice
        }

        return .allowed
    }

    private func meetsMinOSRequirement(_ version: String) -> Bool {
        // Parse "macOS 13.x.x" style strings
        let components = version.components(separatedBy: " ")
        guard let versionStr = components.last else { return true }
        let parts = versionStr.components(separatedBy: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        return major >= 13
    }
}
