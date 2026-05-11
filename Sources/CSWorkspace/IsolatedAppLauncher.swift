import Foundation
import AppKit
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "IsolatedLauncher")

// MARK: - IsolatedAppLauncher

/// Launches managed apps inside a WorkspaceProfile's isolated HOME environment.
///
/// ## Isolation layers (from broadest to narrowest)
///
/// ### Layer 1 — macOS Keychain (MSAL token isolation)
/// The MOST important layer for Microsoft apps.  `ProfileManager.mount()` calls
/// `WorkspaceProfileKeychain.activate()` which promotes the profile's keychain to the
/// front of the user's Keychain search list and makes it the default for new items.
/// MSAL (used by Teams, Outlook, etc.) reads tokens from the front of the search list
/// and writes new tokens to the default keychain.  A new profile has an empty keychain →
/// MSAL finds no token → Teams shows the sign-in page → user authenticates with a
/// different account → tokens are written to the profile keychain → subsequent launches
/// auto-sign in with that profile's account.  On unmount, the profile keychain is removed
/// from the search list (and is physically inaccessible on the locked APFS volume).
///
/// ### Layer 2 — Chromium/Electron user data directory
/// `--user-data-dir=<profile path>` gives Electron-based apps (Slack, old Teams, VSCode,
/// Edge, Chrome) a dedicated directory for cookies, localStorage, IndexedDB, and the
/// Chromium credential store.  This is independent of HOME and works even for apps that
/// don't fully respect the HOME env var.
///
/// ### Layer 3 — HOME env var
/// `open -n -a <App.app> --env HOME=<profileHome> ...` (macOS 12+) overrides HOME in
/// the child process.  This IS respected by:
///   • Node.js / Electron (`os.homedir()` reads `process.env.HOME`)
///   • Shell processes and Unix tools
///   • Python `os.path.expanduser("~")`
/// It is NOT respected by:
///   • `NSHomeDirectory()` — reads from directory services (passwd), not env var
///   • macOS native frameworks using `NSUserDomainMask`
///   • Sandboxed app containers (`~/Library/Containers/<bundleID>/`)
/// For native macOS apps (including new Teams 2.x), Keychain isolation (Layer 1)
/// is the effective isolation mechanism.
public final class IsolatedAppLauncher {

    public let profile: WorkspaceProfile

    public init(profile: WorkspaceProfile) {
        self.profile = profile
    }

    // MARK: - Launch

    /// Launches `app` isolated inside this profile.
    ///
    /// - Sandboxed/WebView2 apps (new Teams): opened in an isolated Chrome/Edge window
    ///   (`--app=<url> --user-data-dir=<profile path>`) — the only mechanism that
    ///   actually provides session isolation for sandboxed macOS apps.
    /// - Electron apps (Slack, old Teams, VSCode): launched via `open -n --env HOME=...
    ///   --args --user-data-dir=...` giving three independent isolation layers.
    public func launch(_ app: ManagedApp) throws {
        guard profile.isMounted else {
            throw IsolatedLaunchError.profileNotMounted(profile.name)
        }

        // Ensure the home skeleton exists before the app first touches it
        try WorkspaceHomeDirectory.ensureStructure(at: profile.homeURL)
        try WorkspaceHomeDirectory.ensureTmpDirectory(at: profile.tmpURL)

        let config = Self.launchConfig(bundleID: app.bundleID, profile: profile)

        switch config {
        case .browserApp(let browserBundleIDs, let url, let extraArgs):
            try launchInBrowser(app: app, browserBundleIDs: browserBundleIDs,
                                url: url, extraArgs: extraArgs)

        case .electronWithUserDataDir, .homeRedirect:
            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: app.bundleID
            ) else {
                throw IsolatedLaunchError.appNotInstalled(app.bundleID)
            }
            let process = makeOpenProcess(appURL: appURL, config: config)
            try process.run()
        }

