import Foundation
import AppKit
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "DLPController")

/// Data Loss Prevention controller.
/// On macOS without ESF (Endpoint Security Framework), DLP operates through:
///   1. Clipboard monitoring (ClipboardGuard)
///   2. File system event monitoring (FSEvents) on the workspace volume
///   3. Policy evaluation for share/export operations
public final class DLPController: @unchecked Sendable {

    public enum DLPAction: Sendable {
        case allow
        case block(userMessage: String)
        case allowWithWatermark
        case alertAndLog
    }

    private let enforcer: PolicyEnforcer
    private let auditCallback: @Sendable (AuditEventType, [String: String]) -> Void
    private var fsEventStream: FSEventStreamRef?
    private let workspaceURL: URL

    public init(
        enforcer: PolicyEnforcer,
        workspaceURL: URL,
        auditCallback: @escaping @Sendable (AuditEventType, [String: String]) -> Void
    ) {
        self.enforcer = enforcer
        self.workspaceURL = workspaceURL
        self.auditCallback = auditCallback
    }

    // MARK: - FSEvents Monitoring

    public func startFileMonitoring() {
        let pathsToWatch = [workspaceURL.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        fsEventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
                guard let info = clientInfo else { return }
                let controller = Unmanaged<DLPController>.fromOpaque(info).takeUnretainedValue()
                // Bridge the opaque UnsafeMutableRawPointer to NSArray, then to [String]
                let nsArray = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue()
                guard let paths = nsArray as? [String] else { return }

                for (i, path) in paths.prefix(numEvents).enumerated() {
                    let flags = eventFlags[i]
                    controller.handleFSEvent(path: path, flags: flags)
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,    // 500ms latency — trade real-time for CPU efficiency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                     kFSEventStreamCreateFlagNoDefer)
        )

        if let stream = fsEventStream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            log.info("DLP file monitoring started on \(self.workspaceURL.path, privacy: .public)")
        }
    }

    public func stopFileMonitoring() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
    }

    // MARK: - Share Sheet Integration

    /// Evaluate whether a share operation should be allowed.
    public func evaluateShare(
        fileURL: URL,
        destinationAppBundleID: String
    ) async -> DLPAction {
        let isManagedDestination = ManagedAppRegistry.shared.isManagedApp(bundleID: destinationAppBundleID)

        if !isManagedDestination {
            auditCallback(.fileAccessBlocked, [
                "path": fileURL.lastPathComponent,
                "operation": "share",
                "destination": destinationAppBundleID,
                "blocked": "true"
            ])
            return .block(userMessage: "Sharing corporate files to '\(destinationAppBundleID)' is not permitted by your organization's policy.")
        }

        auditCallback(.fileCopied, [
            "path": fileURL.lastPathComponent,
            "operation": "share",
            "destination": destinationAppBundleID,
            "blocked": "false"
        ])
        return .allowWithWatermark
    }

    // MARK: - Private

    private func handleFSEvent(path: String, flags: FSEventStreamEventFlags) {
        let isCreated  = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)  != 0
        let isModified = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0
        let isRemoved  = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)  != 0

        let operation = isCreated ? "create" : isModified ? "modify" : isRemoved ? "delete" : "unknown"

        // Only log significant events — skip temp/hidden files
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard !filename.hasPrefix(".") && !filename.hasPrefix("~") else { return }

        auditCallback(.fileWritten, [
            "path": filename,   // only filename, not full path, for privacy
            "operation": operation
        ])
    }
}
