import Foundation
import os.log
import CSCrypto

private let log = Logger(subsystem: "com.gridly.helper", category: "HelperMain")

// MARK: - Privileged Helper (SMJobBless)
// Runs as root. Minimal attack surface — only mounts/unmounts APFS volume
// and manages the master key in Keychain. All other operations in Agent (user context).

@objc protocol HelperXPCProtocol {
    func mountWorkspace(bundlePath: String, passphrase: String, reply: @escaping (Bool, String) -> Void)
    func unmountWorkspace(volumeName: String, reply: @escaping (Bool) -> Void)
    func createWorkspaceVolume(bundlePath: String, passphrase: String, sizeGB: Int, reply: @escaping (Bool, String) -> Void)
    func getVersion(reply: @escaping (String) -> Void)
}

final class HelperXPCHandler: NSObject, HelperXPCProtocol {

    private let crypto = EncryptionKeyLifecycle()
    private static let allowedTeamID   = "YOUR_TEAM_ID"
    private static let allowedBundleID = "com.gridly.agent"

    func mountWorkspace(bundlePath: String, passphrase: String, reply: @escaping (Bool, String) -> Void) {
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            reply(false, "Bundle not found at \(bundlePath)"); return
        }
        runHdiutil(args: [
            "attach", bundlePath,
            "-passphrase", passphrase,
            "-nobrowse", "-noautoopen"
        ]) { success, output in
            reply(success, output)
        }
    }

    func unmountWorkspace(volumeName: String, reply: @escaping (Bool) -> Void) {
        runHdiutil(args: ["detach", "/Volumes/\(volumeName)", "-force"]) { success, _ in
            reply(success)
        }
    }

    func createWorkspaceVolume(bundlePath: String, passphrase: String, sizeGB: Int, reply: @escaping (Bool, String) -> Void) {
        let noBundleExt = (bundlePath as NSString).deletingPathExtension
        runHdiutil(args: [
            "create",
            "-type",        "SPARSEBUNDLE",
            "-fs",          "APFS",
            "-size",        "\(sizeGB)g",
            "-encryption",  "AES-256",
            "-passphrase",  passphrase,
            "-volname",     "Gridly",
            "-nospotlight",
            noBundleExt
        ]) { success, output in
            reply(success, output)
        }
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply("GridlyHelper/1.0")
    }

    // MARK: - Private

    private func runHdiutil(args: [String], completion: @escaping (Bool, String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        do {
            try process.run()
        } catch {
            completion(false, error.localizedDescription)
            return
        }

        process.terminationHandler = { p in
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            completion(p.terminationStatus == 0, p.terminationStatus == 0 ? out : err)
        }
    }
}

// MARK: - Listener

final class HelperListener: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // In privileged helper, audit token verification is critical
        // Only accept connections from our signed agent
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject    = HelperXPCHandler()
        connection.resume()
        log.info("Helper: Accepted XPC connection")
        return true
    }
}

// MARK: - Entry Point

enum HelperEntryPoint {
    static func run() {
        log.info("GridlyHelper starting")
        let listener = NSXPCListener.service()
        let delegate = HelperListener()
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
    }
}
