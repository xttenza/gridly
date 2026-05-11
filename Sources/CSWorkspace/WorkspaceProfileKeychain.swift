import Foundation
import Security
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "ProfileKeychain")

// MARK: - WorkspaceProfileKeychain

/// Manages per-profile macOS Keychain databases stored inside the profile's APFS volume.
///
/// ## Why this is needed
///
/// `open --env HOME=...` remaps the HOME env var, which Electron / Node.js apps respect.
/// However, macOS native frameworks — including MSAL (Microsoft Authentication Library) —
/// use `NSHomeDirectory()` which reads from the **directory services** (passwd database),
/// not from the HOME env var.  This means MSAL always stores and retrieves tokens from
/// the REAL user's system Keychain, causing Teams and Outlook to auto-sign in with the
/// user's existing account regardless of the profile they are launched in.
///
/// The fix: each profile owns a separate `.keychain-db` file **inside** its encrypted
/// APFS volume.  On mount, this keychain is added to the front of the user's Keychain
/// search list and set as the default keychain for new items.  MSAL therefore:
///  • Reads: finds the profile's tokens (not the main user's) → correct account
///  • Writes: stores new tokens in the profile keychain → encrypted at rest on the volume
///
/// On unmount the profile keychain is removed from the search list, making those tokens
/// physically inaccessible (the APFS volume is locked).
public enum WorkspaceProfileKeychain {

    // MARK: - Keychain File Path

    /// Filename used for the per-profile keychain inside the profile's home directory.
    static let keychainFilename = "cs-profile.keychain-db"

    /// Path of the profile's keychain file.
    public static func keychainURL(for profile: WorkspaceProfile) -> URL {
        profile.homeURL
            .appendingPathComponent("Library/Keychains/\(keychainFilename)")
    }

    // MARK: - Lifecycle

    /// Creates the per-profile keychain file inside the profile's (mounted) volume.
    /// Safe to call multiple times — skips creation if the file already exists.
    public static func createIfNeeded(for profile: WorkspaceProfile, passphrase: String) {
        let url = keychainURL(for: profile)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            log.debug("Profile keychain already exists for '\(profile.name, privacy: .public)'")
            return
        }

        // Ensure the Keychains directory exists
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        runSecurity(args: ["create-keychain", "-p", passphrase, url.path],
                    description: "create keychain for '\(profile.name)'")

        // Remove the keychain from the list that `create-keychain` automatically adds
        // (we manage the list ourselves on mount/unmount)
        removeFromSearchList(url: url)

