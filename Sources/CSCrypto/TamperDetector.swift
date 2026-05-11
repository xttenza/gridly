import Foundation
import Security
import CryptoKit
import CSCore
import os.log

private let log = Logger(subsystem: "com.gridly", category: "TamperDetector")

public struct SystemIntegrityStatus: Sendable {
    public var sipEnabled: Bool = false
    public var appSignatureValid: Bool = false
    public var runningInVM: Bool = false
    public var debuggerAttached: Bool = false

    public var isSecure: Bool {
        appSignatureValid && !debuggerAttached
    }

    public var summary: String {
        var issues: [String] = []
        if !sipEnabled       { issues.append("SIP disabled") }
        if !appSignatureValid { issues.append("signature invalid") }
        if runningInVM       { issues.append("running in VM") }
        if debuggerAttached  { issues.append("debugger attached") }
        return issues.isEmpty ? "OK" : issues.joined(separator: ", ")
    }
}

public final class TamperDetector: Sendable {

    private let keychainManager: KeychainManager
    private static let baselineKey = "integrity.baseline.v1"

    public init(keychainManager: KeychainManager) {
        self.keychainManager = keychainManager
    }

    // MARK: - System Integrity

    public func checkSystemIntegrity() -> SystemIntegrityStatus {
        var status = SystemIntegrityStatus()
        status.sipEnabled       = isSIPEnabled()
        status.appSignatureValid = verifyOwnCodeSignature()
        status.runningInVM      = isRunningInVirtualMachine()
        status.debuggerAttached = isDebuggerPresent()
        return status
    }

    // MARK: - Binary Integrity (stores hash of self at install; verifies on each launch)

    public func storeIntegrityBaseline() throws {
        let fingerprint = try computeFingerprint()
        try keychainManager.store(data: fingerprint, key: Self.baselineKey)
        log.info("Integrity baseline stored: \(fingerprint.base64EncodedString(), privacy: .public)")
    }

    public func verifyIntegrity() throws -> Bool {
        guard let baseline = try keychainManager.retrieve(key: Self.baselineKey) else {
            log.warning("No integrity baseline — first run or reinstall")
            try storeIntegrityBaseline()
            return true
        }
        let current = try computeFingerprint()
        let match = constantTimeEqual(current, baseline)
        if !match {
            log.fault("Integrity check FAILED — binary may have been tampered with")
        }
        return match
    }

    // MARK: - XPC Caller Verification

    /// Verify XPC caller code signature.
    ///
    /// Security note on PID vs audit token:
    /// - Full Xcode SDK (production): `NSXPCConnection.auditToken` is used via ObjC bridge
    ///   (audit_token_t is immune to PID-reuse attacks).
    /// - CommandLineTools / SPM: falls back to PID + immediate `SecCodeCopyGuestWithAttributes`.
    ///   The window for a PID-reuse attack is microseconds and acceptable for a local daemon.
    ///   In a fully notarized production build, the Objective-C bridge below closes this gap.
    public func verifyXPCCaller(
        connection: NSXPCConnection,
        expectedTeamID: String,
        expectedBundleID: String
    ) -> Bool {
        // Attempt audit-token path via Objective-C runtime (available in full Xcode SDK).
        // `NSXPCConnection` exposes `auditToken` as an ObjC property since macOS 12;
        // the CommandLineTools Swift overlay omits the Swift projection, so we use
        // NSObject.value(forKey:) to retrieve the raw value safely.
        var code: SecCode?

        if let rawToken = connection.value(forKey: "auditToken") {
            // rawToken is an NSValue wrapping audit_token_t — extract bytes for SecCode.
            var tokenBytes = [UInt8](repeating: 0, count: 32)  // audit_token_t is 32 bytes
            (rawToken as AnyObject).getValue(&tokenBytes)
            let tokenData = Data(tokenBytes)
            let attrs = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
            if SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) != errSecSuccess {
                code = nil  // fall through to PID path
            }
        }

        // Fallback: PID-based lookup (compiles everywhere, slightly wider TOCTOU window).
        if code == nil {
            let pid = connection.processIdentifier
            let attrs = [kSecGuestAttributePid as String: pid] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
                  code != nil else {
                log.error("XPC: Could not obtain SecCode for connection (PID \(pid))")
                return false
            }
        }

        guard let resolvedCode = code else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(resolvedCode, [], &staticCode) == errSecSuccess,
              let sc = staticCode else { return false }

        let reqStr = "anchor apple generic and identifier \"\(expectedBundleID)\" and certificate leaf[subject.OU] = \"\(expectedTeamID)\"" as CFString

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqStr, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }

        let valid = SecStaticCodeCheckValidity(sc, [], req) == errSecSuccess
        if !valid {
            log.error("XPC: Caller verification failed for \(expectedBundleID, privacy: .public)")
        }
        return valid
    }

    // MARK: - Private Helpers

    private func computeFingerprint() throws -> Data {
        guard let exePath = Bundle.main.executablePath else {
            throw CSError.internalError("No executable path")
        }
        let exeData = try Data(contentsOf: URL(fileURLWithPath: exePath))
        var hasher = SHA256()
        hasher.update(data: exeData)

        // Also hash the main bundle's Info.plist
        if let infoPlistURL = Bundle.main.url(forResource: "Info", withExtension: "plist") {
            let infoPlistData = try Data(contentsOf: infoPlistURL)
            hasher.update(data: infoPlistData)
        }

        return Data(hasher.finalize())
    }

    private func verifyOwnCodeSignature() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let sc = staticCode else { return false }

        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let reqStr = "anchor apple generic and identifier \"\(bundleID)\"" as CFString
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqStr, [], &req) == errSecSuccess,
              let r = req else { return false }

        return SecStaticCodeCheckValidity(sc, [], r) == errSecSuccess
    }

    private func isSIPEnabled() -> Bool {
        var csrConfig: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        sysctlbyname("csr_active_config", &csrConfig, &size, nil, 0)
        return csrConfig == 0  // 0 = fully enabled
    }

    private func isRunningInVirtualMachine() -> Bool {
        var result: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.hv_vmm_present", &result, &size, nil, 0)
        return result != 0
    }

    private func isDebuggerPresent() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBytes { aBytes in
            b.withUnsafeBytes { bBytes in
                zip(aBytes, bBytes).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
            }
        }
    }
}
