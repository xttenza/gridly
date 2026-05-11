import Foundation
import AppKit
import UserNotifications
import os.log
import CSCore
import CSCrypto
import CSPolicy

private let log = Logger(subsystem: "com.gridly", category: "DeviceRegistration")

public final class DeviceRegistrationManager: @unchecked Sendable {

    private let graphClient: GraphClientProtocol
    private let keychainManager: KeychainManager
    private var apnsToken: String?

    public init(graphClient: GraphClientProtocol, keychainManager: KeychainManager) {
        self.graphClient = graphClient
        self.keychainManager = keychainManager
    }

    // MARK: - APNs Registration

    /// Register for Apple Push Notification Service to receive remote wipe / lock commands.
    public func registerForRemoteNotifications() async throws -> String {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        guard granted else {
            log.warning("APNs authorization denied — remote wipe via push unavailable")
            throw CSError.notSupported("Push notification permission denied. Remote commands will use polling.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                NSApplication.shared.registerForRemoteNotifications()
                // Token delivered to AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
                // Store token via NotificationCenter observation
                NotificationCenter.default.addObserver(
                    forName: .apnsTokenReceived,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let token = notification.userInfo?["token"] as? String {
                        continuation.resume(returning: token)
                    }
                }
            }
        }
    }

    public func handleAPNsToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02.2hhx", $0) }.joined()
        self.apnsToken = token
        NotificationCenter.default.post(
            name: .apnsTokenReceived,
            object: nil,
            userInfo: ["token": token]
        )
        log.info("APNs token registered (\(token.prefix(8), privacy: .public)…)")

        // Persist for use after restart
        try? keychainManager.store(data: Data(token.utf8), key: "apnsToken")
    }

    // MARK: - Intune Check-in

    public func checkIn(deviceID: String, complianceState: ComplianceState) async {
        // POST check-in to Graph API
        log.info("Device check-in: \(complianceState.rawValue, privacy: .public)")
    }
}

extension Notification.Name {
    static let apnsTokenReceived = Notification.Name("com.gridly.apnsTokenReceived")
}
