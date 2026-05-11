import Foundation
import os.log

private let log = Logger(subsystem: "com.gridly", category: "HomeDirectory")

// MARK: - WorkspaceHomeDirectory

/// Creates and maintains the synthetic HOME directory structure inside a profile volume.
///
/// When a managed app launches with `HOME` pointing here, macOS APIs resolve:
///   `NSHomeDirectory()`                    → <homeURL>/
///   `~/Library/Application Support/`      → <homeURL>/Library/Application Support/
///   `~/Library/Preferences/`              → <homeURL>/Library/Preferences/
///   etc.
///
/// This gives every managed app a completely private data tree inside the encrypted volume,
/// independent of — and invisible to — the real user home and other profiles.
public enum WorkspaceHomeDirectory {

    // macOS home skeleton — mirrors what the system creates for a real user.
    private static let requiredDirectories: [String] = [
        // Core Library dirs that apps write to unconditionally
        "Library/Application Support",
        "Library/Preferences",
        "Library/Caches",
        "Library/Logs",
        "Library/Cookies",
        "Library/Saved Application State",
        "Library/Application Scripts",
        "Library/Keychains",
        "Library/WebKit",

        // Microsoft-specific dirs (Teams, Outlook, Office)
        "Library/Application Support/Microsoft",
        "Library/Application Support/com.microsoft.adalcache",  // MSAL token cache
        "Library/Application Support/MicrosoftEdge",

        // Electron / Chromium generic
        "Library/Application Support/Chromium",
        "Library/Application Support/Google/Chrome",

        // Slack
        "Library/Application Support/Slack",

        // Standard user dirs
        "Documents",
        "Desktop",
        "Downloads",
        "Pictures",
        "Movies",
        "Music",
        "Public",
    ]

    /// Idempotently creates the full directory skeleton at `homeURL`.
    /// Call before launching any managed app into the profile.
    public static func ensureStructure(at homeURL: URL) throws {
        let fm = FileManager.default
        for relative in requiredDirectories {
            let url = homeURL.appendingPathComponent(relative)
            guard !fm.fileExists(atPath: url.path) else { continue }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            log.debug("Created home dir: \(relative, privacy: .public)")
        }
    }

    /// Creates the tmp directory alongside the home directory.
    public static func ensureTmpDirectory(at tmpURL: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: tmpURL.path) {
            try fm.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        }
    }

    /// Returns a `UserDefaults` instance scoped to the profile's preference domain.
    /// Apps that use `UserDefaults.standard` will NOT use this — it only helps
    /// our own code store per-profile settings.
    public static func userDefaults(at homeURL: URL, suiteName: String) -> UserDefaults? {
        let prefsURL = homeURL
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(suiteName).plist")
        return UserDefaults(suiteName: prefsURL.path)
    }

    /// Approximate storage used by this profile's home dir (in bytes).
    public static func storageUsed(at homeURL: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: homeURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.compactMap { item -> Int64? in
            guard let url = item as? URL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return nil }
            return Int64(size)
        }.reduce(0, +)
    }
}
