import Foundation
import SwiftUI
import Combine
import CryptoKit
import CSCore
import CSCrypto
import CSAuth
import CSWorkspace
import CSPolicy
import CSGraph
import CSAudit

@MainActor
public final class DashboardViewModel: ObservableObject {

    // MARK: - Published State
    @Published public var session: WorkspaceSession?
    @Published public var managedApps: [ManagedApp] = ManagedApp.defaultApps
    @Published public var complianceState: ComplianceState = .unknown
    @Published public var complianceReport: ComplianceReport?
    @Published public var isLocked: Bool = true
    @Published public var lockCountdownSeconds: Int = 0
    @Published public var vpnActive: Bool = false
    @Published public var isSyncing: Bool = false
    @Published public var tamperCheckPassed: Bool = true
    @Published public var auditIntegrityClean: Bool = true
    @Published public var selectedTab: Tab = .dashboard
    @Published public var showComplianceAlert: Bool = false
    @Published public var alertMessage: String = ""
    @Published public var isEnrolling: Bool = false

    // MARK: - Dependencies
    private let sessionManager: WorkspaceSessionManager
    private let authProvider: EntraIDAuthProvider
    private let compliance: IntuneComplianceEngine
    private let enforcer: PolicyEnforcer
    private let appLauncher: AppLauncher
    public let auditLogger: AuditLogger
    private let tamperDetector: TamperDetector
    private let remoteWipe: RemoteWipeHandler

    /// Multi-profile manager — nil in legacy/demo mode (single-workspace path).
    public private(set) var profileManager: ProfileManager?

