// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Gridly",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CSCore",      targets: ["CSCore"]),
        .library(name: "CSCrypto",    targets: ["CSCrypto"]),
        .library(name: "CSAuth",      targets: ["CSAuth"]),
        .library(name: "CSWorkspace", targets: ["CSWorkspace"]),
        .library(name: "CSPolicy",    targets: ["CSPolicy"]),
        .library(name: "CSGraph",     targets: ["CSGraph"]),
        .library(name: "CSAudit",     targets: ["CSAudit"]),
        .library(name: "CSUI",        targets: ["CSUI"]),
    ],
    dependencies: [
        // Microsoft Authentication Library
        .package(
            url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc",
            from: "1.2.0"
        ),
        // SQLite ORM for policy cache & audit log
        .package(
            url: "https://github.com/groue/GRDB.swift",
            from: "6.0.0"
        ),
    ],
    targets: [
        // MARK: - CSCore (no external deps — shared types only)
        .target(
            name: "CSCore",
            dependencies: [],
            path: "Sources/CSCore"
        ),

        // MARK: - CSCrypto
        .target(
            name: "CSCrypto",
            dependencies: ["CSCore"],
            path: "Sources/CSCrypto"
        ),

        // MARK: - CSAuth
        .target(
            name: "CSAuth",
            dependencies: [
                "CSCore",
                "CSCrypto",
                .product(name: "MSAL", package: "microsoft-authentication-library-for-objc"),
            ],
            path: "Sources/CSAuth"
        ),

        // MARK: - CSWorkspace
        .target(
            name: "CSWorkspace",
            dependencies: ["CSCore", "CSCrypto", "CSAudit", "CSAuth"],
            path: "Sources/CSWorkspace"
        ),

        // MARK: - CSPolicy
        .target(
            name: "CSPolicy",
            dependencies: [
                "CSCore",
                "CSCrypto",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CSPolicy"
        ),

        // MARK: - CSGraph
        .target(
            name: "CSGraph",
            dependencies: ["CSCore", "CSAuth", "CSPolicy", "CSCrypto"],
            path: "Sources/CSGraph"
        ),

        // MARK: - CSAudit
        .target(
            name: "CSAudit",
            dependencies: [
                "CSCore",
                "CSCrypto",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CSAudit"
        ),

        // MARK: - CSUI
        .target(
            name: "CSUI",
            dependencies: ["CSCore", "CSAuth", "CSWorkspace", "CSPolicy", "CSGraph", "CSAudit"],
            path: "Sources/CSUI"
        ),

        // MARK: - Tests
        .testTarget(
            name: "CSCoreTests",
            dependencies: ["CSCore"],
            path: "Tests/CSCoreTests"
        ),
        .testTarget(
            name: "CSCryptoTests",
            dependencies: ["CSCrypto"],
            path: "Tests/CSCryptoTests"
        ),
        .testTarget(
            name: "CSPolicyTests",
            dependencies: ["CSPolicy"],
            path: "Tests/CSPolicyTests"
        ),
    ]
)
