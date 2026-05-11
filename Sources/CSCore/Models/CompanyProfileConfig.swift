import Foundation

// MARK: - CompanyProfileConfig

/// Describes how a WorkspaceProfile is linked to a Microsoft company/work identity.
///
/// When this is non-nil on a WorkspaceProfile the profile is a "Company Profile":
///  - Tier 1 (ssoOnly): MSAL broker SSO via Company Portal. No MDM policies pushed
///    by Gridly. The device appears in Entra ID for Conditional Access but the company
///    cannot wipe the Mac or push system-level settings.
///  - Tier 2 (userEnrolled): Apple User Enrollment. A separate APFS volume is created
///    by macOS and scoped to the MDM server. The company can push certs/Wi-Fi/VPN only
///    to that volume. Full personal data isolation. (Implemented in a future release.)
public struct CompanyProfileConfig: Codable, Sendable, Hashable {

    // MARK: - Tenant Identity

    /// Azure / Entra ID tenant ID (GUID).
    public var tenantID: String

    /// Primary email domain of the tenant — e.g. "contoso.com".
    public var tenantDomain: String

    /// Human-readable organisation name returned by the OpenID discovery endpoint.
    public var tenantDisplayName: String

    /// Entra ID application (client) ID used for MSAL token requests.
    /// Defaults to the Microsoft 365 well-known client ID if not specified by admin.
    public var clientID: String

    // MARK: - Tier

    public var tier: Tier

    public enum Tier: String, Codable, Sendable, CaseIterable {
        /// Tier 1: Broker SSO via Company Portal. No MDM payload pushed by Gridly.
        case ssoOnly

        /// Tier 2: Apple User Enrollment — separate MDM-managed APFS volume.
        /// Not yet implemented; reserved for a future release.
        case userEnrolled
    }

    // MARK: - State

    /// Whether the user has completed the broker sign-in step.
    public var isAuthenticated: Bool

    /// The User Principal Name (UPN / work email) returned by the broker after sign-in.
    /// Automatically populated from the MSAL token result; used to display the signed-in
    /// identity on the profile card.
    public var userPrincipalName: String?

    /// The MSAL account identifier (opaque) returned after successful broker auth.
    /// Used to acquire tokens silently on subsequent launches.
    public var brokerAccountID: String?

    /// When the company profile was first set up.
    public var enrolledAt: Date

    /// When broker authentication last succeeded (used to detect stale sessions).
    public var lastBrokerAuthAt: Date?

    /// Whether the device has appeared in Entra ID (confirmed via Graph "me/devices").
    public var isDeviceRegistered: Bool

    // MARK: - Privacy disclosure state

    /// Whether the user explicitly accepted the privacy disclosure screen.
    public var privacyDisclosureAccepted: Bool

    // MARK: - Tier 2 (User Enrollment) fields

    /// MDM server URL reported by the installed MDM profile (Intune, NanoMDM, etc.).
    public var mdmServerURL: String?

    /// Organisation name from the MDM payload (e.g. "Contoso IT").
    public var mdmOrganisationName: String?

    /// Whether this is an Apple User Enrollment (scoped) vs full-device enrollment.
    public var isUserEnrollment: Bool

    /// When the user completed Apple MDM enrollment (Tier 2).
    public var userEnrolledAt: Date?

    /// VPN server host configured for this profile after enrollment.
    public var vpnEndpoint: String?

    // MARK: - Init

    public init(
        tenantID: String,
        tenantDomain: String,
        tenantDisplayName: String,
        clientID: String = CompanyProfileConfig.defaultClientID,
        tier: Tier = .ssoOnly,
        isAuthenticated: Bool = false,
        userPrincipalName: String? = nil,
        brokerAccountID: String? = nil,
        enrolledAt: Date = Date(),
        lastBrokerAuthAt: Date? = nil,
        isDeviceRegistered: Bool = false,
        privacyDisclosureAccepted: Bool = false,
        mdmServerURL: String? = nil,
        mdmOrganisationName: String? = nil,
        isUserEnrollment: Bool = false,
        userEnrolledAt: Date? = nil,
        vpnEndpoint: String? = nil
    ) {
        self.tenantID = tenantID
        self.tenantDomain = tenantDomain
        self.tenantDisplayName = tenantDisplayName
        self.clientID = clientID
        self.tier = tier
        self.isAuthenticated = isAuthenticated
        self.userPrincipalName = userPrincipalName
        self.brokerAccountID = brokerAccountID
        self.enrolledAt = enrolledAt
        self.lastBrokerAuthAt = lastBrokerAuthAt
        self.isDeviceRegistered = isDeviceRegistered
        self.privacyDisclosureAccepted = privacyDisclosureAccepted
        self.mdmServerURL = mdmServerURL
        self.mdmOrganisationName = mdmOrganisationName
        self.isUserEnrollment = isUserEnrollment
        self.userEnrolledAt = userEnrolledAt
        self.vpnEndpoint = vpnEndpoint
    }

    // MARK: - Constants

    /// Microsoft 365 / Office well-known multi-tenant client ID.
    /// Works for most tenants without custom app registration.
    public static let defaultClientID = "d3590ed6-52b3-4102-aeff-aad2292ab01c"

    // MARK: - Derived

    /// A short human-readable label for the connection tier.
    public var tierLabel: String {
        switch tier {
        case .ssoOnly:     return "SSO Bridge"
        case .userEnrolled: return "User Enrolled"
        }
    }

    /// Approximate token age in minutes; nil if never authenticated.
    public var tokenAgeMinutes: Int? {
        guard let last = lastBrokerAuthAt else { return nil }
        return Int(Date().timeIntervalSince(last) / 60)
    }

    /// Whether the broker session is likely still valid (PRT refreshes every 4 hours).
    public var isBrokerSessionLikelyValid: Bool {
        guard let age = tokenAgeMinutes else { return false }
        return age < 240  // 4 hours
    }
}

// MARK: - What the company can and cannot do (Tier 1)

public extension CompanyProfileConfig {

    /// Human-readable capabilities the company gains at each tier.
    static func capabilities(for tier: Tier) -> (canDo: [String], cannotDo: [String]) {
        switch tier {
        case .ssoOnly:
            return (
                canDo: [
                    "Single sign-on across Microsoft 365 apps",
                    "Conditional Access policy enforcement",
                    "Revoke your work account tokens remotely",
                    "See that a device with this profile exists in Entra ID",
                ],
                cannotDo: [
                    "Wipe your Mac or personal files",
                    "See your personal apps or data",
                    "Push system settings or certificates",
                    "Track your location",
                    "See your real device serial number",
                ]
            )
        case .userEnrolled:
            return (
                canDo: [
                    "Everything in SSO Bridge, plus:",
                    "Push Wi-Fi, VPN, and certificate profiles",
                    "Deploy and remove managed apps",
                    "Remotely erase only the work data volume",
                ],
                cannotDo: [
                    "Erase your personal Mac volume",
                    "See personal apps or personal data",
                    "Access personal keychain items",
                    "See your real device serial number",
                    "Issue lock or passcode commands",
                ]
            )
        }
    }
}
