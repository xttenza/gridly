import Foundation
import CryptoKit
import os.log
import CSCore
import CSCrypto
import CSWorkspace
import CSPolicy
import CSAudit

private let log = Logger(subsystem: "com.gridly.agent", category: "AgentMain")

// MARK: - Entry Point

// GridlyAgent runs as a persistent LaunchAgent.
// It owns: workspace volume lifecycle, clipboard guard, policy polling,
//          DLP FSEvents monitoring, and remote wipe command processing.

final class AgentApplication {

    private let keychainManager: KeychainManager
    private let crypto: EncryptionKeyLifecycle
    private let tamperDetector: TamperDetector
    private let volumeManager: WorkspaceVolumeManager
    private let clipboardGuard: ClipboardGuard
    private let policyEnforcer: PolicyEnforcer
    private let auditLogger: AuditLogger
    private let xpcListener: NSXPCListener
    private let handler: AgentXPCHandler

    init() throws {
        log.info("GridlyAgent starting…")

        let containerDir = URL.applicationSupportDirectory
            .appending(path: "Gridly", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        keychainManager = KeychainManager(
            service: "com.gridly.workspace",
            accessGroup: "YOUR_TEAM_ID.com.gridly.shared"
        )
        crypto = EncryptionKeyLifecycle()
        tamperDetector = TamperDetector(keychainManager: keychainManager)
        volumeManager  = WorkspaceVolumeManager(containerDirectory: containerDir)

        // Stub audit key until main app passes the real one via XPC
        let auditKey = SymmetricKey(size: .bits256)
        let auditDB  = try AuditDatabase(url: containerDir.appending(path: "audit.db"))
        auditLogger  = AuditLogger(db: auditDB, signingKey: auditKey)

        let stubKey = SymmetricKey(size: .bits256)
        let cache   = try PolicyCache(
            databaseURL: containerDir.appending(path: "policy.db"),
            cacheKey: stubKey,
            crypto: crypto
        )
        let netMonitor = NetworkMonitor()
        policyEnforcer = PolicyEnforcer(cache: cache, networkMonitor: netMonitor)

        clipboardGuard = ClipboardGuard(
            policy: .strict,
            auditCallback: { [weak auditLogger] type, payload in
                guard let al = auditLogger else { return }
                Task { await al.log(eventType: type, sessionID: UUID(), payload: payload) }
            }
        )

        handler = AgentXPCHandler(
            volumeManager: volumeManager,
            policyEnforcer: policyEnforcer,
            auditLogger: auditLogger,
            keychainManager: keychainManager
        )

        // Mach service listener — registered in launchd plist
        xpcListener = NSXPCListener(machServiceName: AgentMachServiceName)
        let listenerDelegate = AgentXPCListener(handler: handler, tamperDetector: tamperDetector)
        xpcListener.delegate = listenerDelegate
    }

    func run() {
        log.info("Agent run loop starting")

        // Startup checks
        verifyIntegrity()
        clipboardGuard.startMonitoring()
        xpcListener.resume()

        // RunLoop keeps agent alive
        RunLoop.main.run()
    }

    private func verifyIntegrity() {
        let ok = (try? tamperDetector.verifyIntegrity()) ?? false
        if !ok {
            log.fault("Integrity check FAILED — possible tampering detected")
            Task {
                await auditLogger.log(eventType: .tamperDetected,
                                      sessionID: UUID(),
                                      payload: ["component": "agent_binary"])
            }
        }
    }
}

// MARK: - XPC Handler

final class AgentXPCHandler: NSObject, AgentXPCProtocol {

    private let volumeManager: WorkspaceVolumeManager
    private let policyEnforcer: PolicyEnforcer
    private let auditLogger: AuditLogger
    private let keychainManager: KeychainManager

    init(
        volumeManager: WorkspaceVolumeManager,
        policyEnforcer: PolicyEnforcer,
        auditLogger: AuditLogger,
        keychainManager: KeychainManager
    ) {
        self.volumeManager  = volumeManager
        self.policyEnforcer = policyEnforcer
        self.auditLogger    = auditLogger
        self.keychainManager = keychainManager
    }

    func lockWorkspace(reply: @escaping (Bool) -> Void) {
        Task {
            await volumeManager.lock()
            reply(true)
        }
    }

    func workspaceIsLocked(reply: @escaping (Bool) -> Void) {
        Task { reply(await !volumeManager.isMounted) }
    }

    func mountWorkspace(passphraseData: Data, reply: @escaping (Bool, String) -> Void) {
        Task {
            guard let passphrase = String(data: passphraseData, encoding: .utf8) else {
                reply(false, "Invalid passphrase encoding")
                return
            }
            do {
                _ = try await volumeManager.mount(passphrase: passphrase)
                reply(true, "")
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func unmountWorkspace(reply: @escaping (Bool) -> Void) {
        Task {
            try? await volumeManager.unmount()
            reply(true)
        }
    }

    func syncPolicy(reply: @escaping (Bool, String) -> Void) {
        Task {
            do {
                let manifest = try await policyEnforcer.syncPolicy()
                reply(true, manifest.version)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func currentComplianceState(reply: @escaping (String) -> Void) {
        Task {
            let policy = await policyEnforcer.currentPolicy()
            reply(policy != nil ? "loaded" : "none")
        }
    }

    func logEvent(typeRawValue: String, payloadJSON: String, reply: @escaping (Bool) -> Void) {
        guard let eventType = AuditEventType(rawValue: typeRawValue) else {
            reply(false); return
        }
        Task {
            let payload = (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: String]) ?? [:]
            await auditLogger.log(eventType: eventType, sessionID: UUID(), payload: payload)
            reply(true)
        }
    }

    func executeWipe(commandJSON: String, accountID: String, reply: @escaping (Bool, String) -> Void) {
        // Wipe commands are validated in RemoteWipeHandler — Agent just orchestrates
        guard let data = commandJSON.data(using: .utf8),
              let command = try? JSONDecoder().decode(RemoteCommand.self, from: data) else {
            reply(false, "Invalid command JSON")
            return
        }
        Task {
            do {
                try keychainManager.destroyWorkspaceDEK(accountID: accountID)
                try keychainManager.deleteAllWorkspaceItems()
                try? await volumeManager.unmount()
                reply(true, "")
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}

// MARK: - Entry Point

enum AgentEntryPoint {
    static func run() {
        do {
            let app = try AgentApplication()
            app.run()
        } catch {
            Logger(subsystem: "com.gridly.agent", category: "AgentMain")
                .fault("Fatal agent startup error: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }
}
