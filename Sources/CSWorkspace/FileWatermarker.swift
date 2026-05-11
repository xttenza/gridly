import Foundation
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "FileWatermarker")

/// Applies metadata-based watermarks to files in the workspace volume.
/// For PDFs and Office docs this writes to standard metadata fields.
/// For all files it stamps an extended attribute as the ground-truth marker.
public final class FileWatermarker: Sendable {

    public struct WatermarkMetadata: Codable, Sendable {
        public let userPrincipalName: String
        public let tenantID: String
        public let timestamp: Date
        public let sessionID: UUID
        public let deviceSerialNumber: String
    }

    private let metadata: WatermarkMetadata
    private static let xattrKey = "com.gridly.watermark"

    public init(metadata: WatermarkMetadata) {
        self.metadata = metadata
    }

    // MARK: - Apply

    /// Stamp an extended attribute on a file — works for any file type.
    /// The xattr survives copy if the destination filesystem supports xattrs.
    public func applyXAttr(to url: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, Self.xattrKey, bytes.baseAddress!, bytes.count, 0, 0)
        }
        guard result == 0 else {
            throw CSError.internalError("setxattr failed: errno \(errno)")
        }
    }

    /// Read back a watermark extended attribute.
    public func readXAttr(from url: URL) throws -> WatermarkMetadata? {
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        let len = getxattr(url.path, Self.xattrKey, &buf, bufSize, 0, 0)
        guard len > 0 else { return nil }
        let data = Data(buf.prefix(len))
        return try JSONDecoder().decode(WatermarkMetadata.self, from: data)
    }

    /// Apply quarantine flag so files opened outside workspace get a Gatekeeper warning.
    public func applyQuarantine(to url: URL) {
        // com.apple.quarantine — standard macOS quarantine mechanism
        let quarantineValue = "0083;00000000;Gridly;"
        if let data = quarantineValue.data(using: .utf8) {
            data.withUnsafeBytes { bytes in
                _ = setxattr(url.path, "com.apple.quarantine", bytes.baseAddress!, bytes.count, 0, 0)
            }
        }
    }

    /// Batch-watermark all files in a directory (async, uses a task group).
    public func watermarkDirectory(_ directoryURL: URL) async throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        await withThrowingTaskGroup(of: Void.self) { group in
            for case let fileURL as URL in enumerator {
                group.addTask { [self] in
                    try self.applyXAttr(to: fileURL)
                }
            }
        }
        log.info("Watermarked directory: \(directoryURL.lastPathComponent, privacy: .public)")
    }
}
