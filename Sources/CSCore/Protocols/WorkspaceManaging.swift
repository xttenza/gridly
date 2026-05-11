import Foundation

public protocol WorkspaceManaging: Sendable {
    var isMounted: Bool { get async }
    var mountURL: URL? { get async }

    func mount(passphrase: String) async throws -> URL
    func unmount() async throws
    func lock() async
    func unlock(passphrase: String) async throws
    func createVolume(sizeGB: Int, passphrase: String) async throws -> URL
    func cryptographicWipe(removeBundle: Bool) async throws
}

public protocol PolicyEnforcing: Sendable {
    func evaluate(event: PolicyEvent) async -> PolicyDecision
    func syncPolicy() async throws -> PolicyManifest
    func currentPolicy() async -> PolicyManifest?
}

public enum PolicyEvent: Sendable {
    case appLaunch(bundleID: String)
    case fileAccess(path: String, operation: String, appBundleID: String)
    case clipboardCopy(fromAppBundleID: String, contentTypes: [String])
    case networkRequest(host: String, appBundleID: String)
    case screenCapture
}

public enum PolicyDecision: Sendable {
    case allow
    case block(reason: String)
    case allowWithAudit
    case requireMFA
}
