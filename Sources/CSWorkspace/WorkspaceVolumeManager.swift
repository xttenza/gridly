import Foundation
import DiskArbitration
import os.log
import CSCore
import CSCrypto

private let log = Logger(subsystem: "com.gridly", category: "VolumeManager")

/// Manages the lifecycle of the encrypted APFS sparse bundle that holds all
/// corporate workspace data.  This class runs in the **privileged helper** process
/// (SMJobBless) so it can call hdiutil without a user-visible prompt for every mount.
public final class WorkspaceVolumeManager: WorkspaceManaging, @unchecked Sendable {

    private let containerDirectory: URL
    private let bundleName = "workspace.sparsebundle"
    /// The APFS volume label — appears as /Volumes/<volumeName> when mounted.
    /// Defaults to "Gridly" for the primary workspace; per-profile
    /// volumes use "CS-<shortID>" so they coexist without name conflicts.
    public let volumeName: String

    private let lock = NSLock()
    private var _mountURL: URL?
    private var _isMounted: Bool = false

    public init(containerDirectory: URL, volumeName: String = "Gridly") {
        self.containerDirectory = containerDirectory
        self.volumeName = volumeName
    }

    // MARK: - Convenience alias used by ProfileManager

    /// Creates an encrypted APFS sparse bundle. Wrapper over `createVolume`.
    public func create(passphrase: String, sizeGB: Int = 10) async throws {
        _ = try await createVolume(sizeGB: sizeGB, passphrase: passphrase)
    }

    // MARK: - WorkspaceManaging

    public var isMounted: Bool {
        get async { lock.withLock { _isMounted } }
    }

    public var mountURL: URL? {
        get async { lock.withLock { _mountURL } }
    }

    // MARK: - Volume Creation

    /// Create a new AES-256–encrypted APFS sparse bundle.
    /// Only called once at enrollment.
    public func createVolume(sizeGB: Int = 50, passphrase: String) async throws -> URL {
        let bundleURL = containerDirectory.appendingPathComponent(bundleName)

        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw CSError.workspaceAlreadyMounted
        }

        try FileManager.default.createDirectory(
            at: containerDirectory,
            withIntermediateDirectories: true
        )

        let args = [
            "create",
            "-type",        "SPARSEBUNDLE",
            "-fs",          "APFS",
            "-size",        "\(sizeGB)g",
            "-encryption",  "AES-256",
            "-passphrase",  passphrase,
            "-volname",     volumeName,   // becomes the /Volumes/<name> mount point
            "-nospotlight",               // exclude from Spotlight
            bundleURL.deletingPathExtension().path  // hdiutil appends .sparsebundle
        ]

        try await runHdiutil(args)
        log.info("Workspace volume created at \(bundleURL.path, privacy: .public)")
        return bundleURL
    }

    // MARK: - Mount / Unmount

    public func mount(passphrase: String) async throws -> URL {
        guard !(await isMounted) else {
            return lock.withLock { _mountURL! }
        }

        let bundleURL = containerDirectory.appendingPathComponent(bundleName)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw CSError.workspaceVolumeNotFound
        }

        let args = [
            "attach",
            bundleURL.path,
            "-passphrase",  passphrase,
            "-nobrowse",    // hide from Finder sidebar
            "-noautoopen",  // don't open Finder window
        ]

        let output = try await runHdiutil(args, captureOutput: true)
        let url = try parseMountPoint(from: output)

        lock.withLock {
            _mountURL = url
            _isMounted = true
        }

        log.info("Workspace mounted at \(url.path, privacy: .public)")
        return url
    }

    public func unmount() async throws {
        guard await isMounted else { return }

        let args = ["detach", "/Volumes/\(volumeName)", "-force"]
        try? await runHdiutil(args)   // best-effort; don't throw if already gone

        lock.withLock {
            _mountURL = nil
            _isMounted = false
        }
        log.info("Workspace unmounted")
    }

    public func lock() async {
        try? await unmount()
    }

    public func unlock(passphrase: String) async throws {
        _ = try await mount(passphrase: passphrase)
    }

    // MARK: - Wipe

    /// Two-stage wipe:
    /// 1. Unmount (instant).
    /// 2. Delete the sparse bundle (async, belt-and-suspenders — real wipe is DEK destruction).
    public func cryptographicWipe(removeBundle: Bool = true) async throws {
        try? await unmount()

        guard removeBundle else { return }

        let bundleURL = containerDirectory.appendingPathComponent(bundleName)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else { return }

        // srm: secure remove; -rf: recursive force; overwrite before delete
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/srm")
        process.arguments = ["-rf", bundleURL.path]
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }

        log.info("Workspace bundle removed")
    }

    // MARK: - Quota

    public func checkQuota(maxGB: Int) async throws -> (usedGB: Double, availableGB: Double) {
        guard let mountURL = await mountURL else { throw CSError.workspaceNotMounted }

        let attrs = try FileManager.default.attributesOfFileSystem(forPath: mountURL.path)
        let total  = (attrs[.systemSize]        as? NSNumber)?.doubleValue ?? 0
        let avail  = (attrs[.systemFreeSize]    as? NSNumber)?.doubleValue ?? 0
        let used   = total - avail

        return (usedGB: used / 1_073_741_824, availableGB: avail / 1_073_741_824)
    }

    // MARK: - Private Helpers

    @discardableResult
    private func runHdiutil(_ args: [String], captureOutput: Bool = false) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if p.terminationStatus != 0 {
                    continuation.resume(throwing: CSError.workspaceMountFailed(err.isEmpty ? "exit \(p.terminationStatus)" : err))
                } else {
                    continuation.resume(returning: captureOutput ? out : "")
                }
            }
        }
    }

    private func parseMountPoint(from output: String) throws -> URL {
        // hdiutil attach output: each line is tab-separated: <dev_entry> <content_hint> <mount_point>
        for line in output.components(separatedBy: "\n") {
            let cols = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let last = cols.last, last.hasPrefix("/Volumes/") {
                return URL(fileURLWithPath: last)
            }
        }
        throw CSError.workspaceMountFailed("Could not determine mount point from hdiutil output")
    }
}
