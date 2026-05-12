import Foundation
import Combine
import CryptoKit
import os.log
import CSCore
import CSCrypto
import CSAudit

private let log = Logger(subsystem: "com.gridly", category: "ProfileManager")

// MARK: - ProfileManager

/// Central coordinator for multiple WorkspaceProfile instances.
///
/// Responsibilities:
///  - Persist the profile registry to disk (JSON, inside the app's container).
///  - Own the lifecycle of each profile's APFS sparse bundle (create / mount / unmount / delete).
///  - Vend `IsolatedAppLauncher` instances bound to a mounted profile.
///  - Track which apps are currently running inside each profile.
///
/// ## Design rationale
/// Each profile is a separate APFS sparse bundle on the main disk, encrypted with AES-256
/// using a passphrase-derived key. When mounted, it appears as `/Volumes/CS-<shortID>/`.
/// The home directory at `/Volumes/CS-<shortID>/home/` becomes the synthetic HOME for
/// any app launched inside that profile via IsolatedAppLauncher.
@MainActor
public final class ProfileManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var profiles: [WorkspaceProfile] = []

    /// Which profiles currently have their APFS volume mounted.
    @Published public private(set) var mountStates: [UUID: ProfileMountState] = [:]

    // MARK: - Dependencies

    private let baseDirectory: URL          // ~/Library/Application Support/Gridly/
    private let crypto: EncryptionKeyLifecycle
    private let keychainManager: KeychainManager

    /// Optional audit logger — nil only in demo / unit-test mode.
    private let auditLogger: AuditLogger?

    /// Optional session manager — when set, mounting a company profile automatically
    /// creates a WorkspaceSession from the profile's companyConfig so the dashboard
    /// session card shows real data instead of staying empty.
    public weak var sessionManager: WorkspaceSessionManager?

    /// Per-profile volume managers, instantiated on first use.
    private var volumeManagers: [UUID: WorkspaceVolumeManager] = [:]

    // MARK: - Persistence

    private var registryURL: URL {
        baseDirectory.appendingPathComponent("Profiles/registry.json")
    }

    // MARK: - Init

    public init(
        baseDirectory: URL,
        crypto: EncryptionKeyLifecycle,
        keychainManager: KeychainManager,
        auditLogger: AuditLogger? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.crypto = crypto
        self.keychainManager = keychainManager
        self.auditLogger = auditLogger
        loadRegistry()
        reconcileMountStates()
    }

    // MARK: - Profile Registry

    /// Persist the profile list to the registry file.
    private func saveRegistry() {
        do {
            let data = try JSONEncoder().encode(profiles)
            let dir = registryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            log.error("Failed to save profile registry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let loaded = try? JSONDecoder().decode([WorkspaceProfile].self, from: data)
        else {
            log.info("No profile registry found — starting fresh")
            return
        }
        profiles = loaded
        log.info("Loaded \(loaded.count) profiles from registry")
    }

    /// Check which profiles are already mounted (e.g. after app restart).
    private func reconcileMountStates() {
        for profile in profiles {
            if profile.isMounted {
                mountStates[profile.id] = ProfileMountState(isMounted: true)
                log.info("Profile '\(profile.name, privacy: .public)' already mounted at startup")
            }
        }
    }

    // MARK: - Demo / Testing Helpers

    /// Injects pre-built profiles without creating real APFS volumes.
    /// Call this in demo mode to populate the UI with representative data.
    /// Saves to the registry so subsequent launches restore the same profiles.
    public func injectDemoProfiles(_ demoProfiles: [WorkspaceProfile], mountedIDs: Set<UUID> = []) {
        profiles = demoProfiles
        for profile in demoProfiles {
            let isMounted = mountedIDs.contains(profile.id)
            mountStates[profile.id] = ProfileMountState(isMounted: isMounted)
        }
        saveRegistry()
    }

    // MARK: - Profile CRUD

    /// Creates a new profile: registers it, creates the APFS sparse bundle, sets up home skeleton.
    @discardableResult
    public func createProfile(
        name: String,
        accountIdentifier: String = "",
        color: WorkspaceProfile.ProfileColor,
        passphrase: String,
        sizeGB: Int = 10
    ) async throws -> WorkspaceProfile {
        var profile = WorkspaceProfile(
            name: name,
            accountIdentifier: accountIdentifier,
            color: color
        )

        let bundleURL = profile.bundleURL(base: baseDirectory)

        // Create sparse bundle directory
        let bundleDir = bundleURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // Create APFS encrypted sparse bundle via hdiutil
        let vm = volumeManager(for: profile)
        try await vm.create(passphrase: passphrase, sizeGB: sizeGB)

        // Mount it to set up the home skeleton
        _ = try await vm.mount(passphrase: passphrase)
        try WorkspaceHomeDirectory.ensureStructure(at: profile.homeURL)
        try WorkspaceHomeDirectory.ensureTmpDirectory(at: profile.tmpURL)

        // Create per-profile Keychain database inside the encrypted volume.
        // This is the key to MSAL/Keychain isolation: by creating a separate keychain
        // and activating it (see mount()), MSAL stores tokens here instead of in
        // login.keychain-db.  The file lives on the APFS volume so it's encrypted at
        // rest and physically inaccessible when the profile is locked.
        WorkspaceProfileKeychain.createIfNeeded(for: profile, passphrase: passphrase)
        WorkspaceProfileKeychain.activate(for: profile, passphrase: passphrase)

        // Save to registry
        profiles.append(profile)
        saveRegistry()
        mountStates[profile.id] = ProfileMountState(isMounted: true)

        log.info("Created profile '\(profile.name, privacy: .public)' id=\(profile.id, privacy: .public)")
        audit(.profileCreated, profile: profile, extra: ["sizeGB": "\(sizeGB)"])
        return profile
    }

    /// Permanently deletes a profile: unmounts volume, removes the sparse bundle and registry entry.
    public func deleteProfile(_ profile: WorkspaceProfile) async throws {
        try? await unmount(profile)
        let bundleURL = profile.bundleURL(base: baseDirectory)
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            try FileManager.default.removeItem(at: bundleURL)
        }
        // Remove the profile directory
        let profileDir = bundleURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: profileDir)

        profiles.removeAll { $0.id == profile.id }
        mountStates.removeValue(forKey: profile.id)
        volumeManagers.removeValue(forKey: profile.id)
        saveRegistry()
        log.info("Deleted profile '\(profile.name, privacy: .public)'")
        audit(.profileDeleted, profile: profile)
    }

    /// Updates a profile's mutable fields (name, accountIdentifier, color).
    public func updateProfile(_ profile: WorkspaceProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            saveRegistry()
        }
    }

    // MARK: - Volume Lifecycle

    /// Mounts the profile's APFS volume using the provided passphrase.
    public func mount(_ profile: WorkspaceProfile, passphrase: String) async throws {
        guard !profile.isMounted else {
            mountStates[profile.id] = ProfileMountState(isMounted: true)
            return
        }
        let vm = volumeManager(for: profile)
        _ = try await vm.mount(passphrase: passphrase)

        // Touch the home skeleton in case new dirs were added since creation
        try WorkspaceHomeDirectory.ensureStructure(at: profile.homeURL)
        try WorkspaceHomeDirectory.ensureTmpDirectory(at: profile.tmpURL)

        // Update last-accessed timestamp
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx].lastAccessedAt = Date()
            saveRegistry()
        }

        // Activate the profile's keychain: promotes it to the front of the Keychain
        // search list and makes it the default for new items.  MSAL will now store
        // tokens for apps launched in this profile in the profile's keychain, not
        // in login.keychain-db.  Achieves true per-profile MSAL token isolation.
        WorkspaceProfileKeychain.createIfNeeded(for: profile, passphrase: passphrase)
        WorkspaceProfileKeychain.activate(for: profile, passphrase: passphrase)

        mountStates[profile.id] = ProfileMountState(isMounted: true)
        log.info("Mounted profile '\(profile.name, privacy: .public)'")
        audit(.profileMounted, profile: profile)

        // Populate the dashboard session card from the profile's company config.
        // This replaces any stale/demo session with real identity data so the
        // "User", "Tenant", "Token exp." fields reflect the actual signed-in account.
        if let config = profile.companyConfig, config.isAuthenticated {
            let accountID = profile.accountIdentifier.isEmpty ? nil : profile.accountIdentifier
            let upn = config.userPrincipalName ?? accountID ?? config.tenantDomain
            let expiresAt = config.lastBrokerAuthAt?.addingTimeInterval(3600)
                ?? Date().addingTimeInterval(3600)
            let realSession = WorkspaceSession(
                userPrincipalName: upn,
                displayName: upn,
                tenantID: config.tenantID,
                accessTokenExpiresAt: expiresAt,
                isAuthenticated: true,
                complianceStatus: .unknown
            )
            sessionManager?.session = realSession
            log.info("Session populated from company config for '\(profile.name, privacy: .public)'")
        } else if sessionManager?.session?.userPrincipalName.contains("contoso") == true {
            // Clear any leftover demo session so the card shows "No active session"
            sessionManager?.session = nil
        }

        // Silently refresh the SSO broker session if this is a company profile.
        // Non-blocking: runs in background so mount doesn't wait on network.
        if let companyConfig = profile.companyConfig, companyConfig.isAuthenticated {
            Task {
                let mgr = CompanyProfileManager()
                let ok = await mgr.refreshSilently(config: companyConfig)
                if ok {
                    log.info("Silent SSO refresh succeeded for '\(profile.name, privacy: .public)'")
                } else {
                    log.warning("Silent SSO refresh failed for '\(profile.name, privacy: .public)' — interactive re-auth may be needed")
                }
            }
        }
    }

    /// Unmounts the profile's APFS volume, locking all data on disk.
    public func unmount(_ profile: WorkspaceProfile) async throws {
        guard profile.isMounted else {
            mountStates[profile.id] = ProfileMountState(isMounted: false)
            return
        }
        let vm = volumeManager(for: profile)

        // Deactivate profile keychain BEFORE unmounting so we can still access
        // the search list to clean it up while the volume is still readable.
        WorkspaceProfileKeychain.deactivate(for: profile)

        try await vm.unmount()
        mountStates[profile.id] = ProfileMountState(isMounted: false)
        log.info("Unmounted profile '\(profile.name, privacy: .public)'")
        audit(.profileUnmounted, profile: profile)

        // Clear session if it belonged to this profile
        if let upn = profile.companyConfig?.userPrincipalName ?? (profile.accountIdentifier.isEmpty ? nil : profile.accountIdentifier),
           sessionManager?.session?.userPrincipalName == upn {
            sessionManager?.session = nil
        }
    }

    /// Unmounts all currently mounted profiles (e.g. on app quit or remote wipe).
    public func unmountAll() async {
        for profile in profiles where profile.isMounted {
            try? await unmount(profile)
        }
    }

    public func isMounted(_ profile: WorkspaceProfile) -> Bool {
        mountStates[profile.id]?.isMounted ?? profile.isMounted
    }

    // MARK: - App Launching

    /// Returns an IsolatedAppLauncher bound to the given profile.
    /// Throws if the profile is not mounted.
    public func launcher(for profile: WorkspaceProfile) throws -> IsolatedAppLauncher {
        guard isMounted(profile) else {
            throw IsolatedLaunchError.profileNotMounted(profile.name)
        }
        return IsolatedAppLauncher(profile: profile)
    }

    /// Convenience: launch a single app inside a profile.
    public func launchApp(_ app: ManagedApp, in profile: WorkspaceProfile) throws {
        let launcher = try launcher(for: profile)
        try launcher.launch(app)

        // Track running app and log it
        var state = mountStates[profile.id] ?? ProfileMountState(isMounted: true)
        state.runningAppBundleIDs.insert(app.bundleID)
        mountStates[profile.id] = state
        audit(.profileAppLaunched, profile: profile,
              extra: ["bundleID": app.bundleID, "appName": app.displayName])
    }

    /// Returns all managed apps with their install/running status for a given profile.
    public func appStatuses(for profile: WorkspaceProfile) -> [ProfileAppStatus] {
        let launcher = try? launcher(for: profile)
        let runningIDs = mountStates[profile.id]?.runningAppBundleIDs ?? []
        return ManagedApp.defaultApps.map { app in
            ProfileAppStatus(
                app: app,
                isInstalled: launcher?.isInstalled(app) ?? false,
                isRunning: runningIDs.contains(app.bundleID)
            )
        }
    }

    // MARK: - Audit Helpers

    private func audit(
        _ eventType: AuditEventType,
        profile: WorkspaceProfile,
        extra: [String: String] = [:]
    ) {
        guard let auditLogger else { return }
        var payload: [String: String] = [
            "profileID":   profile.id.uuidString,
            "profileName": profile.name,
        ]
        payload.merge(extra) { _, new in new }
        Task {
            await auditLogger.log(eventType: eventType,
                                  sessionID: UUID(),
                                  payload: payload)
        }
    }

    // MARK: - Private Helpers

    private func volumeManager(for profile: WorkspaceProfile) -> WorkspaceVolumeManager {
        if let vm = volumeManagers[profile.id] { return vm }
        let bundleDir = profile.bundleURL(base: baseDirectory).deletingLastPathComponent()
        let vm = WorkspaceVolumeManager(
            containerDirectory: bundleDir,
            volumeName: profile.mountVolumeName
        )
        volumeManagers[profile.id] = vm
        return vm
    }
}

// MARK: - ProfileAppStatus

public struct ProfileAppStatus: Identifiable {
    public var id: String { app.bundleID }
    public let app: ManagedApp
    public let isInstalled: Bool
    public let isRunning: Bool
}
