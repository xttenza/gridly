import Foundation
import os.log
import CSCrypto

private let log = Logger(subsystem: "com.gridly.agent", category: "XPC")

final class AgentXPCListener: NSObject, NSXPCListenerDelegate {

    private let handler: AgentXPCHandler
    private let tamperDetector: TamperDetector
    private static let expectedTeamID   = "YOUR_TEAM_ID"   // Replace at build time
    private static let expectedBundleID = "com.gridly.app"

    init(handler: AgentXPCHandler, tamperDetector: TamperDetector) {
        self.handler = handler
        self.tamperDetector = tamperDetector
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Verify the caller is our signed main app — not any other process
        guard tamperDetector.verifyXPCCaller(
            connection: connection,
            expectedTeamID: Self.expectedTeamID,
            expectedBundleID: Self.expectedBundleID
        ) else {
            log.error("XPC: Rejected connection from unverified caller")
            return false
        }

        let interface = NSXPCInterface(with: AgentXPCProtocol.self)

        // Restrict allowed classes to prevent deserialization attacks
        let safeClasses: NSSet = [NSString.self, NSNumber.self, NSData.self]
        interface.setClasses(safeClasses as! Set<AnyHashable>,
                             for: #selector(AgentXPCProtocol.mountWorkspace(passphraseData:reply:)),
                             argumentIndex: 0,
                             ofReply: false)

        connection.exportedInterface = interface
        connection.exportedObject    = handler
        connection.invalidationHandler = {
            log.info("XPC connection invalidated")
        }
        connection.interruptionHandler = {
            log.warning("XPC connection interrupted")
        }

        connection.resume()
        log.info("XPC: Accepted connection from \(Self.expectedBundleID, privacy: .public)")
        return true
    }
}
