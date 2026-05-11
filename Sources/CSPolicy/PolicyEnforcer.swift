import Foundation
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "PolicyEnforcer")

public final class PolicyEnforcer: PolicyEnforcing, @unchecked Sendable {

    private let cache: PolicyCache
    private let networkMonitor: NetworkMonitor
    private var currentManifest: PolicyManifest?
    private let lock = NSLock()

    public init(cache: PolicyCache, networkMonitor: NetworkMonitor) {
        self.cache = cache
        self.networkMonitor = networkMonitor
    }

    // MARK: - PolicyEnforcing

    public func evaluate(event: PolicyEvent) async -> PolicyDecision {
        guard let policy = lock.withLock({ currentManifest }) else {
            return .allowWithAudit  // No policy loaded yet — allow but log
        }

        switch event {
        case .appLaunch(let bundleID):
            if policy.requiredApps.isEmpty { return .allow }
            return .allow  // Required apps enforcement is additive, not block-list

        case .fileAccess(let path, let operation, _):
            if policy.dlpEnabled {
                return evaluateFileAccess(path: path, operation: operation, policy: policy)
            }
            return .allow

        case .clipboardCopy(_, let contentTypes):
            if policy.clipboardPolicy.blockCorporateToPersonal {
                log.info("Clipboard copy — types: \(contentTypes.joined(separator: ","), privacy: .public)")
                return .allowWithAudit
            }
            return .allow

        case .networkRequest(let host, _):
            if policy.blockedNetworkDomains.contains(where: { host.hasSuffix($0) }) {
                return .block(reason: "Domain '\(host)' blocked by policy")
            }
            return .allow

        case .screenCapture:
            return .allowWithAudit   // Cannot block on macOS; log and alert
        }
    }

    public func syncPolicy() async throws -> PolicyManifest {
        // Network sync is handled by IntuneComplianceEngine; here we load from cache
        if let cached: PolicyManifest = try cache.retrieve(PolicyManifest.self, policyType: "manifest", tenantID: "") {
            lock.withLock { currentManifest = cached }
            return cached
        }
        // Fall back to built-in default until first sync
        let fallback = PolicyManifest.default
        lock.withLock { currentManifest = fallback }
        return fallback
    }

    public func currentPolicy() async -> PolicyManifest? {
        lock.withLock { currentManifest }
    }

    public func applyManifest(_ manifest: PolicyManifest) {
        lock.withLock { currentManifest = manifest }
        log.info("Policy manifest applied — version \(manifest.version, privacy: .public)")
    }

    // MARK: - File Access Evaluation

    private func evaluateFileAccess(path: String, operation: String, policy: PolicyManifest) -> PolicyDecision {
        // Block exfil operations (copy/move) to outside workspace volume
        if operation == "copy" || operation == "move" {
            let isInsideWorkspace = path.hasPrefix("/Volumes/Gridly")
            if !isInsideWorkspace {
                return .block(reason: "DLP: File transfer outside workspace volume blocked by policy")
            }
        }
        return .allowWithAudit
    }
}

// MARK: - Network Monitor

public final class NetworkMonitor: @unchecked Sendable {
    public static let shared = NetworkMonitor()
    @Published public private(set) var isConnected: Bool = true

    public init() {}
}
