import Foundation
import AppKit
import os.log
import CSCore
import CSAudit

private let log = Logger(subsystem: "com.gridly", category: "AppLauncher")

public final class AppLauncher: Sendable {

    private let workspaceURL: URL
    private let auditLogger: AuditLogger
    private let sessionID: UUID

    public init(workspaceURL: URL, auditLogger: AuditLogger, sessionID: UUID) {
        self.workspaceURL = workspaceURL
        self.auditLogger = auditLogger
        self.sessionID = sessionID
    }

    // MARK: - Launch

    public func launch(_ app: ManagedApp, vpnActive: Bool) async throws {
        guard app.isEnabled else {
            throw CSError.notSupported("\(app.displayName) is disabled by policy.")
        }

        if app.requiredVPN && !vpnActive {
            throw CSError.notSupported("\(app.displayName) requires VPN to be active.")
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            throw CSError.notSupported("\(app.displayName) is not installed (bundle ID: \(app.bundleID)).")
        }

        // Prepare isolated data directory on workspace volume
        if let relPath = app.dataDirectoryRelativePath {
            let dataDir = workspaceURL.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }

        let environment = buildEnvironment(for: app)

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = app.launchArguments
        config.environment = environment
        config.activates = true
        config.addsToRecentItems = false   // Don't pollute system Recent Items

        let runningApp = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)

        await auditLogger.log(
            .init(
                sessionID: sessionID,
                eventType: .appLaunched,
                payload: [
                    "bundleID": app.bundleID,
                    "pid": "\(runningApp.processIdentifier)",
                    "displayName": app.displayName
                ]
            )
        )
        log.info("Launched \(app.displayName, privacy: .public) PID \(runningApp.processIdentifier)")
    }

    // MARK: - Install Check

    public func checkInstallStatuses(for apps: [ManagedApp]) -> [ManagedApp] {
        apps.map { app in
            var updated = app
            updated.installStatus = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: app.bundleID
            ) != nil ? .installed : .notInstalled
            return updated
        }
    }

    // MARK: - Private

    private func buildEnvironment(for app: ManagedApp) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Redirect application data to workspace volume
        if let relPath = app.dataDirectoryRelativePath {
            let dataDir = workspaceURL.appendingPathComponent(relPath)
            env["HOME"]        = dataDir.path
            env["USERPROFILE"] = dataDir.path
            env["APPDATA"]     = dataDir.appendingPathComponent("AppData").path
            env["TMPDIR"]      = workspaceURL.appendingPathComponent("tmp").path
        }

        // Merge app-specific env vars from policy
        for (key, value) in app.environmentVariables {
            env[key] = value
        }

        // Remove personal keychain search path so app uses its own workspace keychain
        env.removeValue(forKey: "KEYCHAIN_PATH")

        return env
    }
}
