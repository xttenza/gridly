import Foundation
import AppKit
import Combine
import os.log
import CSCore
import CSCrypto

private let log = Logger(subsystem: "com.gridly", category: "SessionManager")

/// Central coordinator for a workspace session: mount → unlock → idle timer → lock.
public final class WorkspaceSessionManager: @unchecked Sendable {

    // MARK: - Published State

    @Published public var session: WorkspaceSession?
    @Published public private(set) var isLocked: Bool = true
    @Published public private(set) var lockCountdownSeconds: Int = 0

    public var mountURL: URL? {
        get async { await volumeManager.mountURL }
    }

    // MARK: - Dependencies

    private let volumeManager: WorkspaceVolumeManager
    private let keychainManager: KeychainManager
    private let crypto: EncryptionKeyLifecycle
    private let idleTimeoutSeconds: Int

    private var idleTimer: Timer?
    private var countdownTimer: Timer?
    private var lastActivityDate = Date()

    /// Called whenever `lock()` fires (user-initiated, idle timeout, or remote command).
    /// Use this to unmount all profile volumes so they are locked alongside the main workspace.
    public var onLock: (() async -> Void)?

    private static let countdownWarningSeconds = 60

    public init(
        volumeManager: WorkspaceVolumeManager,
        keychainManager: KeychainManager,
        crypto: EncryptionKeyLifecycle,
        idleTimeoutSeconds: Int = 900,
        initialLocked: Bool = true
    ) {
        self.volumeManager = volumeManager
        self.keychainManager = keychainManager
        self.crypto = crypto
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.isLocked = initialLocked

        setupActivityMonitoring()
    }

    // MARK: - Unlock

    public func unlock(currentSession: WorkspaceSession) async throws {
        let masterKey = try keychainManager.retrieveWorkspaceDEK(accountID: currentSession.userPrincipalName)
        let passphrase = crypto.deriveVolumePassphrase(masterKey: masterKey)

        _ = try await volumeManager.mount(passphrase: passphrase)

        await MainActor.run {
            self.session = currentSession
            self.isLocked = false
            self.lastActivityDate = Date()
        }

        startIdleTimer()
        log.info("Workspace unlocked for \(currentSession.userPrincipalName, privacy: .private)")
    }

    // MARK: - Lock

    public func lock(reason: String = "manual") async {
        stopTimers()
        // Unmount main workspace volume
        try? await volumeManager.unmount()
        // Unmount all profile volumes (Knox-style: locking workspace locks all profiles)
        await onLock?()

        await MainActor.run {
            self.isLocked = true
            self.lockCountdownSeconds = 0
        }
        log.info("Workspace locked: \(reason, privacy: .public)")
    }

    // MARK: - Activity Tracking

    public func recordActivity() {
        lastActivityDate = Date()
        // Reset countdown if it was showing
        if lockCountdownSeconds > 0 {
            Task { @MainActor in
                self.lockCountdownSeconds = 0
            }
        }
    }

    // MARK: - Idle Timer

    private func startIdleTimer() {
        stopTimers()

        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
        RunLoop.main.add(idleTimer!, forMode: .common)
    }

    private func checkIdle() {
        let idleSeconds = Int(Date().timeIntervalSince(lastActivityDate))
        let remaining = idleTimeoutSeconds - idleSeconds

        if remaining <= 0 {
            log.info("Idle timeout reached — locking workspace")
            Task { await self.lock(reason: "idle_timeout") }
        } else if remaining <= Self.countdownWarningSeconds {
            DispatchQueue.main.async {
                self.lockCountdownSeconds = remaining
            }
        }
    }

    private func stopTimers() {
        idleTimer?.invalidate(); idleTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil
    }

    // MARK: - System Activity Monitoring

    private func setupActivityMonitoring() {
        // Monitor screen lock / sleep to immediately lock workspace
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.lock(reason: "screen_sleep") }
        }
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.lock(reason: "session_resign") }
        }
    }
}