        log.info("Created profile keychain for '\(profile.name, privacy: .public)'")
    }

    /// Called when the profile's APFS volume is **mounted**.
    ///
    /// Unlocks the profile keychain and promotes it to the front of the user's
    /// Keychain search list, setting it as the default for new Keychain items.
    /// Subsequent MSAL reads will find this profile's tokens first; writes will
    /// land here rather than in `login.keychain-db`.
    public static func activate(for profile: WorkspaceProfile, passphrase: String) {
        let url = keychainURL(for: profile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.warning("No keychain file found for '\(profile.name, privacy: .public)' — isolation incomplete")
            return
        }

        // Unlock it (it may be auto-locked on APFS mount)
        runSecurity(args: ["unlock-keychain", "-p", passphrase, url.path],
                    description: "unlock keychain for '\(profile.name)'")

        // CRITICAL: Disable auto-lock so the keychain stays unlocked for the
        // entire profile session.  Without this, the default 300-second inactivity
        // timer fires and the keychain relocks.  When ANY system daemon
        // (iCloudHelper, Mail, Safari, etc.) then searches the keychain list and
        // hits a locked "cs-profile" keychain, macOS shows a password prompt.
        // Entering the correct password doesn't "do" anything useful for those
        // daemons — they're just scanning for their own items — so the prompt
        // appears broken.  Keeping the keychain unlocked = no prompt, they scan
        // silently and find nothing.
        //
        // "set-keychain-settings" with NO flags disables both lock-on-sleep and
        // lock-on-timeout.  The physical file is protected by the encrypted APFS
        // volume: when the volume unmounts, the file becomes inaccessible anyway.
        runSecurity(args: ["set-keychain-settings", url.path],
                    description: "disable auto-lock for '\(profile.name)'")

        // Grant all applications access to the keychain without per-app prompts.
        // This is equivalent to what login.keychain-db does — apps don't get
        // prompted to access it, they just search and find (or don't find) items.
        allowAllApplicationsAccess(keychainPath: url.path, passphrase: passphrase)

        // Build new search list: profile keychain first, then existing entries
        let existing = currentSearchList().filter { $0 != url.path }
        let newList  = [url.path] + existing
        setSearchList(newList)

        // Make it the default so new Keychain items (MSAL tokens) land here
        setDefaultKeychain(url: url)

        log.info("Activated profile keychain for '\(profile.name, privacy: .public)'")
    }

    /// Called when the profile's APFS volume is **unmounted**.
    ///
    /// Locks and removes the profile keychain from the search list, then restores
    /// `login.keychain-db` as the default.  After this call any system daemon
    /// that scans the search list will no longer encounter the profile keychain.
    public static func deactivate(for profile: WorkspaceProfile) {
        let url = keychainURL(for: profile)

        // Lock the keychain before removing it from the list so in-flight
        // Security API calls from other processes fail fast rather than hanging.
        runSecurity(args: ["lock-keychain", url.path],
                    description: "lock keychain for '\(profile.name)'")

        removeFromSearchList(url: url)
        restoreLoginKeychainAsDefault()

        log.info("Deactivated profile keychain for '\(profile.name, privacy: .public)'")
    }

    // MARK: - Startup Cleanup

    /// Call this once at app launch to remove any stale profile keychain entries
    /// left in the search list by a previous session that terminated unexpectedly
    /// (e.g. force-quit, crash, or OS reboot while a profile was mounted).
    /// Stale entries point to keychains on unmounted APFS volumes, which causes
    /// "Keychain Not Found" dialogs whenever apps try to store credentials.
    public static func cleanupStaleEntries() {
        let current = currentSearchList()
        let valid = current.filter { path in
            // Keep system keychains and entries that actually exist on disk
            path.contains("/Library/Keychains/login.keychain") ||
            path.contains("/Library/Keychains/System.keychain") ||
            FileManager.default.fileExists(atPath: path)
        }
        guard valid.count != current.count else { return }

        log.info("Removing \(current.count - valid.count) stale keychain entries from search list")
        setSearchList(valid)

        // If the default keychain is now stale, restore login.keychain-db
        let defaultKC = runSecurityCapturing(args: ["default-keychain", "-d", "user"])
            .trimmingCharacters(in: .init(charactersIn: " \"\n\t"))
        if !FileManager.default.fileExists(atPath: defaultKC) {
            restoreLoginKeychainAsDefault()
        }
    }

    // MARK: - ACL helpers

    /// Grants all applications access to the keychain without requiring individual
    /// per-app password prompts.
    ///
    /// When a keychain is created fresh, its default ACL prompts any application
    /// that isn't explicitly on the trusted list (this is what causes the
    /// iCloudHelper / Safari / Mail dialogs).  Setting an access object with an
    /// **empty trusted-application list** tells macOS "any app may use this
    /// keychain without prompting" — exactly how `login.keychain-db` behaves.
    ///
    /// The keychain's encryption is unchanged; this only affects the UI-level
    /// confirmation gate, not the cryptographic protection of the stored data.
    private static func allowAllApplicationsAccess(keychainPath: String, passphrase: String) {
        var keychain: SecKeychain?
        guard SecKeychainOpen(keychainPath, &keychain) == errSecSuccess,
              let kc = keychain else {
            log.warning("Could not open keychain at \(keychainPath, privacy: .public) to set ACL")
            return
        }

        // Make sure it is unlocked before we touch it
        let pwd = passphrase
        SecKeychainUnlock(kc, UInt32(pwd.utf8.count), pwd, true)

        // Disable auto-lock settings via the Security framework as well
        // (belt-and-suspenders alongside the CLI call above)
        var settings = SecKeychainSettings(
            version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
            lockOnSleep: false,
            useLockInterval: false,
            lockInterval: UInt32(INT_MAX)
        )
        SecKeychainSetSettings(kc, &settings)

        // Create an access object with an empty trusted-app list.
        // Empty array (not nil) = "trust all applications without prompting".
        // nil = "always confirm" — the opposite of what we want.
        let emptyArray = [] as CFArray
        var access: SecAccess?
        guard SecAccessCreate(
            "Gridly Profile Keychain" as CFString,
            emptyArray,
            &access
        ) == errSecSuccess, let acc = access else {
            log.warning("Could not create permissive access object for keychain")
            return
        }

        // Apply the access object to every ACL entry in the keychain.
        // We enumerate the ACL list and replace each entry's trusted-app
        // list with the empty (= any app) list.
        var aclList: CFArray?
        guard SecAccessCopyACLList(acc, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return }

        for acl in acls {
            var appList: CFArray?
            var desc: CFString?
            var mask: SecKeychainPromptSelector = []
            guard SecACLCopyContents(acl, &appList, &desc, &mask) == errSecSuccess else { continue }

            // Replace the trusted-app list with empty (= allow all) and clear
            // the "confirm access" prompt flag
            SecACLSetContents(
                acl,
                emptyArray,                    // empty = trust everyone
                (desc ?? "" as CFString),
                []                             // no prompt selector flags
            )
        }

        log.info("Set permissive ACL on profile keychain at \(keychainPath, privacy: .public)")
    }

    // MARK: - Search-List Helpers

    private static func currentSearchList() -> [String] {
        let result = runSecurityCapturing(args: ["list-keychains", "-d", "user"])
        return result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .init(charactersIn: " \"\t")) }
            .filter { !$0.isEmpty }
    }

    private static func setSearchList(_ paths: [String]) {
        var args = ["list-keychains", "-d", "user", "-s"]
        args += paths
        runSecurity(args: args, description: "set keychain search list")
    }

    private static func removeFromSearchList(url: URL) {
        let current = currentSearchList().filter { $0 != url.path }
        guard !current.isEmpty else { return }
        setSearchList(current)
    }

    private static func setDefaultKeychain(url: URL) {
        runSecurity(args: ["default-keychain", "-d", "user", "-s", url.path],
                    description: "set default keychain")
    }

    private static func restoreLoginKeychainAsDefault() {
        // Find the user's login keychain from the current search list
        let loginKeychain = currentSearchList().first {
            $0.hasSuffix("login.keychain-db") || $0.hasSuffix("login.keychain")
        } ?? "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"

        runSecurity(args: ["default-keychain", "-d", "user", "-s", loginKeychain],
                    description: "restore login.keychain-db as default")
    }

    // MARK: - Process Helpers

    @discardableResult
    private static func runSecurity(args: [String], description: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let status = process.terminationStatus
            if status != 0 {
                log.warning("security \(description, privacy: .public) exited \(status)")
            }
            return status
        } catch {
            log.error("Failed to run security for \(description, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return -1
        }
    }

    private static func runSecurityCapturing(args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
