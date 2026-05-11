import SwiftUI

// MARK: - RootView
// Three-column NavigationSplitView:  Sidebar | Profile list | Detail

struct RootView: View {

    @EnvironmentObject private var profileManager: ProfileManager
    @EnvironmentObject private var appState: AppState

    @State private var selectedTab: AppState.Tab   = .profiles
    @State private var selectedProfile: Profile?

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
        } content: {
            switch selectedTab {
            case .profiles:
                ProfileListView(selectedProfile: $selectedProfile)
            case .dashboard:
                DashboardContentView()
            case .apps:
                AllAppsView()
            case .auditLog:
                AuditLogView()
            case .settings:
                SettingsView()
            }
        } detail: {
            if selectedTab == .profiles, let profile = selectedProfile {
                ProfileDetailView(profile: profile)
            } else if selectedTab == .profiles {
                ProfilePlaceholderView()
            } else {
                EmptyView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Sidebar

struct SidebarView: View {

    @Binding var selectedTab: AppState.Tab
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                }
                .listRowBackground(
                    selectedTab == tab
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear
                )
            }
        }
        .navigationTitle("Gridly")
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { statusFooter }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(appState.sessionLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(appState.complianceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: appState.vpnActive ? "network.badge.shield.half.filled" : "network.slash")
                    .foregroundStyle(appState.vpnActive ? .blue : .secondary)
                    .font(.caption)
                Text(appState.vpnActive ? "VPN On" : "No VPN")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Placeholder (no profile selected)

struct ProfilePlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.badge.shield.checkmark.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Select a Profile")
                .font(.title3.weight(.semibold))
            Text("Choose a workspace profile to manage\nits apps and isolation settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
