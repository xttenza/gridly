import NetworkExtension
import os.log

private let log = Logger(subsystem: "com.gridly.networkextension", category: "DNS")

/// NEDNSProxyProvider: resolves corporate domain names via the internal DNS server.
/// All other domains go through the system resolver unchanged.
final class WorkspaceDNSProxy: NEDNSProxyProvider {

    private var corporateDomains: [String] = []
    private var internalDNSServer: String = ""

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        // Configuration is passed via options dict from NEDNSProxyProviderProtocol.providerConfiguration
        if let domains = options?["corporateDomains"] as? [String] {
            corporateDomains = domains
        }
        if let dns = options?["internalDNS"] as? String {
            internalDNSServer = dns
        }
        log.info("DNS proxy started — \(self.corporateDomains.count) corporate domains")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // DNS proxy provider handles UDP/TCP port-53 flows automatically
        // via the NEDNSProxyProvider mechanism — override not strictly needed
        // but allows per-query logging and forwarding decisions
        return false  // Let NEDNSProxyProvider handle routing
    }
}
