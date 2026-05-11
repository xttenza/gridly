import Foundation
import SwiftUI

public enum ComplianceState: String, Codable, Sendable, CaseIterable {
    case compliant
    case noncompliant
    case unknown
    case notApplicable
    case error
    case conflict
    case checking

    public var displayName: String {
        switch self {
        case .compliant:      return "Compliant"
        case .noncompliant:   return "Non-Compliant"
        case .unknown:        return "Unknown"
        case .notApplicable:  return "Not Applicable"
        case .error:          return "Error"
        case .conflict:       return "Conflict"
        case .checking:       return "Checking…"
        }
    }

    public var description: String {
        switch self {
        case .compliant:
            return "Your device meets all security requirements."
        case .noncompliant:
            return "Your device does not meet security requirements. Access may be restricted."
        case .unknown:
            return "Compliance status could not be determined."
        case .notApplicable:
            return "Compliance policies do not apply to this device."
        case .error:
            return "An error occurred while checking compliance."
        case .conflict:
            return "Conflicting compliance policies detected."
        case .checking:
            return "Verifying compliance with your organization's policies…"
        }
    }

    public var systemImage: String {
        switch self {
        case .compliant:     return "checkmark.shield.fill"
        case .noncompliant:  return "xmark.shield.fill"
        case .unknown:       return "questionmark.circle.fill"
        case .notApplicable: return "minus.circle.fill"
        case .error:         return "exclamationmark.triangle.fill"
        case .conflict:      return "exclamationmark.shield.fill"
        case .checking:      return "shield"
        }
    }

    public var color: Color {
        switch self {
        case .compliant:     return .green
        case .noncompliant:  return .red
        case .unknown:       return .gray
        case .notApplicable: return .gray
        case .error:         return .orange
        case .conflict:      return .yellow
        case .checking:      return .blue
        }
    }

    public var blocksWorkspace: Bool {
        self == .noncompliant || self == .error
    }
}

public struct ComplianceReport: Codable, Sendable {
    public let deviceID: String
    public let complianceState: ComplianceState
    public let lastSyncDateTime: Date
    public let noncompliantReasons: [NoncompliantReason]
    public let nextCheckDateTime: Date?

    public init(
        deviceID: String,
        complianceState: ComplianceState,
        lastSyncDateTime: Date,
        noncompliantReasons: [NoncompliantReason],
        nextCheckDateTime: Date?
    ) {
        self.deviceID = deviceID
        self.complianceState = complianceState
        self.lastSyncDateTime = lastSyncDateTime
        self.noncompliantReasons = noncompliantReasons
        self.nextCheckDateTime = nextCheckDateTime
    }

    public struct NoncompliantReason: Codable, Sendable, Identifiable {
        public let id: String
        public let displayName: String
        public let description: String
        public let remediationURL: URL?

        public init(id: String, displayName: String, description: String, remediationURL: URL?) {
            self.id = id
            self.displayName = displayName
            self.description = description
            self.remediationURL = remediationURL
        }
    }
}
