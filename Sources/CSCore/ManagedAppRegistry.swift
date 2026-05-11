import Foundation

/// Shared registry of managed (corporate) app bundle IDs.
/// Lives in CSCore so both CSWorkspace (ClipboardGuard) and CSPolicy (DLPController) can use it
/// without creating a circular dependency.
public final class ManagedAppRegistry: @unchecked Sendable {
    public static let shared = ManagedAppRegistry()

    private let lock = NSLock()
    private var managedBundleIDs: Set<String> = Set(ManagedApp.defaultApps.map(\.bundleID))

    private init() {}

    public func isManagedApp(bundleID: String) -> Bool {
        lock.withLock { managedBundleIDs.contains(bundleID) }
    }

    public func sync(apps: [ManagedApp]) {
        lock.withLock { managedBundleIDs = Set(apps.map(\.bundleID)) }
    }
}
