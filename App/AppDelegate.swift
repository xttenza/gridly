import AppKit
import CryptoKit
import os.log
import CSCore
import CSCrypto
import CSAuth
import CSWorkspace
import CSPolicy
import CSGraph
import CSAudit
import CSUI

private let log = Logger(subsystem: "com.gridly", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var container: AppContainer!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Demo mode: skip full container (no Entra ID or Keychain needed).
        // Also falls into demo mode automatically when Gridly-Config.plist
        // is absent — lets the app run locally without Entra credentials configured.
        if Configuration.loadFromBundle() == nil, !isDemoMode {
            log.info("No Gridly-Config.plist found — running in demo mode")
            isDemoMode = true  // flip the global so GridlyApp picks it up
        }
        guard !isDemoMode else {
            log.info("Demo mode — AppContainer skipped")
            return
        }
        // AppContainer.init is async (calls actor-isolated configure()).
        // We start in a .checkingAuth spinner; container will be ready before auth check completes.
        Task { @MainActor in
            do {
                self.container = try await AppContainer()
            } catch {
                log.fault("Failed to initialize AppContainer: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Failed to Start"
                alert.informativeText = "Gridly could not initialize: \(error.localizedDescription)"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        log.info("Gridly launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // Stay alive in background (agent handles workspace)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Lock workspace and unmount all profile volumes on quit — don't leave data exposed
        Task {
            await container.sessionManager.lock(reason: "app_quit")
            await container.profileManager.unmountAll()
        }
    }

    // MARK: - APNs

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        container.deviceRegistrationManager.handleAPNsToken(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.warning("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let commandType = userInfo["command"] as? String else { return }
        log.info("Remote notification received: \(commandType, privacy: .public)")

        Task {
            if let commands = try? await container.complianceEngine.pollRemoteCommands(),
               let upn = container.dashboardViewModel.session?.userPrincipalName {
                await container.remoteWipeHandler.processCommands(commands, accountID: upn)
            }
        }
    }
}

// MARK: - AppContainer (Dependency Injection Root)

@MainActor
public final class AppContainer {

    // Core infrastructure
    let keychainManager: KeychainManager
    let crypto: EncryptionKeyLifecycle
    let tamperDetector: TamperDetector
    let tokenManager: TokenManager

    // Auth
    let authProvider: EntraIDAuthProvider

    // Workspace
    let volumeManager: WorkspaceVolumeManager
    let sessionManager: WorkspaceSessionManager
    let profileManager: ProfileManager
    let clipboardGuard: ClipboardGuard
    let browserProfileManager: BrowserProfileManager

    // Policy
    let policyCache: PolicyCache
    let policyEnforcer: PolicyEnforcer
    let networkMonitor: NetworkMonitor

    // Audit
    let auditDB: AuditDatabase
    let auditLogger: AuditLogger

    // Graph
    let graphClient: GraphClient
    let complianceEngine: IntuneComplianceEngine
    let deviceRegistrationManager: DeviceRegistrationManager
    let remoteWipeHandler: RemoteWipeHandler

    // App layer
    let dashboardViewModel: DashboardViewModel

    public init() async throws {
        // ── Configuration ──────────────────────────────────────────────────────
        guard let config = Configuration.loadFromBundle() else {
            throw CSError.internalError("Missing Gridly-Config.plist in bundle")
        }

        // ── Crypto Layer ───────────────────────────────────────────────────────
        keychainManager = KeychainManager(
            service: "com.gridly.workspace"
            // accessGroup omitted — no provisioning profile required for local builds.
            // Add your Team ID prefix here if distributing to multiple Macs via notarization.
        )
        crypto = EncryptionKeyLifecycle()
        tamperDetector = TamperDetector(keychainManager: keychainManager)
        tokenManager = TokenManager(keychainManager: keychainManager, crypto: crypto)

        // ── Auth Layer ─────────────────────────────────────────────────────────
        let authConfig = EntraIDAuthProvider.Configuration(
            clientID: config.entraClientID,
            tenantID: config.entraTenantID
        )
        authProvider = EntraIDAuthProvider(config: authConfig, tokenManager: tokenManager)
        try await authProvider.configure()   // actor-isolated MSAL setup

        // ── Workspace Directories ──────────────────────────────────────────────
        // Use an explicit path so data lives at ~/Library/Application Support/Gridly/
        // regardless of sandbox state. This path is stable across app updates,
        // moves, and re-installations — it is never inside the .app bundle.
        let containerDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gridly", isDirectory: true)
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        // Write a version stamp so diagnostic tools and future migrations can
        // detect which app version last wrote this data directory.
        let versionStampURL = containerDir.appendingPathComponent(".gridly-version")
        let stamp = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        try? stamp.write(to: versionStampURL, atomically: true, encoding: .utf8)

        // ── Workspace Layer ────────────────────────────────────────────────────
        volumeManager = WorkspaceVolumeManager(containerDirectory: containerDir)
        networkMonitor = NetworkMonitor()

        // Policy cache uses a separate encryption key derived from the master key.
        // At startup, if we have no session, use a stub key; replaced on auth.
        let stubKey = SymmetricKey(size: .bits256)
        policyCache = try PolicyCache(
            databaseURL: containerDir.appending(path: "policy.db"),
            cacheKey: stubKey,
            crypto: crypto
        )
        policyEnforcer = PolicyEnforcer(cache: policyCache, networkMonitor: networkMonitor)

        // ── Audit Layer ────────────────────────────────────────────────────────
        let auditDBURL = containerDir.appending(path: "audit.db")
        auditDB = try AuditDatabase(url: auditDBURL)
        let auditKey = SymmetricKey(size: .bits256)  // Replaced with real key after auth
        auditLogger = AuditLogger(db: auditDB, signingKey: auditKey)

        // ── Profile Manager ────────────────────────────────────────────────────
        // Created after auditLogger so profile lifecycle events can be logged.
        profileManager = ProfileManager(
            baseDirectory: containerDir,
            crypto: crypto,
            keychainManager: keychainManager,
            auditLogger: auditLogger
        )

        // Clean up any stale profile keychain entries left in the search list
        // by a previous session that crashed or was force-quit while profiles
        // were mounted.  Prevents "Keychain Not Found" dialogs in other apps.
        WorkspaceProfileKeychain.cleanupStaleEntries()

        // ── Session Manager ────────────────────────────────────────────────────
        sessionManager = WorkspaceSessionManager(
            volumeManager: volumeManager,
            keychainManager: keychainManager,
            crypto: crypto,
            idleTimeoutSeconds: UserDefaults.standard.integer(forKey: "lockTimeoutMinutes") * 60
        )
        clipboardGuard = ClipboardGuard(
            policy: .strict,
            auditCallback: { [weak auditLogger] type, payload in
                guard let auditLogger else { return }
                Task { await auditLogger.log(eventType: type, sessionID: UUID(), payload: payload) }
            }
        )
        browserProfileManager = BrowserProfileManager(workspaceURL: containerDir)

        // ── Graph Layer ────────────────────────────────────────────────────────
        graphClient = GraphClient(
            tokenManager: tokenManager,
            accountID: ""  // Set on first auth
        )
        complianceEngine = IntuneComplianceEngine(
            graphClient: graphClient,
            cache: policyCache,
            networkMonitor: networkMonitor
        )
        deviceRegistrationManager = DeviceRegistrationManager(
            graphClient: graphClient,
            keychainManager: keychainManager
        )
        remoteWipeHandler = RemoteWipeHandler(
            keychainManager: keychainManager,
            volumeManager: volumeManager,
            graphClient: graphClient,
            auditCallback: { [weak auditLogger] type, payload in
                guard let auditLogger else { return }
                Task { await auditLogger.log(eventType: type, sessionID: UUID(), payload: payload) }
            },
            lockWorkspace: { [weak sessionManager] in
                await sessionManager?.lock(reason: "remote_command")
            }
        )

        // ── App Launcher ───────────────────────────────────────────────────────
        let appLauncher = AppLauncher(
            workspaceURL: containerDir,
            auditLogger: auditLogger,
            sessionID: UUID()
        )

        // ── Dashboard ViewModel ────────────────────────────────────────────────
        dashboardViewModel = DashboardViewModel(
            sessionManager: sessionManager,
            authProvider: authProvider,
            compliance: complianceEngine,
            enforcer: policyEnforcer,
            appLauncher: appLauncher,
            auditLogger: auditLogger,
            tamperDetector: tamperDetector,
            remoteWipe: remoteWipeHandler,
            profileManager: profileManager
        )
    }

    // MARK: - Post-auth Setup

    func onAuthenticated(session: WorkspaceSession) {
        // Wire profile unmount to workspace lock so all profile APFS volumes lock together
        sessionManager.onLock = { [weak profileManager] in
            await profileManager?.unmountAll()
        }

        clipboardGuard.startMonitoring()
        dashboardViewModel.startPolicyPolling()
        dashboardViewModel.refresh()
    }

    func unlock() async throws {
        guard let session = dashboardViewModel.session else { throw CSError.noAccountFound }
        try await sessionManager.unlock(currentSession: session)
    }
}

// MARK: - Configuration

struct Configuration {
    let entraClientID: String
    let entraTenantID: String
    let auditEndpointURL: String?

    static func loadFromBundle() -> Configuration? {
        guard let url = Bundle.main.url(forResource: "Gridly-Config", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        let clientID  = dict["EntraClientID"]  as? String ?? ""
        let tenantID  = dict["EntraTenantID"]  as? String ?? ""
        // Treat placeholder / empty values the same as missing config → demo mode
        guard !clientID.isEmpty,
              !clientID.hasPrefix("YOUR-"),
              !tenantID.isEmpty,
              !tenantID.hasPrefix("YOUR-") else { return nil }
        return Configuration(
            entraClientID: clientID,
            entraTenantID: tenantID,
            auditEndpointURL: dict["AuditEndpointURL"] as? String
        )
    }
}
