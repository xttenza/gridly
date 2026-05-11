import Foundation
import MSAL
import CSCore
import CSCrypto

/// Wraps MSAL to provide Entra ID authentication with broker support (Company Portal)
/// and Conditional Access compatibility.
public actor EntraIDAuthProvider {

    public struct Configuration: Sendable {
        public let clientID: String
        public let tenantID: String
        public let redirectURI: String
        public let scopes: [String]

        public init(
            clientID: String,
            tenantID: String,
            redirectURI: String? = nil,
            additionalScopes: [String] = []
        ) {
            self.clientID = clientID
            self.tenantID = tenantID
            self.redirectURI = redirectURI ?? "msauth.\(Bundle.main.bundleIdentifier ?? "com.gridly.app")://auth"
            self.scopes = [
                "https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All",
                "https://graph.microsoft.com/DeviceManagementConfiguration.Read.All",
                "https://graph.microsoft.com/User.Read",
                "offline_access",
                "openid",
                "profile"
            ] + additionalScopes
        }
    }

    private let config: Configuration
    private let tokenManager: TokenManager
    private var msalApp: MSALPublicClientApplication?

    public init(config: Configuration, tokenManager: TokenManager) {
        self.config = config
        self.tokenManager = tokenManager
    }

    // MARK: - Setup

    public func configure() throws {
        let authorityURL = URL(string: "https://login.microsoftonline.com/\(config.tenantID)")!
        let authority = try MSALAADAuthority(url: authorityURL)

        let msalConfig = MSALPublicClientApplicationConfig(
            clientId: config.clientID,
            redirectUri: config.redirectURI,
            authority: authority
        )
        // Enable broker globally: allows SSO with other Microsoft apps and Conditional Access signals
        MSALGlobalConfig.brokerAvailability = .auto

        self.msalApp = try MSALPublicClientApplication(configuration: msalConfig)
    }

    // MARK: - Interactive Authentication

    public func acquireTokenInteractive(presentingWindow: NSWindow) async throws -> WorkspaceSession {
        guard let app = msalApp else { throw CSError.authNotConfigured }

        // MSALWebviewParameters requires AppKit objects; construct on the main actor
        let webviewParams = await MainActor.run {
            let vc = presentingWindow.contentViewController ?? NSViewController()
            let p = MSALWebviewParameters(authPresentationViewController: vc)
            p.webviewType = .wkWebView
            return p
        }

        let params = MSALInteractiveTokenParameters(scopes: config.scopes, webviewParameters: webviewParams)
        params.promptType = .selectAccount

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
            app.acquireToken(with: params) { result, error in
                if let error { continuation.resume(throwing: error); return }
                guard let result else { continuation.resume(throwing: CSError.authResultNil); return }
                continuation.resume(returning: result)
            }
        }

        return try await buildSession(from: result)
    }

    // MARK: - Silent Token Acquisition

    public func acquireTokenSilent(accountID: String? = nil) async throws -> WorkspaceSession {
        guard let app = msalApp else { throw CSError.authNotConfigured }

        let accounts = try app.allAccounts()
        guard let account = accountID.flatMap({ id in accounts.first(where: { $0.identifier == id }) })
                         ?? accounts.first else {
            throw CSError.noAccountFound
        }

        let authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/\(config.tenantID)")!)
        let params = MSALSilentTokenParameters(scopes: config.scopes, account: account)
        params.authority = authority
        params.forceRefresh = false

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
            app.acquireTokenSilent(with: params) { result, error in
                if let error { continuation.resume(throwing: error); return }
                guard let result else { continuation.resume(throwing: CSError.authResultNil); return }
                continuation.resume(returning: result)
            }
        }

        return try await buildSession(from: result)
    }

    // MARK: - Sign Out

    public func signOut(accountID: String) throws {
        guard let app = msalApp else { return }
        let accounts = try app.allAccounts()
        guard let account = accounts.first(where: { $0.identifier == accountID }) else { return }
        try app.remove(account)
    }

    public func currentAccounts() throws -> [MSALAccount] {
        guard let app = msalApp else { return [] }
        return try app.allAccounts()
    }

    // MARK: - Private

    private func buildSession(from result: MSALResult) async throws -> WorkspaceSession {
        let accountID = result.account.identifier ?? UUID().uuidString
        let claims = await tokenManager.extractClaims(from: result.idToken ?? "")
        let expiresOn = result.expiresOn ?? Date().addingTimeInterval(3600)

        try await tokenManager.storeTokens(
            accessToken: result.accessToken,
            idToken: result.idToken ?? "",
            expiresOn: expiresOn,
            accountID: accountID
        )

        return WorkspaceSession(
            userPrincipalName: result.account.username ?? "",
            displayName: claims["name"] as? String ?? result.account.username ?? "User",
            tenantID: result.tenantProfile.tenantId ?? config.tenantID,
            accessTokenExpiresAt: expiresOn,
            isAuthenticated: true,
            complianceStatus: .checking,
            deviceID: nil
        )
    }
}
