import Foundation
import AppKit
import CSCore
import CSAuth
import os.log

private let log = Logger(subsystem: "com.gridly", category: "UserEnrollmentCoordinator")

// MARK: - UserEnrollmentCoordinator

/// Drives the Tier 2 upgrade flow: Apple User Enrollment via Microsoft Intune.
///
/// Tier 2 adds MDM policy enforcement (Wi-Fi, VPN, certificates, managed apps)
/// scoped exclusively to the user's managed APFS volume. The company still cannot
/// wipe personal data or access personal files.
///
/// Flow:
///   Checking requirements → Consent → Open Company Portal → Awaiting enrollment
///   → Detecting MDM profile → Configuring VPN → Complete
@MainActor
public final class UserEnrollmentCoordinator: ObservableObject {

    // MARK: - State machine

    public enum Step: Equatable {
        /// Not started.
        case idle
        /// Verifying Tier 1 SSO is active and Company Portal is installed.
        case checkingRequirements
        /// Requirements met; waiting for the user to read the disclosure and confirm.
        case awaitingConsent(tenantName: String)
        /// Company Portal has been opened; user is going through the enrollment flow.
        case enrollingInCompanyPortal
        /// Company Portal is done; polling `profiles` to detect MDM profile installation.
        case detectingMDMProfile(attempt: Int)
        /// MDM profile detected; applying per-profile VPN configuration.
        case configuringVPN
        /// Enrollment and VPN setup complete.
        case complete(updatedConfig: CompanyProfileConfig)
        /// Something went wrong.
        case failed(String)
    }

    @Published public private(set) var step: Step = .idle
    /// Progress fraction 0…1 for step indicators.
    @Published public private(set) var progress: Double = 0

    // MARK: - Dependencies

    private let enrollmentClient: UserEnrollmentClient
    private let vpnManager: PerAppVPNManager

    public init(
        enrollmentClient: UserEnrollmentClient = UserEnrollmentClient(),
        vpnManager: PerAppVPNManager = PerAppVPNManager()
    ) {
        self.enrollmentClient = enrollmentClient
        self.vpnManager = vpnManager
    }

    // MARK: - Entry point

    /// Begin the Tier 2 upgrade for an existing Tier 1 config.
    public func startUpgrade(config: CompanyProfileConfig) async {
        step = .checkingRequirements
        progress = 0.1

        // 1. Make sure the existing Tier 1 SSO is authenticated
        guard config.isAuthenticated else {
            step = .failed("Please complete Tier 1 SSO sign-in before upgrading.")
            return
        }

        // 2. Check if already enrolled via MDM
        let currentStatus = await enrollmentClient.enrollmentStatus()
        if currentStatus.isEnrolled {
            log.info("Device already enrolled in MDM — promoting directly to Tier 2")
            await finalise(config: config, mdmStatus: currentStatus)
            return
        }

        progress = 0.2
        step = .awaitingConsent(tenantName: config.tenantDisplayName)
    }

    /// Called when the user taps "Enrol now" on the consent screen.
    public func beginEnrollment(config: CompanyProfileConfig) async {
        step = .enrollingInCompanyPortal
        progress = 0.35

        // Open Company Portal — the user manually completes enrollment there
        await enrollmentClient.startEnrollment()

        // Give the user time to complete the flow, then start polling
        try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s head-start
        await pollForEnrollment(config: config)
    }

    /// Allows the user to re-trigger detection after completing enrollment manually.
    public func checkNow(config: CompanyProfileConfig) async {
        await pollForEnrollment(config: config, maxAttempts: 1)
    }

    // MARK: - Polling

    private func pollForEnrollment(config: CompanyProfileConfig, maxAttempts: Int = 36) async {
        // Poll for up to ~3 minutes (36 × 5s)
        for attempt in 1...maxAttempts {
            step = .detectingMDMProfile(attempt: attempt)
            progress = min(0.35 + Double(attempt) / Double(maxAttempts) * 0.4, 0.75)

            let status = await enrollmentClient.enrollmentStatus()
            if status.isEnrolled {
                await finalise(config: config, mdmStatus: status)
                return
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        step = .failed(
            "MDM profile was not detected after 3 minutes. " +
            "Please complete enrollment in Company Portal, then tap 'Check again'."
        )
    }

    // MARK: - Finalisation

    private func finalise(config: CompanyProfileConfig, mdmStatus: MDMEnrollmentStatus) async {
        step = .configuringVPN
        progress = 0.80

        // Configure per-profile VPN if the MDM payload includes a VPN server
        var vpnEndpoint: String? = nil
        if let serverURL = mdmStatus.serverURL,
           let host = URL(string: serverURL)?.host {
            do {
                try await vpnManager.configure(profileID: config.tenantID, serverHost: host)
                vpnEndpoint = host
                log.info("Per-profile VPN configured for host \(host, privacy: .public)")
            } catch {
                // VPN is non-fatal — log and continue
                log.warning("VPN configuration failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }

        progress = 1.0

        var upgraded = config
        upgraded.tier = .userEnrolled
        upgraded.isDeviceRegistered = true
        upgraded.mdmServerURL        = mdmStatus.serverURL
        upgraded.mdmOrganisationName = mdmStatus.organisationName
        upgraded.isUserEnrollment    = mdmStatus.isUserEnrollment
        upgraded.vpnEndpoint         = vpnEndpoint
        upgraded.userEnrolledAt      = Date()

        step = .complete(updatedConfig: upgraded)
        log.info("Tier 2 enrollment complete for \(config.tenantDisplayName, privacy: .public)")
    }

    // MARK: - Reset

    public func reset() {
        step = .idle
        progress = 0
    }

    // MARK: - Open helpers

    public func openProfilesPreferencePane() {
        Task { await enrollmentClient.openProfilesPreferencePane() }
    }
}
