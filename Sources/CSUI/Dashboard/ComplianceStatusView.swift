import SwiftUI
import CSCore

// MARK: - Compliance Status Card

struct ComplianceStatusCard: View {
    let state: ComplianceState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: state.systemImage)
                        .font(.title2)
                        .foregroundStyle(state.color)
                    Text(state.displayName)
                        .font(.headline)
                    Spacer()
                }

                Text(state.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if state.blocksWorkspace {
                    Button("View Requirements") {}
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                }
            }
        } label: {
            Label("Compliance", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
        }
    }
}

// MARK: - Security Status Card

struct SecurityStatusCard: View {
    let tamperOK: Bool
    let vpnActive: Bool
    let auditOK: Bool

    private var overallOK: Bool { tamperOK && auditOK }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                statusRow("App Integrity",    ok: tamperOK, detail: tamperOK ? "Verified" : "Check failed")
                statusRow("Audit Log",        ok: auditOK,  detail: auditOK  ? "Intact"   : "Tampered!")
                statusRow("VPN",              ok: vpnActive, detail: vpnActive ? "Connected" : "Not active")
            }
        } label: {
            Label("Security", systemImage: overallOK ? "lock.shield.fill" : "exclamationmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(overallOK ? Color.primary : Color.red)
        }
    }

    @ViewBuilder
    private func statusRow(_ label: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .font(.caption)
            Text(label)
                .font(.caption)
            Spacer()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(ok ? Color.secondary : Color.red)
        }
    }
}

// MARK: - Session Info Card

struct SessionInfoCard: View {
    let session: WorkspaceSession?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let session {
                    infoRow("User",       session.userPrincipalName)
                    infoRow("Tenant",     String(session.tenantID.prefix(8)) + "…")
                    infoRow("Active for", formatDuration(session.sessionDuration))
                    infoRow("Token exp.", formatExpiry(session.accessTokenExpiresAt))
                } else {
                    Text("No active session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Session", systemImage: "person.badge.shield.checkmark.fill")
                .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func formatExpiry(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        if remaining < 0 { return "Expired" }
        if remaining < 60 { return "< 1 min" }
        return "\(Int(remaining / 60))m"
    }
}

// MARK: - Full Compliance Detail View

public struct ComplianceDetailView: View {
    let report: ComplianceReport?
    let onRefresh: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let report {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Compliance Status")
                            .font(.title2.weight(.bold))
                        Text("Last checked: \(report.lastSyncDateTime.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh", action: onRefresh)
                        .buttonStyle(.bordered)
                }

                ComplianceStatusCard(state: report.complianceState)

                if !report.noncompliantReasons.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Issues to Resolve")
                            .font(.headline)

                        ForEach(report.noncompliantReasons) { reason in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(reason.displayName).font(.subheadline.weight(.medium))
                                    Text(reason.description).font(.caption).foregroundStyle(.secondary)
                                    if let url = reason.remediationURL {
                                        Link("Fix this →", destination: url)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView("Checking compliance…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(40)
            }

            Spacer()
        }
        .padding(20)
        .navigationTitle("Compliance")
    }
}