        log.info("Launched \(app.displayName, privacy: .public) in profile '\(self.profile.name, privacy: .public)'")
    }

    // MARK: - Bundle ID Check

    public func isInstalled(_ app: ManagedApp) -> Bool {
        let config = Self.launchConfig(bundleID: app.bundleID, profile: profile)
        switch config {
        case .browserApp(let browserBundleIDs, _, _):
            return browserBundleIDs.contains { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            }
        case .electronWithUserDataDir, .homeRedirect:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
        }
    }

    // MARK: - Isolation Quality

    public static func isolationDescription(for bundleID: String) -> (label: String, detail: String, symbol: String) {
        let sentinel = WorkspaceProfile(id: UUID(), name: "", color: .blue)
        switch launchConfig(bundleID: bundleID, profile: sentinel) {
        case .browserApp:
            return ("Browser",
                    "Opens in an isolated browser window. Each profile gets a completely separate session — sign in with a different account.",
                    "globe.badge.chevron.backward")
        case .electronWithUserDataDir:
            return ("Full",
                    "Separate Keychain, HOME directory, and Chromium user data — three independent isolation layers.",
                    "checkmark.shield.fill")
        case .homeRedirect:
            return ("HOME",
                    "Data stored in this profile's encrypted HOME directory with per-profile Keychain isolation.",
                    "folder.badge.person.crop")
        }
    }

    // MARK: - Private: Browser Launch

    /// Launches a sandboxed/non-Electron app inside an isolated Chrome or Edge window.
    /// This is the ONLY mechanism that provides true session isolation for apps like
    /// new Teams 2.x that are sandboxed and ignore `HOME` env var overrides.
    private func launchInBrowser(app: ManagedApp, browserBundleIDs: [String],
                                 url: String, extraArgs: [String]) throws {
        // Find the first available browser
        guard let browserURL = browserBundleIDs.lazy.compactMap({
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }).first else {
            throw IsolatedLaunchError.noBrowserInstalled(app.displayName)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        // Browser must NOT be sandboxed itself — Chrome/Edge manage their own sandboxing
        // and respect --user-data-dir regardless, providing full session isolation.
        var args: [String] = ["-n", "-a", browserURL.path, "--args"]
        args += extraArgs + ["--app=\(url)", "--no-first-run"]

        process.arguments = args
        log.info("Browser launch: \(args.joined(separator: " "), privacy: .public)")
        try process.run()
    }

    // MARK: - Private: Native / Electron Launch

    private func makeOpenProcess(appURL: URL, config: AppLaunchConfig) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        var args: [String] = ["-n", "-a", appURL.path]

        // Inject profile environment (Electron / Node.js reads HOME from env)
        for (key, value) in profile.processEnvironment {
            args += ["--env", "\(key)=\(value)"]
        }

        let appArgs = config.extraArgs
        if !appArgs.isEmpty {
            args += ["--args"] + appArgs
        }

        process.arguments = args
        log.debug("open args: \(args.joined(separator: " "), privacy: .public)")
        return process
    }

    // MARK: - App-Specific Launch Configuration

    enum AppLaunchConfig {
        /// Open in an isolated browser window (Chrome/Edge). Used for sandboxed apps
        /// like Teams 2.x where HOME env var and --user-data-dir have no effect.
        /// `browserBundleIDs`: ordered list of browsers to try (first found wins).
        /// `url`: the web URL to open as a standalone app window.
        /// `extraArgs`: additional flags (--user-data-dir, --profile-directory, etc.).
        case browserApp(browserBundleIDs: [String], url: String, extraArgs: [String])

        /// Electron/Chromium: HOME env + --user-data-dir gives three-layer isolation.
        case electronWithUserDataDir([String])

        /// HOME env var remapping is sufficient.
        case homeRedirect

        var extraArgs: [String] {
            switch self {
            case .browserApp(_, _, let args):    return args
            case .electronWithUserDataDir(let a): return a
            case .homeRedirect:                   return []
            }
        }
    }

    static func launchConfig(bundleID: String, profile: WorkspaceProfile) -> AppLaunchConfig {
        let support = profile.homeURL.appendingPathComponent("Library/Application Support")

        // Browser precedence: Edge first (same M365 ecosystem), then Chrome
        let m365Browsers = ["com.microsoft.edgemac", "com.google.Chrome"]

        switch bundleID {

        // ── Microsoft Teams 2.x (sandboxed, WebView2-based) ──────────────────
        // TESTED: Teams is sandboxed (com.apple.security.app-sandbox) and uses
        // MSWebView2.framework, not Electron. HOME env var is completely ignored
        // by the OS sandbox. --user-data-dir is not accepted. The ONLY working
        // isolation is opening Teams WEB in an isolated Chrome/Edge profile.
        // Verified: Chrome with --app=https://teams.microsoft.com/v2/ +
        // --user-data-dir=<profile path> shows a fresh sign-in page with zero
        // session leakage from the user's main account.
        case "com.microsoft.teams2":
            return .browserApp(
                browserBundleIDs: m365Browsers,
                url: "https://teams.microsoft.com/v2/",
                extraArgs: [
                    "--user-data-dir=\(support.appendingPathComponent("Teams-Browser").path)",
                    "--profile-directory=Default",
                ]
            )

        // ── Microsoft Teams legacy (Electron < 2.0) ──────────────────────────
        case "com.microsoft.teams":
            return .electronWithUserDataDir([
                "--user-data-dir=\(support.appendingPathComponent("Microsoft/Teams").path)",
            ])

        // ── Microsoft Edge ────────────────────────────────────────────────────
        case "com.microsoft.edgemac":
            return .electronWithUserDataDir([
                "--user-data-dir=\(support.appendingPathComponent("Microsoft Edge").path)",
                "--profile-directory=Default",
            ])

        // ── Google Chrome ─────────────────────────────────────────────────────
        case "com.google.Chrome":
            return .electronWithUserDataDir([
                "--user-data-dir=\(support.appendingPathComponent("Google/Chrome").path)",
            ])

        // ── Slack (Electron, NOT sandboxed) ───────────────────────────────────
        // TESTED: Slack has app.asar + electron.icns, no com.apple.security.app-sandbox.
        // HOME + --user-data-dir gives full isolation.
        case "com.tinyspeck.slackmacgap":
            return .electronWithUserDataDir([
                "--user-data-dir=\(support.appendingPathComponent("Slack").path)",
            ])

        // ── VS Code (Electron) ────────────────────────────────────────────────
        case "com.microsoft.VSCode":
            return .electronWithUserDataDir([
                "--user-data-dir=\(support.appendingPathComponent("VSCode").path)",
                "--extensions-dir=\(support.appendingPathComponent("VSCode/extensions").path)",
            ])

        // ── Zoom ──────────────────────────────────────────────────────────────
        case "us.zoom.xos":
            return .homeRedirect

        default:
            return .homeRedirect
        }
    }
}

// MARK: - IsolatedLaunchError

public enum IsolatedLaunchError: LocalizedError {
    case profileNotMounted(String)
    case appNotInstalled(String)
    case noBrowserInstalled(String)
    case processStartFailed(String, Error)

    public var errorDescription: String? {
        switch self {
        case .profileNotMounted(let name):
            return "Workspace profile '\(name)' is not mounted. Unlock it first."
        case .appNotInstalled(let bundleID):
            return "App with bundle ID '\(bundleID)' is not installed on this Mac."
        case .noBrowserInstalled(let appName):
            return "To launch \(appName) in isolation, Microsoft Edge or Google Chrome must be installed."
        case .processStartFailed(let displayName, let error):
            return "Failed to launch \(displayName): \(error.localizedDescription)"
        }
    }
}
