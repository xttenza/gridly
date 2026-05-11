import SwiftUI

// MARK: - AuditLogView (middle column for .auditLog tab)

struct AuditLogView: View {
    @EnvironmentObject private var profileManager: ProfileManager
    @StateObject private var log = AuditLog.shared

    @State private var searchText = ""
    @State private var selectedFilter: AuditEvent.Category? = nil

    private var filteredEvents: [AuditEvent] {
        log.events
            .filter { event in
                if let f = selectedFilter, event.category != f { return false }
                if !searchText.isEmpty,
                   !event.message.localizedCaseInsensitiveContains(searchText),
                   !event.profileName.localizedCaseInsensitiveContains(searchText) {
                    return false
                }
                return true
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            filterBar

            Divider()

            if filteredEvents.isEmpty {
                emptyState
            } else {
                List(filteredEvents) { event in
                    AuditEventRow(event: event)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Audit Log")
        .searchable(text: $searchText, prompt: "Search log…")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    log.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(log.events.isEmpty)
            }
        }
        .onAppear {
            // Seed some demo events if empty
            if log.events.isEmpty {
                AuditLog.shared.seedDemo(profiles: profileManager.profiles)
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", category: nil)
                ForEach(AuditEvent.Category.allCases, id: \.self) { cat in
                    filterChip(label: cat.displayName, category: cat)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func filterChip(label: String, category: AuditEvent.Category?) -> some View {
        let active = selectedFilter == category
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedFilter = category
            }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    active ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Events")
                .font(.title3.weight(.semibold))
            Text("Activity will appear here as you use Gridly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AuditEventRow

struct AuditEventRow: View {
    let event: AuditEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Category icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(event.category.color.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: event.category.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(event.category.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(event.message)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if !event.profileName.isEmpty {
                        Label(event.profileName, systemImage: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(event.timestamp.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - AuditEvent model

struct AuditEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: Category
    let message: String
    let profileName: String

    enum Category: String, CaseIterable {
        case profileSwitch = "profile_switch"
        case appLaunch     = "app_launch"
        case security      = "security"
        case system        = "system"

        var displayName: String {
            switch self {
            case .profileSwitch: return "Profile"
            case .appLaunch:     return "App Launch"
            case .security:      return "Security"
            case .system:        return "System"
            }
        }

        var icon: String {
            switch self {
            case .profileSwitch: return "person.2.badge.gearshape.fill"
            case .appLaunch:     return "arrow.up.right.square.fill"
            case .security:      return "lock.shield.fill"
            case .system:        return "gearshape.fill"
            }
        }

        var color: Color {
            switch self {
            case .profileSwitch: return .indigo
            case .appLaunch:     return .blue
            case .security:      return .orange
            case .system:        return .secondary
            }
        }
    }
}

// MARK: - AuditLog store

@MainActor
final class AuditLog: ObservableObject {
    static let shared = AuditLog()

    @Published private(set) var events: [AuditEvent] = []

    func add(_ event: AuditEvent) {
        events.insert(event, at: 0)
        if events.count > 500 { events = Array(events.prefix(500)) }
    }

    func record(category: AuditEvent.Category, message: String, profile: String = "") {
        add(AuditEvent(timestamp: Date(), category: category, message: message, profileName: profile))
    }

    func clear() {
        events.removeAll()
    }

    func seedDemo(profiles: [Profile]) {
        let names = profiles.map(\.name)
        let p0 = names.first ?? "Work"
        let p1 = names.dropFirst().first ?? "Personal"

        let demo: [(Double, AuditEvent.Category, String, String)] = [
            (-10,  .system,        "Gridly started",                             ""),
            (-120, .profileSwitch, "Activated profile \"\(p0)\"",                p0),
            (-180, .appLaunch,     "Opened Microsoft Teams",                      p0),
            (-240, .appLaunch,     "Opened Microsoft Outlook",                    p0),
            (-360, .security,      "Compliance check: Compliant",                 ""),
            (-500, .profileSwitch, "Activated profile \"\(p1)\"",                p1),
            (-540, .appLaunch,     "Opened Slack",                                p1),
            (-700, .system,        "Profile list refreshed (3 profiles)",          ""),
            (-900, .security,      "VPN status: Disconnected",                    ""),
        ]

        for (offset, cat, msg, prof) in demo {
            add(AuditEvent(
                timestamp: Date(timeIntervalSinceNow: offset),
                category: cat,
                message: msg,
                profileName: prof
            ))
        }
    }
}
