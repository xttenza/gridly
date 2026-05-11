import Foundation
import AppKit
import CSCore
import os.log

private let log = Logger(subsystem: "com.gridly", category: "UserEnrollmentClient")

// MARK: - MDMEnrollmentStatus

/// Describes the current MDM enrollment state of this Mac.
public struct MDMEnrollmentStatus: Sendable {

    /// Whether any MDM configuration profile is installed.
    public let isEnrolled: Bool

    /// Server URL reported by the installed MDM payload, if any.
    public let serverURL: String?

    /// Organisation / payload display name of the MDM profile.
    public let organisationName: String?

    /// Whether the enrolled MDM uses Apple User Enrollment (scoped to user,
    /// not full-device management).
    public let isUserEnrollment: Bool

    /// Whether this appears to be a Microsoft Intune enrollment.
    public let isIntuneEnrollment: Bool

    public static let notEnrolled = MDMEnrollmentStatus(
        isEnrolled: false,
        serverURL: nil,
        organisationName: nil,
        isUserEnrollment: false,
        isIntuneEnrollment: false
    )
}

// MARK: - UserEnrollmentClient

/// Detects Apple MDM User Enrollment status and guides the user through
/// enrolling with Microsoft Intune (or any compatible MDM server).
///
/// Apple User Enrollment (macOS 13+):
///   - Creates a separate APFS volume scoped to the MDM channel.
///   - Company can push Wi-Fi, VPN, certificates, and managed apps to that volume.
///   - Company **cannot** wipe the personal volume, see personal apps/data,
///     or read the real hardware serial number (a synthetic ID is presented).
///   - Requires macOS to create the enrollment relationship; Gridly just guides it.
public actor UserEnrollmentClient {

    // MARK: - Microsoft Intune endpoints

    private static let intuneEnrollURL     = URL(string: "https://portal.manage.microsoft.com/enrollment/")!
    private static let companyPortalBundleID = "com.microsoft.CompanyPortalMac"
    private static let companyPortalMASID    = "com.microsoft.intune.companyportal"
    private static let profilesPath          = "/usr/bin/profiles"

    public init() {}

    // MARK: - Enrollment detection

    /// Reads the current MDM enrollment status from the `profiles` CLI.
    /// Runs as the current user — no elevated privileges needed for reading.
    public func enrollmentStatus() async -> MDMEnrollmentStatus {
        guard FileManager.default.fileExists(atPath: Self.profilesPath) else {
            // macOS < 13 (shouldn't happen given our deployment target)
            log.warning("profiles binary not found at \(Self.profilesPath, privacy: .public)")
            return .notEnrolled
        }

        do {
            let output = try await runProfiles(arguments: ["-P", "-o", "stdout-xml"])
            return parseMDMStatus(from: output)
        } catch {
            log.warning("profiles list failed: \(error.localizedDescription, privacy: .public)")
            return .notEnrolled
        }
    }

    /// Polls until MDM enrollment is detected or the timeout expires.
    /// Returns the status at the time of detection (enrolled) or at timeout (not enrolled).
    public func waitForEnrollment(
        timeout: TimeInterval = 300,
        pollInterval: TimeInterval = 5
    ) async -> MDMEnrollmentStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = await enrollmentStatus()
            if status.isEnrolled {
                log.info("MDM enrollment detected: \(status.organisationName ?? "unknown", privacy: .public)")
                return status
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        log.info("Enrollment polling timed out after \(timeout, privacy: .public)s")
        return .notEnrolled
    }

    // MARK: - Enrollment launch

    /// Opens Company Portal to the device enrollment screen.
    /// Falls back to the Intune web portal if Company Portal isn't installed.
    @MainActor
    public func startEnrollment() {
        // Prefer Company Portal app (already installed for Tier 1 SSO)
        for bundleID in [Self.companyPortalBundleID, Self.companyPortalMASID] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                // Open Company Portal — user taps "Enroll Device" inside it
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: .init(),
                    completionHandler: nil
                )
                log.info("Opened Company Portal for enrollment at \(url.path, privacy: .public)")
                return
            }
        }
        // Fallback: Intune web portal
        NSWorkspace.shared.open(Self.intuneEnrollURL)
        log.info("Opened Intune web portal for enrollment")
    }

    /// Opens System Settings → Privacy & Security → Profiles so the user
    /// can confirm a downloaded enrollment profile.
    @MainActor
    public func openProfilesPreferencePane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.configurationprofiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private helpers

    /// Runs `/usr/bin/profiles` with the given arguments and returns stdout.
    private func runProfiles(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.profilesPath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 || !output.isEmpty {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: CSError.commandFailed("profiles exited \(p.terminationStatus)"))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Parses the XML plist output of `profiles -P -o stdout-xml` to extract MDM info.
    private func parseMDMStatus(from xml: String) -> MDMEnrollmentStatus {
        guard let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else {
            return .notEnrolled
        }

        // profiles -P emits: { "_computerlevel": [ { ... profile dicts ... } ] }
        // and: { "xttenza": [ ... ] } for user-level profiles
        var allProfiles: [[String: Any]] = []
        for value in root.values {
            if let arr = value as? [[String: Any]] {
                allProfiles.append(contentsOf: arr)
            }
        }

        // Look for an MDM payload type in any installed profile
        for profile in allProfiles {
            guard let payloadContent = profile["_computerlevel"] as? [[String: Any]]
                    ?? profile["ProfileItems"] as? [[String: Any]]
                    ?? (profile["PayloadContent"] as? [[String: Any]]) else { continue }

            for payload in payloadContent {
                let payloadType = payload["PayloadType"] as? String ?? ""
                guard payloadType == "com.apple.mdm" else { continue }

                let serverURL   = payload["ServerURL"] as? String
                let orgName     = profile["PayloadOrganization"] as? String
                    ?? profile["PayloadDisplayName"] as? String

                // User Enrollment: CheckinURL contains "/checkin" and
                // the MDM profile has AccessRights != 8191 (full access)
                let accessRights = payload["AccessRights"] as? Int ?? 0
                let isUserEnroll = accessRights < 8191  // full device = 8191

                let isIntune = serverURL?.contains("microsoft.com") == true
                    || serverURL?.contains("manage.microsoft.com") == true
                    || orgName?.lowercased().contains("intune") == true

                log.info("MDM profile found: org=\(orgName ?? "nil", privacy: .public) server=\(serverURL ?? "nil", privacy: .public) userEnroll=\(isUserEnroll, privacy: .public)")

                return MDMEnrollmentStatus(
                    isEnrolled: true,
                    serverURL: serverURL,
                    organisationName: orgName,
                    isUserEnrollment: isUserEnroll,
                    isIntuneEnrollment: isIntune
                )
            }
        }

        return .notEnrolled
    }
}
