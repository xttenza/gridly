import SwiftUI
import CSCore
import CSAudit

// MARK: - AuditLogView

/// Displays the signed local audit log — the tamper-evident chain of all
/// workspace events (session, app launches, profile mount/unmount, compliance, etc.).
public struct AuditLogView: View {

    private let auditLogger: AuditLogger

    @State private var records: [SignedAuditRecord] = []
    @State private var isLoading = false
    @State private var filter: FilterCategory = .all
    @State private var searchText = ""

    public init(auditLogger: AuditLogger) {
        self.auditLogger = auditLogger
    }

    // MARK: - Filter

    enum FilterCategory: String, CaseIterable, Identifiable {
        case all       = "All"
        case profiles  = "Profiles"
        case session   = "Session"
        case apps      = "Apps"
        case policy    = "Policy"
        case security  = "Security"

        var id: String { rawValue }

        func matches(_ eventType: String) -> Bool {
            switch self {
            case .all:      return true
            case .profiles: return eventType.hasPrefix("profile")
            case .session:  return ["workspaceOpened","workspaceLocked","workspaceUnlocked",
                                    "workspaceWiped","sessionExpired","authenticationSuccess",
                                    "authenticationFailure","tokenRefreshed","mfaCompleted"].contains(eventType)
            case .apps:     return ["appLaunched","appTerminated"].contains(eventType)
            case .policy:   return ["policyUpdated","policyViolation","complianceChecked",
                                    "complianceChanged"].contains(eventType)
            case .security: return ["remoteWipeReceived","tamperDetected","vpnConnected",
                                    "vpnDisconnected","screenshotDetected","clipboardCopied",
                                    "clipboardCleared","clipboardBlocked"].contains(eventType)
            }
        }
    }

    // MARK: - Filtered Data

    private var filteredRecords: [SignedAuditRecord] {
        records.filter { record in
            guard filter.matches(record.eventType) else { return false }
            guard !searchText.isEmpty else { return true }
            let q = searchText.lowercased()
            return record.eventType.lowercased().contains(q)
                || record.payloadJSON.lowercased().contains(q)
        }
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if isLoading {
                ProgressView("Loading audit log…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .task { await loadRecords() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audit Log")
                    .font(.title2.weight(.semibold))
                Text("\(records.count) signed entries · HMAC-SHA256 integrity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // Filter picker
            Picker("Filter", selection: $filter) {
                ForEach(FilterCategory.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            Button {
                Task { await loadRecords() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Log List

    private var logList: some View {
        List(filteredRecords, id: \.id) { record in
            AuditRowView(record: record)
                .listRowSeparator(.visible)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .font(.system(.caption, design: .monospaced))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty && filter == .all
                 ? "No audit events yet"
                 : "No matching events")
                .font(.headline)
            Text(searchText.isEmpty && filter == .all
                 ? "Events will appear here as you use the workspace."
                 : "Try a different filter or search term.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load

    private func loadRecords() async {
        isLoading = true
        records = (try? await auditLogger.fetchRecent(limit: 500)) ?? []
        isLoading = false
    }
}

// MARK: - AuditRowView

private struct AuditRowView: View {

    let record: SignedAuditRecord

    private var date: Date {
        Date(timeIntervalSince1970: record.loggedAt)
    }

    private var payload: [String: String] {
        guard let data = record.payloadJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon + colour
            Image(systemName: iconName(for: record.eventType))
                .font(.system(size: 14))
                .foregroundStyle(iconColor(for: record.eventType))
                .frame(width: 22, height: 22)
                .background(iconColor(for: record.eventType).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.eventType)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(date.formatted(.dateTime.month().day().hour().minute().second()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                // Key payload fields
                let dict = payload
                if !dict.isEmpty {
                    let summary = dict
                        .filter { !["sessionID"].contains($0.key) }
                        .sorted { $0.key < $1.key }
                        .prefix(3)
                        .map { "\($0.key): \($0.value)" }
                        .joined(separator: "  ·  ")
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Icon helpers

    private func iconName(for eventType: String) -> String {
        switch eventType {
        case let t where t.hasPrefix("profile"):
            return t.contains("Mounted") || t.contains("mounted") ? "externaldrive.badge.checkmark"
                 : t.contains("Unmounted") || t.contains("unmounted") ? "externaldrive.badge.minus"
                 : t.contains("App") ? "app.badge.fill"
                 : t.contains("Deleted") || t.contains("deleted") ? "trash.fill"
                 : "person.2.badge.gearshape.fill"
        case "workspaceLocked":      return "lock.fill"
        case "workspaceUnlocked":    return "lock.open.fill"
        case "workspaceWiped":       return "exclamationmark.triangle.fill"
        case "appLaunched":          return "app.fill"
        case "policyUpdated":        return "checkmark.shield"
        case "complianceChecked":    return "checkmark.circle"
        case "tamperDetected":       return "exclamationmark.shield.fill"
        case "remoteWipeReceived":   return "icloud.and.arrow.down"
        case "clipboardBlocked":     return "clipboard.fill"
        case "vpnConnected":         return "network.badge.shield.half.filled"
        default:                     return "doc.text"
        }
    }

    private func iconColor(for eventType: String) -> Color {
        switch eventType {
        case let t where t.hasPrefix("profile"):
            return t.contains("deleted") || t.contains("Deleted") ? .red : .blue
        case "workspaceLocked":      return .orange
        case "workspaceUnlocked":    return .green
        case "workspaceWiped":       return .red
        case "tamperDetected":       return .red
        case "remoteWipeReceived":   return .red
        case "clipboardBlocked":     return .orange
        case "policyViolation":      return .orange
        case "appLaunched":          return .purple
        default:                     return .secondary
        }
    }
}
