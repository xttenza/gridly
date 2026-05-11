import Foundation
import AppKit
import CSCore
import CSAuth
import os.log

private let log = Logger(subsystem: "com.gridly", category: "CompanyProfileManager")

// MARK: - CompanyProfileManager

/// Orchestrates the end-to-end setup and lifecycle of Company Profile SSO (Tier 1).
///
/// Responsibilities:
///  - Tenant discovery from a work email address.
///  - Driving the CompanyPortalBridge for broker token acquisition.
///  - Persisting `CompanyProfileConfig` changes back to the profile registry
///    (via the caller's ProfileManager).
///  - Silent token refresh on profile activation.
///  - Sign-out / disconnect.
///
/// This is intentionally kept separate from the macOS ProfileManager so the
/// company-profile logic can evolve independently and be reused by GridlyMobile.
@MainActor
public final class CompanyProfileManager: ObservableObject {

    // MARK: - Setup state (drives the wizard UI)

    public enum SetupStep: Equatable {
        case idle
        case discoveringTenant
        case tenantFound(TenantInfo)
        case checkingPortal
        case portalMissing
        case awaitingConsent(TenantInfo)
        case authenticating
        case complete(CompanyProfileConfig)
        case failed(String)
    }

    @Published public private(set) var step: SetupStep = .idle
    @Published public private(set) var portalStatus: CompanyPortalStatus = .notInstalled

    // MARK: - Dependencies

    private let discovery: TenantDiscovery
    private let bridge: CompanyPortalBridge

    public init(
        discovery: TenantDiscovery = TenantDiscovery(),
        bridge: CompanyPortalBridge = CompanyPortalBridge()
    ) {
        self.discovery = discovery
        self.bridge = bridge
    }

    // MARK: - Wizard steps

    /// Step 1: Validate email and discover the tenant.
    public func discoverTenant(email: String) async {
        step = .discoveringTenant
        do {
            let info = try await discovery.discover(email: email)
            step = .tenantFound(info)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    /// Step 2: Check Company Portal and advance to consent or portalMissing.
    public func checkCompanyPortal(for tenantInfo: TenantInfo) async {
        step = .checkingPortal
        let status = await bridge.portalStatus()
        portalStatus = status
        switch status {
        case .installed:
            step = .awaitingConsent(tenantInfo)
        case .notInstalled:
            step = .portalMissing
        }
    }

    /// Called when user confirms consent and wants to sign in.
    /// Advances to `.authenticating` then calls the broker.
    public func authenticate(
        tenantInfo: TenantInfo,
        loginHint: String?,
        clientID: String = CompanyProfileConfig.defaultClientID,
        presentingWindow: NSWindow
    ) async -> CompanyProfileConfig? {
        step = .authenticating
        do {
            let tokenResult = try await bridge.acquireTokenInteractive(
                clientID: clientID,
                tenantID: tenantInfo.tenantID,
                scopes: CompanyPortalBridge.tier1Scopes,
                loginHint: loginHint,
                presentingWindow: presentingWindow
            )

            var config = CompanyProfileConfig(
                tenantID: tenantInfo.tenantID,
                tenantDomain: tenantInfo.domain,
                tenantDisplayName: tenantInfo.displayName,
                clientID: clientID,
                tier: .ssoOnly,
                isAuthenticated: true,
                userPrincipalName: tokenResult.upn.isEmpty ? loginHint : tokenResult.upn,
                brokerAccountID: tokenResult.accountID,
                enrolledAt: Date(),
                lastBrokerAuthAt: Date(),
                isDeviceRegistered: false,
                privacyDisclosureAccepted: true
            )

            // Check if device appeared in Entra ID (non-blocking; update async)
            Task {
                let regStatus = await bridge.deviceRegistrationStatus(
                    clientID: clientID,
                    tenantID: tenantInfo.tenantID
                )
                if case .workplaceJoined = regStatus {
                    config.isDeviceRegistered = true
                    log.info("Device registered in Entra ID for tenant \(tenantInfo.tenantID, privacy: .public)")
                }
            }

            step = .complete(config)
            log.info("Company profile setup complete for tenant \(tenantInfo.tenantID, privacy: .public)")
            return config

        } catch {
            step = .failed(error.localizedDescription)
            log.error("Broker authentication failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Post-setup: silent refresh

    /// Attempts a silent SSO token refresh for an existing company profile.
    /// Should be called when the profile is activated.
    ///
    /// Returns `true` if refresh succeeded. Returns `false` if interactive re-auth is needed.
    public func refreshSilently(config: CompanyProfileConfig) async -> Bool {
        guard let accountID = config.brokerAccountID else { return false }
        do {
            let result = try await bridge.acquireTokenSilent(
                clientID: config.clientID,
                tenantID: config.tenantID,
                scopes: CompanyPortalBridge.tier1Scopes,
                accountID: accountID
            )
            return result != nil
        } catch {
            log.warning("Silent refresh failed for \(config.tenantDomain, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Re-authenticates interactively when the broker session has expired.
    public func reauthenticate(
        config: inout CompanyProfileConfig,
        presentingWindow: NSWindow
    ) async -> Bool {
        step = .authenticating
        do {
            let result = try await bridge.acquireTokenInteractive(
                clientID: config.clientID,
                tenantID: config.tenantID,
                scopes: CompanyPortalBridge.tier1Scopes,
                loginHint: config.tenantDomain.isEmpty ? nil : config.tenantDomain,
                presentingWindow: presentingWindow
            )
            config.brokerAccountID = result.accountID
            config.lastBrokerAuthAt = Date()
            config.isAuthenticated = true
            if !result.upn.isEmpty { config.userPrincipalName = result.upn }
            step = .complete(config)
            return true
        } catch {
            step = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: - Disconnect

    /// Removes the company profile configuration and signs out from MSAL.
    /// The sign-out is fire-and-forget (actor isolation prevents calling it synchronously).
    public func disconnect(config: CompanyProfileConfig) {
        step = .idle
        Task {
            do {
                if let accountID = config.brokerAccountID {
                    try await bridge.signOut(
                        clientID: config.clientID,
                        tenantID: config.tenantID,
                        accountID: accountID
                    )
                }
                log.info("Disconnected company profile for \(config.tenantDomain, privacy: .public)")
            } catch {
                log.error("Sign-out error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Portal helpers

    public func openPortalInstallPage() {
        Task { await bridge.openInstallPage() }
    }

    public func openCompanyPortal() {
        Task { await bridge.openCompanyPortal() }
    }

    public func refreshPortalStatus() async {
        portalStatus = await bridge.portalStatus()
    }

    // MARK: - Wizard reset

    public func reset() {
        step = .idle
    }
}
