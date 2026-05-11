import Foundation
import AppKit
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "BrowserProfile")

public final class BrowserProfileManager: Sendable {

    private let workspaceURL: URL

    public struct BrowserProfile: Sendable {
        public let name: String
        public let userDataDir: URL
        public let policyDir: URL
    }

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    // MARK: - Profile Setup

    public func setupEdgeProfile() throws -> BrowserProfile {
        let profileDir = workspaceURL
            .appendingPathComponent("BrowserProfiles/Edge")
        let policyDir = profileDir.appendingPathComponent("managed")

        try FileManager.default.createDirectory(at: policyDir, withIntermediateDirectories: true)

        let policies: [String: Any] = [
            "SyncDisabled": true,
            "BrowserSignin": 2,                  // Force sign-in with org account
            "NonRemovableProfileEnabled": true,
            "PasswordManagerEnabled": false,      // Use corporate SSO
            "AutofillAddressEnabled": false,
            "AutofillCreditCardEnabled": false,
            "SafeBrowsingEnabled": true,
            "DownloadDirectory": workspaceURL.appendingPathComponent("Downloads").path,
            "DefaultDownloadDirectory": workspaceURL.appendingPathComponent("Downloads").path,
            "PromptForDownloadLocation": false,
            "DefaultCookiesSetting": 1,           // Allow all cookies (SSO needs them)
            "DefaultPopupsSetting": 2,            // Block popups by default
            "BackgroundModeEnabled": false,
            "MetricsReportingEnabled": false,
            "SpellCheckServiceEnabled": false,
            "TranslateEnabled": false,            // Avoid data leaving to Google Translate
        ]

        let policyData = try JSONSerialization.data(withJSONObject: policies, options: .prettyPrinted)
        try policyData.write(to: policyDir.appendingPathComponent("policy.json"))

        // Create downloads directory
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent("Downloads"),
            withIntermediateDirectories: true
        )

        log.info("Edge workspace profile ready at \(profileDir.path, privacy: .public)")
        return BrowserProfile(name: "Gridly-Edge", userDataDir: profileDir, policyDir: policyDir)
    }

    // MARK: - Launch

    public func launchEdge(url: URL? = nil, profile: BrowserProfile) throws {
        let edgeCandidates = [
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Microsoft Edge Beta.app/Contents/MacOS/Microsoft Edge Beta",
        ]
        guard let edgePath = edgeCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw CSError.notSupported("Microsoft Edge is not installed. Please install it from https://aka.ms/edgemac")
        }

        var args: [String] = [
            "--user-data-dir=\(profile.userDataDir.path)",
            "--profile-directory=Default",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-extensions-except=",      // Start with no personal extensions
            "--download-default-directory=\(workspaceURL.appendingPathComponent("Downloads").path)",
        ]
        if let url { args.append(url.absoluteString) }

        var environment = ProcessInfo.processInfo.environment
        // Redirect HOME so Edge picks up workspace profile unconditionally
        environment["HOME"] = profile.userDataDir.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: edgePath)
        process.arguments = args
        process.environment = environment
        try process.run()

        log.info("Microsoft Edge launched with workspace profile")
    }

    public func launchSafariWithWorkspaceSession(url: URL? = nil) throws {
        // Safari doesn't support --user-data-dir; open in Private Browsing for isolation
        var components = URLComponents(string: "x-safari-private://")!
        if let url { components.path = url.absoluteString }
        if let safeURL = components.url {
            NSWorkspace.shared.open(safeURL)
        }
        log.info("Safari opened in private mode for workspace session")
    }
}
