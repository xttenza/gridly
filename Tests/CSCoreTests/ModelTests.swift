import XCTest
@testable import CSCore

final class WorkspaceSessionTests: XCTestCase {

    func testIsTokenExpiredReturnsTrueForPastDate() {
        let session = WorkspaceSession(
            userPrincipalName: "user@corp.com",
            displayName: "Test User",
            tenantID: UUID().uuidString,
            accessTokenExpiresAt: Date().addingTimeInterval(-1),
            isAuthenticated: true,
            complianceStatus: .compliant
        )
        XCTAssertTrue(session.isTokenExpired)
    }

    func testIsTokenExpiredReturnsFalseForFutureDate() {
        let session = WorkspaceSession(
            userPrincipalName: "user@corp.com",
            displayName: "Test User",
            tenantID: UUID().uuidString,
            accessTokenExpiresAt: Date().addingTimeInterval(3600),
            isAuthenticated: true,
            complianceStatus: .compliant
        )
        XCTAssertFalse(session.isTokenExpired)
    }

    func testSessionCodableRoundTrip() throws {
        let session = WorkspaceSession(
            userPrincipalName: "user@corp.com",
            displayName: "Test User",
            tenantID: "tenant-123",
            accessTokenExpiresAt: Date().addingTimeInterval(3600),
            isAuthenticated: true,
            complianceStatus: .compliant
        )
        let data    = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(WorkspaceSession.self, from: data)

        XCTAssertEqual(decoded.userPrincipalName, session.userPrincipalName)
        XCTAssertEqual(decoded.complianceStatus,  session.complianceStatus)
        XCTAssertEqual(decoded.id,                session.id)
    }
}

final class ComplianceStateTests: XCTestCase {

    func testCompliantDoesNotBlockWorkspace() {
        XCTAssertFalse(ComplianceState.compliant.blocksWorkspace)
    }

    func testNonCompliantBlocksWorkspace() {
        XCTAssertTrue(ComplianceState.noncompliant.blocksWorkspace)
    }

    func testErrorBlocksWorkspace() {
        XCTAssertTrue(ComplianceState.error.blocksWorkspace)
    }

    func testAllStatesHaveDisplayName() {
        for state in ComplianceState.allCases {
            XCTAssertFalse(state.displayName.isEmpty, "\(state) has no display name")
        }
    }

    func testAllStatesHaveSystemImage() {
        for state in ComplianceState.allCases {
            XCTAssertFalse(state.systemImage.isEmpty, "\(state) has no systemImage")
        }
    }
}

final class ManagedAppTests: XCTestCase {

    func testDefaultAppsAreNotEmpty() {
        XCTAssertFalse(ManagedApp.defaultApps.isEmpty)
    }

    func testDefaultAppsHaveUniqueBundleIDs() {
        let ids = ManagedApp.defaultApps.map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate bundle IDs in defaultApps")
    }

    func testDefaultAppsHaveUniqueIDs() {
        let ids = ManagedApp.defaultApps.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate IDs in defaultApps")
    }

    func testIsInstalledForInstalledStatus() {
        var app = ManagedApp.defaultApps[0]
        app.installStatus = .installed
        XCTAssertTrue(app.isInstalled)
    }

    func testIsInstalledFalseForNotInstalled() {
        var app = ManagedApp.defaultApps[0]
        app.installStatus = .notInstalled
        XCTAssertFalse(app.isInstalled)
    }
}
