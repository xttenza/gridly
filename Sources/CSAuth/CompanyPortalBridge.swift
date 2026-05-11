import Foundation
import MSAL
import AppKit
import CSCore
import os.log

private let log = Logger(subsystem: "com.gridly", category: "CompanyPortalBridge")

// MARK: - CompanyPortalStatus

public enum CompanyPortalStatus: Sendable {
    case installed(version: String)
    case notInstalled
}

// MARK: - DeviceRegistrationStatus

public enum DeviceRegistrationStatus: Sendable {
    /// Device has not appeared in Entra ID yet.
    case notRegistered
    /// Workplace-joined via broker (Tier 1 SSO Bridge).
    case workplaceJoined(tenantID: String, deviceID: String?)
    /// Fully MDM-enrolled via Apple User Enrollment (Tier 2).
    case userEnrolled(tenantID: String, deviceID: String?)
}

// MARK: - BrokerTokenResult

public struct BrokerTokenResult: Sendable {
    public let accessToken: String
    public let idToken: String?
    public let accountID: String
    public let tenantID: String
    public let upn: String
    public let expiresOn: Date
    public let usedBroker: Bool
}

// MARK: - CompanyPortalBridge

/// Detects Microsoft Company Portal and uses it as an MSAL broker for
/// PRT-based SSO and Entra ID device registration.
///
/// When Company Portal is present MSAL routes interactive and silent token
/// requests through it, gaining access to the hardware-bound Primary Refresh
/// Token stored in the Secure Enclave. This satisfies Conditional Access
/// "device must be compliant" policies without Gridly pushing any MDM profile.
///
/// When Company Portal is absent the bridge falls back to standard MSAL
/// interactive auth (web view). The user can still sign in but Conditional
/// Access device-compliance checks may fail.
public actor CompanyPortalBridge {

    private static let companyPortalBundleID = "com.microsoft.CompanyPortalMac"
    private static let companyPortalMASBundleID = "com.microsoft.intune.companyportal"
    private static let appStoreURL = URL(string: "https://apps.apple.com/app/intune-company-portal/id869655554")!

    public init() {}

    // MARK: - Company Portal detection

    /// Checks whether Microsoft Company Portal is installed on this Mac.
    public func portalStatus() -> CompanyPortalStatus {
        let ids = [Self.companyPortalBundleID, Self.companyPortalMASBundleID]
        for bundleID in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let bundle = Bundle(url: url)
                let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                log.info("Company Portal found at \(url.path, privacy: .public) v\(version, privacy: .public)")
                return .installed(version: version)
            }
        }
        log.info("Company Portal not found")
        return .notInstalled
    }

    /// Opens the App Store listing for Microsoft Intune Company Portal.
    @MainActor
    public func openInstallPage() {
        NSWorkspace.shared.open(Self.appStoreURL)
    }

    /// Opens the Company Portal app if installed.
    @MainActor
    public func openCompanyPortal() {
        for id in [Self.companyPortalBundleID, Self.companyPortalMASBundleID] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                return
            }
        }
    }

    // MARK: - MSAL application factory

    /// Builds an MSALPublicClientApplication configured for broker SSO.
    /// Broker is set to `.auto` so MSAL uses Company Portal when available
    /// and falls back to an in-app web view when not.
    private func makeMSALApp(clientID: String, tenantID: String) throws -> MSALPublicClientApplication {
        let authorityURL = URL(string: "https://login.microsoftonline.com/\(tenantID)")!
        let authority = try MSALAADAuthority(url: authorityURL)

        let redirectURI = "msauth.\(Bundle.main.bundleIdentifier ?? "com.gridly.app")://auth"
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: redirectURI,
            authority: authority
        )
        // CP1 capability signals Continuous Access Evaluation support
        config.clientApplicationCapabilities = ["CP1"]

        // Auto: uses Company Portal when installed, falls back to embedded WebView
        MSALGlobalConfig.brokerAvailability = .auto

        return try MSALPublicClientApplication(configuration: config)
    }

    // MARK: - Device registration status

    /// Determines Entra ID / Workplace-Join registration status for the device.
    ///
    /// Strategy: when Company Portal is installed and a broker-backed account
    /// exists in the MSAL cache we attempt a silent token request. If MSAL
    /// routes it through the broker and returns a result the device has a
    /// Workplace-Join relationship with the tenant — no separate WPJ metadata
    /// API call is required. If the silent request fails or no account is
    /// cached, the device is not yet registered.
    public func deviceRegistrationStatus(
        clientID: String,
        tenantID: String,
        accountID: String? = nil
    ) async -> DeviceRegistrationStatus {
        guard case .installed = portalStatus() else { return .notRegistered }

        do {
            let app = try makeMSALApp(clientID: clientID, tenantID: tenantID)
            let accounts = try app.allAccounts()

            // Use the provided account or the first cached one for this tenant
            let account: MSALAccount?
            if let id = accountID {
                account = accounts.first { $0.identifier == id }
            } else {
                account = accounts.first { $0.tenantProfiles?.contains { $0.tenantId == tenantID } == true }
                    ?? accounts.first
            }

            guard let account else {
                log.info("No cached account for tenant \(tenantID, privacy: .public) — not registered")
                return .notRegistered
            }

            let authority = try MSALAADAuthority(
                url: URL(string: "https://login.microsoftonline.com/\(tenantID)")!
            )
            let params = MSALSilentTokenParameters(scopes: ["openid", "profile"], account: account)
            params.authority = authority

            let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
                app.acquireTokenSilent(with: params) { result, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let result else {
                        continuation.resume(throwing: CSError.authResultNil); return
                    }
                    continuation.resume(returning: result)
                }
            }

            let resolvedTenantID = result.tenantProfile.tenantId ?? tenantID
            log.info("Silent broker token acquired — device workplace-joined for tenant \(resolvedTenantID, privacy: .public)")
            return .workplaceJoined(tenantID: resolvedTenantID, deviceID: nil)

        } catch {
            log.info("Device registration check: silent token failed (\(error.localizedDescription, privacy: .public)) — treating as not registered")
            return .notRegistered
        }
    }

    // MARK: - Token acquisition

    /// Acquires a token interactively, routing through the Company Portal broker
    /// when available. Falls back to an in-app WebView when not installed.
    ///
    /// On success updates `companyConfig` with the broker account ID and UPN.
    public func acquireTokenInteractive(
        clientID: String,
        tenantID: String,
        scopes: [String],
        loginHint: String?,
        presentingWindow: NSWindow
    ) async throws -> BrokerTokenResult {
        let app = try makeMSALApp(clientID: clientID, tenantID: tenantID)

        let webviewParams = await MainActor.run {
            let vc = presentingWindow.contentViewController ?? NSViewController()
            let p = MSALWebviewParameters(authPresentationViewController: vc)
            p.webviewType = .wkWebView
            return p
        }

        let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webviewParams)
        params.promptType = loginHint == nil ? .selectAccount : .default
        if let hint = loginHint { params.loginHint = hint }

        let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
            app.acquireToken(with: params) { result, error in
                if let error { continuation.resume(throwing: error); return }
                guard let result else {
                    continuation.resume(throwing: CSError.authResultNil); return
                }
                continuation.resume(returning: result)
            }
        }

        let usedBroker: Bool
        if case .installed = portalStatus() {
            // MSAL doesn't expose this directly; infer from token cache source
            usedBroker = result.account.identifier?.contains("live.com") == false
        } else {
            usedBroker = false
        }

        log.info("Token acquired for \(result.account.username ?? "?", privacy: .private) via \(usedBroker ? "broker" : "webview", privacy: .public)")

        return BrokerTokenResult(
            accessToken: result.accessToken,
            idToken: result.idToken,
            accountID: result.account.identifier ?? UUID().uuidString,
            tenantID: result.tenantProfile.tenantId ?? tenantID,
            upn: result.account.username ?? "",
            expiresOn: result.expiresOn ?? Date().addingTimeInterval(3600),
            usedBroker: usedBroker
        )
    }

    /// Attempts a silent token refresh using a stored MSAL account.
    /// Returns nil if the account is not found or the token cannot be refreshed silently.
    public func acquireTokenSilent(
        clientID: String,
        tenantID: String,
        scopes: [String],
        accountID: String
    ) async throws -> BrokerTokenResult? {
        let app = try makeMSALApp(clientID: clientID, tenantID: tenantID)
        let accounts = try app.allAccounts()
        guard let account = accounts.first(where: { $0.identifier == accountID }) else {
            return nil
        }

        let authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/\(tenantID)")!)
        let params = MSALSilentTokenParameters(scopes: scopes, account: account)
        params.authority = authority

        do {
            let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
                app.acquireTokenSilent(with: params) { result, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let result else {
                        continuation.resume(throwing: CSError.authResultNil); return
                    }
                    continuation.resume(returning: result)
                }
            }
            return BrokerTokenResult(
                accessToken: result.accessToken,
                idToken: result.idToken,
                accountID: result.account.identifier ?? accountID,
                tenantID: result.tenantProfile.tenantId ?? tenantID,
                upn: result.account.username ?? "",
                expiresOn: result.expiresOn ?? Date().addingTimeInterval(3600),
                usedBroker: false
            )
        } catch {
            log.warning("Silent token refresh failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Sign out

    public func signOut(clientID: String, tenantID: String, accountID: String) async throws {
        let app = try makeMSALApp(clientID: clientID, tenantID: tenantID)
        let accounts = try app.allAccounts()
        if let account = accounts.first(where: { $0.identifier == accountID }) {
            try app.remove(account)
            log.info("Signed out account \(accountID, privacy: .private)")
        }
    }

    // MARK: - Standard scopes for Tier 1

    public static let tier1Scopes: [String] = [
        "https://graph.microsoft.com/User.Read",
        "https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All",
        "offline_access",
        "openid",
        "profile",
    ]
}