    private var cancellables = Set<AnyCancellable>()
    private var policyPollingTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        sessionManager: WorkspaceSessionManager,
        authProvider: EntraIDAuthProvider,
        compliance: IntuneComplianceEngine,
        enforcer: PolicyEnforcer,
        appLauncher: AppLauncher,
        auditLogger: AuditLogger,
        tamperDetector: TamperDetector,
        remoteWipe: RemoteWipeHandler,
        profileManager: ProfileManager? = nil
    ) {
        self.sessionManager  = sessionManager
        self.authProvider    = authProvider
        self.compliance      = compliance
        self.enforcer        = enforcer
        self.appLauncher     = appLauncher
        self.auditLogger     = auditLogger
        self.tamperDetector  = tamperDetector
        self.remoteWipe      = remoteWipe
        self.profileManager  = profileManager

        bindSessionManager()
    }

    // MARK: - Session Binding

    private func bindSessionManager() {
        sessionManager.$isLocked
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLocked)

        sessionManager.$lockCountdownSeconds
            .receive(on: DispatchQueue.main)
            .assign(to: &$lockCountdownSeconds)

        sessionManager.$session
            .receive(on: DispatchQueue.main)
            .assign(to: &$session)

        // Re-run compliance check whenever a new session is available so
        // the status bar shows the correct state immediately after sign-in.
        sessionManager.$session
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }        // only non-nil sessions
            .sink { [weak self] _ in
                Task { await self?.checkCompliance() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    public func refresh() {
        managedApps = appLauncher.checkInstallStatuses(for: managedApps)
        Task { await checkTamperIntegrity() }
        Task { await checkCompliance() }
    }

    public func launch(_ app: ManagedApp) {
        Task {
            do {
                try await appLauncher.launch(app, vpnActive: vpnActive)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    public func lockWorkspace() {
        Task { await sessionManager.lock(reason: "user_request") }
    }

    public func extendSession() {
        sessionManager.recordActivity()
    }

    public func syncPolicy() {
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            defer { isSyncing = false }
            _ = try? await enforcer.syncPolicy()
            await checkCompliance()
        }
    }

    // MARK: - Compliance

    private func checkCompliance() async {
        guard let upn = session?.userPrincipalName else { return }
        do {
            let report = try await compliance.checkCompliance(userPrincipalName: upn)
            complianceReport  = report
            complianceState   = report.complianceState
            if report.complianceState.blocksWorkspace {
                showComplianceAlert = true
            }
        } catch {
            complianceState = .error
        }
    }

    // MARK: - Tamper Detection

    private func checkTamperIntegrity() async {
        let status = tamperDetector.checkSystemIntegrity()
        tamperCheckPassed = status.isSecure

        if let clean = try? await auditLogger.verifyIntegrity() {
            auditIntegrityClean = clean.isClean
        }

        if !tamperCheckPassed {
            await auditLogger.log(eventType: .tamperDetected,
                                  sessionID: session?.id ?? UUID(),
                                  payload: ["summary": tamperDetector.checkSystemIntegrity().summary])
        }
    }

    // MARK: - Policy Polling

    public func startPolicyPolling(intervalSeconds: Int = 3600) {
        policyPollingTask?.cancel()
        policyPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                syncPolicy()

                // Poll for remote commands (wipe, lock, policy update)
                if let commands = try? await compliance.pollRemoteCommands(),
                   let upn = session?.userPrincipalName {
                    await remoteWipe.processCommands(commands, accountID: upn)
                }
            }
        }
    }

    public func stopPolicyPolling() {
        policyPollingTask?.cancel()
        policyPollingTask = nil
    }

    // MARK: - Demo / Preview Factory

    /// Creates a fully-populated view model with mock data — no Entra ID or Keychain needed.
    /// Launch the app with `--demo` to activate this path.
    @MainActor
    public static func demo() -> DashboardViewModel {
        // Minimal stub dependencies — nothing hits network or Keychain
        let crypto = EncryptionKeyLifecycle()
        let km = KeychainManager(service: "com.cs.demo")
        let td = TamperDetector(keychainManager: km)

        let containerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-demo-\(UUID().uuidString)")
        // Must create directory before GRDB tries to open database files inside it
        try? FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        let volumeManager = WorkspaceVolumeManager(containerDirectory: containerDir)

        let networkMonitor = NetworkMonitor()
        let stubKey = SymmetricKey(size: .bits256)
        let policyCache = try! PolicyCache(
            databaseURL: containerDir.appendingPathComponent("policy.db"),
            cacheKey: stubKey,
            crypto: crypto
        )
        let policyEnforcer = PolicyEnforcer(cache: policyCache, networkMonitor: networkMonitor)

        let auditDB = try! AuditDatabase(url: containerDir.appendingPathComponent("audit.db"))
        let auditLogger = AuditLogger(db: auditDB, signingKey: stubKey)

        let demoSession = WorkspaceSession(
            userPrincipalName: "jane.doe@contoso.com",
            displayName: "Jane Doe",
            tenantID: "contoso.onmicrosoft.com",
            accessTokenExpiresAt: Date().addingTimeInterval(3600),
            isAuthenticated: true,
            complianceStatus: .compliant
        )
        let sessionManager = WorkspaceSessionManager(
            volumeManager: volumeManager,
            keychainManager: km,
            crypto: crypto,
            idleTimeoutSeconds: 900,
            initialLocked: false   // demo starts unlocked; Combine delivers false into VM
        )
        // Seed the demo session before binding so the Combine publisher carries it into the VM
        sessionManager.session = demoSession

        let tokenManager = TokenManager(keychainManager: km, crypto: crypto)
        let authCfg = EntraIDAuthProvider.Configuration(
            clientID: "demo-client-id",
            tenantID: "demo-tenant-id"
        )
        let authProvider = EntraIDAuthProvider(config: authCfg, tokenManager: tokenManager)

        let appLauncher = AppLauncher(
            workspaceURL: containerDir,
            auditLogger: auditLogger,
            sessionID: UUID()
        )

        // Stub Graph client that always returns demo compliance data
        let graphClient = DemoGraphClient()
        let compliance = IntuneComplianceEngine(
            graphClient: graphClient,
            cache: policyCache,
            networkMonitor: networkMonitor
        )
        // Pre-register a demo device ID so fetchComplianceReport returns .compliant
        // (without this, deviceID is nil and the engine falls back to .unknown)
        Task { await compliance.setDeviceID("demo-device-id") }
        let remoteWipe = RemoteWipeHandler(
            keychainManager: km,
            volumeManager: volumeManager,
            graphClient: graphClient,
            auditCallback: { _, _ in },
            lockWorkspace: {}
        )

        let profileManager = ProfileManager(
            baseDirectory: containerDir,
            crypto: crypto,
            keychainManager: km
        )

        // Pre-populate with representative demo profiles (no real APFS volumes)
        let workProfileID = UUID()
        let clientProfileID = UUID()
        profileManager.injectDemoProfiles([
            WorkspaceProfile(
                id: workProfileID,
                name: "Contoso Work",
                accountIdentifier: "jane.doe@contoso.com",
                color: .blue
            ),
            WorkspaceProfile(
                id: clientProfileID,
                name: "Client — Fabrikam",
                accountIdentifier: "jane@fabrikam.com",
                color: .purple
            ),
            WorkspaceProfile(
                id: UUID(),
                name: "Dev / Staging",
                accountIdentifier: "",
                color: .orange
            ),
        ], mountedIDs: [workProfileID])

        let vm = DashboardViewModel(
            sessionManager: sessionManager,
            authProvider: authProvider,
            compliance: compliance,
            enforcer: policyEnforcer,
            appLauncher: appLauncher,
            auditLogger: auditLogger,
            tamperDetector: td,
            remoteWipe: remoteWipe,
            profileManager: profileManager
        )

        // Pre-populate published state (session comes via Combine from sessionManager above)
        vm.selectedTab        = .profiles   // Open on Profiles tab in demo
        vm.complianceState    = .compliant
        vm.tamperCheckPassed  = true
        vm.auditIntegrityClean = true
        vm.vpnActive          = false
        vm.isLocked           = false
        vm.managedApps        = ManagedApp.defaultApps

        return vm
    }
}

// MARK: - Demo Graph Client (no network calls)

private final class DemoGraphClient: GraphClientProtocol, @unchecked Sendable {
    func registerDevice(payload: DeviceRegistrationPayload) async throws -> String { "demo-device-id" }

    func fetchComplianceReport(deviceID: String) async throws -> ComplianceReport {
        ComplianceReport(
            deviceID: deviceID,
            complianceState: .compliant,
            lastSyncDateTime: Date(),
            noncompliantReasons: [],
            nextCheckDateTime: Date().addingTimeInterval(3600)
        )
    }

    func fetchAppProtectionPolicies() async throws -> [AppProtectionPolicy] { [] }
    func fetchRemoteCommands(deviceID: String) async throws -> [RemoteCommand] { [] }
}
