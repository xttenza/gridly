import NetworkExtension
import Network
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly.networkextension", category: "Proxy")

/// NEAppProxyProvider: routes managed app traffic through the corporate VPN tunnel.
/// Personal app traffic passes through unchanged — only managed bundle IDs are routed.
final class WorkspaceProxyProvider: NEAppProxyProvider {

    private var managedBundleIDs: Set<String> = Set(ManagedApp.defaultApps.map(\.bundleID))
    private var corporateVPNEndpoint: Network.NWEndpoint?

    // MARK: - Lifecycle

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        log.info("WorkspaceProxyProvider starting")

        // Load configuration from provider configuration (options takes priority)
        let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        if let bundleIDs = (options?["managedBundleIDs"] ?? providerConfig?["managedBundleIDs"]) as? [String] {
            managedBundleIDs = Set(bundleIDs)
        }

        if let host = (options?["vpnHost"] ?? providerConfig?["vpnHost"]) as? String,
           let portStr = (options?["vpnPort"] ?? providerConfig?["vpnPort"]) as? String,
           let portNum = UInt16(portStr) {
            let nwHost = Network.NWEndpoint.Host(host)
            let nwPort = Network.NWEndpoint.Port(rawValue: portNum) ?? .any
            corporateVPNEndpoint = .hostPort(host: nwHost, port: nwPort)
        }

        completionHandler(nil)
        log.info("WorkspaceProxyProvider started — managing \(self.managedBundleIDs.count) apps")
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("WorkspaceProxyProvider stopping: \(reason.rawValue)")
        completionHandler()
    }

    // MARK: - Flow Handling

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let bundleID = flow.metaData.sourceAppSigningIdentifier
        guard !bundleID.isEmpty else {
            return false   // Unknown app — don't proxy
        }

        let isManagedApp = managedBundleIDs.contains(bundleID)
        guard isManagedApp else {
            return false   // Personal app — pass through system stack unchanged
        }

        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            handleTCPFlow(tcpFlow, bundleID: bundleID)
            return true
        }
        if let udpFlow = flow as? NEAppProxyUDPFlow {
            handleUDPFlow(udpFlow, bundleID: bundleID)
            return true
        }

        return false
    }

    // MARK: - TCP

    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow, bundleID: String) {
        guard let endpoint = corporateVPNEndpoint else {
            // No VPN endpoint configured — pass through
            flow.open(withLocalEndpoint: nil) { _ in }
            return
        }

        log.debug("Routing TCP from \(bundleID, privacy: .public) through corporate VPN")

        // Create NWConnection to VPN gateway and relay bidirectional traffic
        let connection = Network.NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: DispatchQueue.global(qos: .utility))

        flow.open(withLocalEndpoint: nil) { error in
            if let error {
                log.error("TCP flow open failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            self.relayTCP(flow: flow, connection: connection)
        }
    }

    private func relayTCP(flow: NEAppProxyTCPFlow, connection: Network.NWConnection) {
        // App → VPN gateway
        func readFromFlow() {
            flow.readData { data, error in
                if let error { log.debug("Flow read ended: \(error.localizedDescription, privacy: .public)"); return }
                guard let data, !data.isEmpty else { return }
                connection.send(content: data, completion: .contentProcessed { _ in readFromFlow() })
            }
        }

        // VPN gateway → App
        func readFromVPN() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    flow.write(data) { _ in readFromVPN() }
                }
                if isComplete || error != nil { flow.closeReadWithError(error) }
            }
        }

        readFromFlow()
        readFromVPN()
    }

    // MARK: - UDP

    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow, bundleID: String) {
        log.debug("UDP flow from \(bundleID, privacy: .public) — allowing directly")
        // For MVP: allow UDP through without proxying (VoIP / Teams call quality)
        flow.open(withLocalEndpoint: nil) { _ in }
    }
}
