import AppKit
import Combine
import os.log
import CSCore

private let log = Logger(subsystem: "com.gridly", category: "ClipboardGuard")

public final class ClipboardGuard: @unchecked Sendable {

    public struct Policy: Sendable {
        public var blockCorporateToPersonal: Bool
        public var watermarkCopiedText: Bool
        public var clearOnContextSwitch: Bool

        public static let strict = Policy(
            blockCorporateToPersonal: true,
            watermarkCopiedText: true,
            clearOnContextSwitch: true
        )

        public static let permissive = Policy(
            blockCorporateToPersonal: false,
            watermarkCopiedText: false,
            clearOnContextSwitch: false
        )
    }

    private var policy: Policy
    private var lastChangeCount: Int = 0
    private var timer: Timer?
    private let auditCallback: @Sendable (AuditEventType, [String: String]) -> Void
    private var previousFrontApp: NSRunningApplication?

    public init(
        policy: Policy = .strict,
        auditCallback: @escaping @Sendable (AuditEventType, [String: String]) -> Void
    ) {
        self.policy = policy
        self.auditCallback = auditCallback
    }

    // MARK: - Monitoring

    public func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount

        // 250ms poll: unnoticeable to users, fast enough to catch copy events
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)

        // Track app switching
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        log.info("ClipboardGuard started")
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        log.info("ClipboardGuard stopped")
    }

    public func updatePolicy(_ policy: Policy) {
        self.policy = policy
    }

    // MARK: - Policy

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let isCorporate = ManagedAppRegistry.shared.isManagedApp(bundleID: frontApp.bundleIdentifier ?? "")

        auditCallback(.clipboardCopied, [
            "app": frontApp.bundleIdentifier ?? "unknown",
            "isCorporate": isCorporate ? "true" : "false",
            "types": (pb.types?.map(\.rawValue) ?? []).joined(separator: ",")
        ])

        if policy.watermarkCopiedText && isCorporate {
            watermarkText(in: pb)
        }
    }

    @objc private func frontAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        let wasCorpApp = previousFrontApp.map { ManagedAppRegistry.shared.isManagedApp(bundleID: $0.bundleIdentifier ?? "") } ?? false
        let isPersonalApp = !ManagedAppRegistry.shared.isManagedApp(bundleID: app.bundleIdentifier ?? "")

        if policy.clearOnContextSwitch && wasCorpApp && isPersonalApp {
            clearClipboard(reason: "context_switch")
        }

        previousFrontApp = app
    }

    // MARK: - Actions

    /// Append an invisible Unicode watermark to any text on the clipboard.
    /// Uses zero-width space (U+200B) and zero-width non-joiner (U+200C)
    /// to encode a timestamp as binary — invisible in all editors.
    private func watermarkText(in pb: NSPasteboard) {
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }

        let stamp = Int(Date().timeIntervalSince1970)
        let bits = String(stamp, radix: 2)
        let invisible = bits.map { $0 == "1" ? "\u{200B}" : "\u{200C}" }.joined()

        pb.clearContents()
        pb.setString(text + invisible, forType: .string)
    }

    private func clearClipboard(reason: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("", forType: .string)

        auditCallback(.clipboardCleared, ["reason": reason])
        log.info("Clipboard cleared: \(reason, privacy: .public)")
    }
}

// ManagedAppRegistry is defined in CSCore/ManagedAppRegistry.swift
// and is available here via the CSCore import above.
