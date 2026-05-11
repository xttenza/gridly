import Foundation
import SwiftUI

// MARK: - WorkspaceProfile

/// A named, isolated workspace context — analogous to a Samsung Knox profile or Android Work Profile.
///
/// Each profile owns:
///  • A dedicated APFS sparse bundle (AES-256 encrypted) that acts as its storage volume.
///  • A synthetic HOME directory inside that volume, so every app that runs inside the profile
///    stores its data, preferences, caches, and MSAL token caches there — not in the real `~`.
///  • An optional per-profile Keychain database (.keychain-db) also stored on the volume.
///
/// Two profiles can therefore run the same managed app (e.g. Microsoft Teams) simultaneously
/// with completely separate accounts, sessions, and data — no cross-contamination.
public struct WorkspaceProfile: Identifiable, Codable, Sendable, Hashable {

    public let id: UUID
    public var name: String
    public var accountIdentifier: String   // UPN: jane@contoso.com, or empty before sign-in
    public var color: ProfileColor
    public let createdAt: Date
    public var lastAccessedAt: Date?

    /// When non-nil this profile is connected to a Microsoft company/work identity.
    /// See `CompanyProfileConfig` for details on what the company can and cannot access.
    public var companyConfig: CompanyProfileConfig?

    public init(
        id: UUID = UUID(),
        name: String,
        accountIdentifier: String = "",
        color: ProfileColor = .blue,
        createdAt: Date = Date(),
        lastAccessedAt: Date? = nil,
        companyConfig: CompanyProfileConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.accountIdentifier = accountIdentifier
        self.color = color
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.companyConfig = companyConfig
    }

    /// Whether this profile is connected to a Microsoft company tenant.
    public var isCompanyProfile: Bool { companyConfig != nil }

    /// Whether broker SSO is configured and authenticated for this profile.
    public var isSSOReady: Bool { companyConfig?.isAuthenticated == true }

    // MARK: - Derived Identifiers

    /// Short 8-char prefix used in volume/file names so paths stay readable.
    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    /// The hdiutil volume name — appears as /Volumes/<mountVolumeName>.
    public var mountVolumeName: String { "CS-\(shortID)" }

    // MARK: - Path Resolution

    /// Root of the profile's sparse bundle directory inside the app's container.
    public func bundleURL(base: URL) -> URL {
        base.appendingPathComponent("Profiles/\(id.uuidString)/workspace.sparsebundle")
    }

    /// Mount point: /Volumes/CS-<shortID>
    public var mountURL: URL {
        URL(fileURLWithPath: "/Volumes/\(mountVolumeName)")
    }

    /// Synthetic HOME directory — every managed app launched in this profile
    /// sees this as its HOME, so `~/Library/Application Support/` etc. go here.
    public var homeURL: URL {
        mountURL.appendingPathComponent("home")
    }

    /// Dedicated temp dir (avoids leaking temp files through the shared /tmp).
    public var tmpURL: URL {
        mountURL.appendingPathComponent("tmp")
    }

    /// Per-profile Keychain database stored inside the encrypted volume.
    public var keychainURL: URL {
        homeURL.appendingPathComponent("Library/Keychains/profile.keychain-db")
    }

    /// Whether the profile's volume is currently mounted.
    public var isMounted: Bool {
        FileManager.default.fileExists(atPath: mountURL.path)
    }

    // MARK: - Environment Variables

    /// Full set of env-var overrides injected into every app launched in this profile.
    /// `open --env` (macOS 12+) applies these to the launched process, so
    /// `NSHomeDirectory()`, `FileManager.homeDirectoryForCurrentUser`, and
    /// Electron's `app.getPath('home')` all resolve to the profile volume.
    public var processEnvironment: [String: String] {
        [
            "HOME":           homeURL.path,
            "TMPDIR":         tmpURL.path,
            "USERPROFILE":    homeURL.path,          // Some apps use this on macOS
            "XDG_DATA_HOME":  homeURL.appendingPathComponent("Library/Application Support").path,
            "XDG_CONFIG_HOME":homeURL.appendingPathComponent("Library/Preferences").path,
            "XDG_CACHE_HOME": homeURL.appendingPathComponent("Library/Caches").path,
        ]
    }
}

// MARK: - ProfileColor

public extension WorkspaceProfile {

    /// Visual accent colour for a profile card in the UI.
    enum ProfileColor: String, Codable, CaseIterable, Sendable {
        case blue, indigo, purple, pink, red, orange, yellow, green, teal, cyan

        public var swiftUIColor: Color {
            switch self {
            case .blue:   return .blue
            case .indigo: return .indigo
            case .purple: return .purple
            case .pink:   return .pink
            case .red:    return .red
            case .orange: return .orange
            case .yellow: return .yellow
            case .green:  return .green
            case .teal:   return .teal
            case .cyan:   return .cyan
            }
        }

        public var displayName: String { rawValue.capitalized }

        /// Next colour in the cycle — used to auto-assign to new profiles.
        public static func next(after existing: [WorkspaceProfile]) -> ProfileColor {
            let used = Set(existing.map(\.color))
            return allCases.first { !used.contains($0) } ?? .blue
        }
    }
}

// MARK: - ProfileMountState

/// Observable mount + running-app state for a profile; vended by ProfileManager.
public struct ProfileMountState: Sendable {
    public var isMounted: Bool
    public var runningAppBundleIDs: Set<String>

    public init(isMounted: Bool = false, runningAppBundleIDs: Set<String> = []) {
        self.isMounted = isMounted
        self.runningAppBundleIDs = runningAppBundleIDs
    }
}
