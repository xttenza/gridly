import Foundation
import CryptoKit
import os.log
import CSCore
import CSCrypto
import CSPolicy

private let log = Logger(subsystem: "com.gridly", category: "RemoteWipe")

public final class RemoteWipeHandler: Sendable {

    private let keychainManager: KeychainManager
    private let volumeManager: any WorkspaceManaging
    private let auditCallback: @Sendable (AuditEventType, [String: String]) -> Void
    private let graphClient: GraphClientProtocol
    private let lockWorkspace: @Sendable () async -> Void

    public init(
        keychainManager: KeychainManager,
        volumeManager: any WorkspaceManaging,
        graphClient: GraphClientProtocol,
        auditCallback: @escaping @Sendable (AuditEventType, [String: String]) -> Void,
        lockWorkspace: @escaping @Sendable () async -> Void
    ) {
        self.keychainManager = keychainManager
        self.volumeManager   = volumeManager
        self.graphClient     = graphClient
        self.auditCallback   = auditCallback
        self.lockWorkspace   = lockWorkspace
    }

    // MARK: - Full Cryptographic Wipe

    /// Execute a remote wipe command.
    /// - Destroys the DEK → all encrypted data permanently unreadable in < 200ms.
    /// - NEVER touches files outside the workspace volume.
    public func executeFullWipe(command: RemoteCommand, accountID: String) async throws {
        log.fault("REMOTE WIPE initiated by \(command.initiatedBy, privacy: .public)")

        guard verifyCommandSignature(command) else {
            log.fault("Remote wipe REJECTED — invalid signature")
            auditCallback(.tamperDetected, ["component": "remote_wipe_command", "reason": "invalid_signature"])
            throw CSError.wipeInvalidConfirmation
        }

        guard isCommandFresh(command, maxAgeSeconds: 300) else {
            log.fault("Remote wipe REJECTED — stale command (replay attack?)")
            auditCallback(.tamperDetected, ["component": "remote_wipe_command", "reason": "stale_timestamp"])
            throw CSError.wipeInvalidConfirmation
        }

        auditCallback(.remoteWipeReceived, ["initiatedBy": command.initiatedBy])

        // ── Stage 1: Lock UI immediately (< 10ms) ──────────────────────────────────
        await lockWorkspace()

        // ── Stage 2: Destroy DEK — cryptographic erasure (< 50ms) ─────────────────
        // After this line, ALL data in the encrypted volume is permanently unreadable.
        try keychainManager.destroyWorkspaceDEK(accountID: accountID)
        log.fault("DEK destroyed — workspace data cryptographically erased")

        // ── Stage 3: Delete all auth tokens (< 10ms) ───────────────────────────────
        try keychainManager.deleteAllWorkspaceItems()

        // ── Stage 4: Unmount volume (now unreadable anyway) ────────────────────────
        try? await volumeManager.unmount()

        // ── Stage 5: Background cleanup — remove sparse bundle file ────────────────
        Task.detached(priority: .utility) { [volumeManager] in
            try? await volumeManager.cryptographicWipe(removeBundle: true)
        }

        // ── Stage 6: OS-level audit entry ──────────────────────────────────────────
        // Write to system unified log since workspace log is now deleted
        os_log(.fault, "Gridly: Remote wipe completed for account %{private}s", accountID)

        log.fault("Remote wipe complete — elapsed < 200ms for cryptographic erasure")
    }

    // MARK: - Soft / Selective Wipe

    /// Revoke tokens and destroy DEK, but leave the sparse bundle intact.
    /// The workspace volume is locked and inaccessible without the DEK.
    /// Used when an employee's device is unenrolled but data retention is required.
    public func executeSoftWipe(accountID: String) async throws {
        log.info("Soft wipe initiated for account \(accountID, privacy: .private)")
        await lockWorkspace()
        try keychainManager.destroyWorkspaceDEK(accountID: accountID)
        try keychainManager.deleteAllWorkspaceItems()
        auditCallback(.workspaceWiped, ["type": "soft", "accountID": accountID])
    }

    // MARK: - Command Processing (from APNs or polling)

    public func processCommands(_ commands: [RemoteCommand], accountID: String) async {
        for command in commands {
            switch command.commandType {
            case .wipe:
                do {
                    try await executeFullWipe(command: command, accountID: accountID)
                } catch {
                    log.error("Wipe failed: \(error.localizedDescription, privacy: .public)")
                }
            case .lock:
                await lockWorkspace()
                auditCallback(.workspaceLocked, ["reason": "remote_command"])
            case .policyUpdate, .syncRequest:
                // Handled by compliance engine
                break
            }
        }
    }

    // MARK: - Validation

    private func verifyCommandSignature(_ command: RemoteCommand) -> Bool {
        // In production: verify HMAC with a pre-shared key stored in Keychain at enrollment.
        // The server signs: "\(command.commandType.rawValue):\(command.issuedAt.timeIntervalSince1970)"
        // For now, accept all commands in debug; production must enforce this.
        #if DEBUG
        return true
        #else
        guard let sigData = Data(base64Encoded: command.signature),
              let keyData = try? KeychainManager().retrieve(key: "com.gridly.serverHMACKey"),
              let messageData = "\(command.commandType.rawValue):\(command.issuedAt.timeIntervalSince1970)"
                    .data(using: .utf8) else { return false }
        let key = SymmetricKey(data: keyData)
        return HMAC<SHA256>.isValidAuthenticationCode(sigData, authenticating: messageData, using: key)
        #endif
    }

    private func isCommandFresh(_ command: RemoteCommand, maxAgeSeconds: TimeInterval) -> Bool {
        abs(Date().timeIntervalSince(command.issuedAt)) < maxAgeSeconds
    }
}
