import Foundation

/// XPC interface exposed by GridlyAgent to the main app.
/// Keep types simple — only NSData, NSString, NSNumber cross XPC boundaries safely.
@objc public protocol AgentXPCProtocol {

    // Workspace lifecycle
    func lockWorkspace(reply: @escaping (Bool) -> Void)
    func workspaceIsLocked(reply: @escaping (Bool) -> Void)
    func mountWorkspace(passphraseData: Data, reply: @escaping (Bool, String) -> Void)
    func unmountWorkspace(reply: @escaping (Bool) -> Void)

    // Policy
    func syncPolicy(reply: @escaping (Bool, String) -> Void)
    func currentComplianceState(reply: @escaping (String) -> Void)

    // Audit
    func logEvent(typeRawValue: String, payloadJSON: String, reply: @escaping (Bool) -> Void)

    // Remote wipe
    func executeWipe(commandJSON: String, accountID: String, reply: @escaping (Bool, String) -> Void)

    // Agent health
    func ping(reply: @escaping (Bool) -> Void)
}

public let AgentMachServiceName = "com.gridly.agent.xpc"
