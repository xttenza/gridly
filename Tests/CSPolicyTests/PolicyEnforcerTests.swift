import XCTest
import CryptoKit
@testable import CSCore
@testable import CSPolicy

final class PolicyEnforcerTests: XCTestCase {

    // MARK: - Network Blocking

    func testBlockedDomainReturnsBlock() async {
        let manifest = PolicyManifest(
            version: "1.0",
            tenantID: "test",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            lockTimeoutSeconds: 900,
            clipboardPolicy: .init(
                blockCorporateToPersonal: true,
                blockPersonalToCorporate: false,
                watermarkCopiedText: true
            ),
            dlpEnabled: true,
            watermarkEnabled: true,
            remoteWipeEnabled: true,
            auditShippingEndpointURL: nil,
            allowedNetworkDomains: [],
            blockedNetworkDomains: ["pastebin.com", "dropbox.com"],
            requiredApps: [],
            workspaceStorageQuotaGB: 50
        )

        let enforcer = makeEnforcer(manifest: manifest)
        let decision = await enforcer.evaluate(event: .networkRequest(host: "www.pastebin.com", appBundleID: "com.test"))

        if case .block(let reason) = decision {
            XCTAssertTrue(reason.contains("pastebin.com"))
        } else {
            XCTFail("Expected .block but got \(decision)")
        }
    }

    func testAllowedDomainPassesThrough() async {
        let manifest = PolicyManifest.default
        let enforcer = makeEnforcer(manifest: manifest)
        let decision = await enforcer.evaluate(event: .networkRequest(host: "microsoft.com", appBundleID: "com.microsoft.teams2"))

        if case .allow = decision { /* pass */ } else {
            XCTFail("Expected .allow but got \(decision)")
        }
    }

    // MARK: - File Access DLP

    func testFileExfiltratedOutsideWorkspaceIsBlocked() async {
        let enforcer = makeEnforcer(manifest: makeDLPManifest(dlpEnabled: true))
        let decision = await enforcer.evaluate(
            event: .fileAccess(
                path: "/Users/xttenza/Desktop/secret.pdf",
                operation: "copy",
                appBundleID: "com.microsoft.Word"
            )
        )

        if case .block = decision { /* pass */ } else {
            XCTFail("Expected DLP block for file outside workspace, got \(decision)")
        }
    }

    func testFileInsideWorkspaceIsAllowedWithAudit() async {
        let enforcer = makeEnforcer(manifest: makeDLPManifest(dlpEnabled: true))
        let decision = await enforcer.evaluate(
            event: .fileAccess(
                path: "/Volumes/Gridly/Documents/report.pdf",
                operation: "copy",
                appBundleID: "com.microsoft.Word"
            )
        )

        if case .allowWithAudit = decision { /* pass */ } else {
            XCTFail("Expected .allowWithAudit, got \(decision)")
        }
    }

    // MARK: - Screenshot

    func testScreenshotIsAllowedWithAudit() async {
        let enforcer = makeEnforcer(manifest: .default)
        let decision = await enforcer.evaluate(event: .screenCapture)

        if case .allowWithAudit = decision { /* pass */ } else {
            XCTFail("Screenshot should be allowWithAudit (cannot block on macOS)")
        }
    }

    // MARK: - Helpers

    private func makeEnforcer(manifest: PolicyManifest) -> PolicyEnforcer {
        let enforcer = PolicyEnforcer(
            cache: try! makePolicyCache(),
            networkMonitor: NetworkMonitor()
        )
        enforcer.applyManifest(manifest)
        return enforcer
    }

    private func makePolicyCache() throws -> PolicyCache {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".db")
        let key = SymmetricKey(size: .bits256)
        return try PolicyCache(databaseURL: tmp, cacheKey: key)
    }

    private func makeDLPManifest(dlpEnabled: Bool) -> PolicyManifest {
        PolicyManifest(
            version: "test",
            tenantID: "test",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            lockTimeoutSeconds: 900,
            clipboardPolicy: .init(blockCorporateToPersonal: true, blockPersonalToCorporate: false, watermarkCopiedText: true),
            dlpEnabled: dlpEnabled,
            watermarkEnabled: true,
            remoteWipeEnabled: true,
            auditShippingEndpointURL: nil,
            allowedNetworkDomains: [],
            blockedNetworkDomains: [],
            requiredApps: [],
            workspaceStorageQuotaGB: 50
        )
    }
}
