import SwiftUI

// MARK: - Dashboard (middle-column content for .dashboard tab)

struct DashboardContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var profileManager: ProfileManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status row
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    StatusCard(
                        title: "Session",
                        value: appState.sessionLabel,
                        icon: "person.badge.shield.checkmark.fill",
                        color: .green
                    )
                    StatusCard(
                        title: "Compliance",
                        value: appState.complianceLabel,
                        icon: "checkmark.shield.fill",
                        color: appState.complianceColor
                    )
                    StatusCard(
                        title: "VPN",
                        value: appState.vpnActive ? "Connected" : "Off",
                        icon: appState.vpnActive ? "network.badge.shield.half.filled" : "network.slash",
                        color: appState.vpnActive ? .blue : .secondary
                    )
                    StatusCard(
                        title: "Profiles",
                        value: "\(profileManager.profiles.count)",
                        icon: "person.2.badge.gearshape.fill",
                        color: .indigo
                    )
                }

                // Active profile card
                if let active = profileManager.activeProfile {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Active Profile")
                            .font(.headline)
                        HStack(spacing: 14) {
                            Circle()
                                .fill(active.color.gradient)
                                .frame(width: 48, height: 48)
                                .overlay {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundStyle(.white)
                                        .font(.system(size: 20, weight: .semibold))
                                }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(active.name).font(.title3.weight(.semibold))
                                Text(active.accountIdentifier.isEmpty ? "No account" : active.accountIdentifier)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .padding(18)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                }

                // Quick app launch
                VStack(alignment: .leading, spacing: 14) {
                    Text("Quick Launch")
                        .font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(ManagedApp.all.prefix(8)) { app in
                            QuickLaunchButton(app: app, profile: profileManager.activeProfile)
                        }
                    }
                }
                .padding(18)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
    }
}

// MARK: - StatusCard

struct StatusCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(color)
            Spacer()
            Text(value)
                .font(.title3.weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - QuickLaunchButton

struct QuickLaunchButton: View {
    let app: ManagedApp
    let profile: Profile?

    var body: some View {
        Button {
            let scheme = app.urlScheme.map { $0 + "://" } ?? app.webURL
            guard let url = URL(string: scheme) else { return }
            UIApplication.shared.open(url) { success in
                if !success, let web = URL(string: app.webURL) {
                    UIApplication.shared.open(web)
                }
            }
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 12)
                    .fill((profile?.color ?? .blue).opacity(0.1))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: app.iconSystemName)
                            .font(.system(size: 22))
                            .foregroundStyle(profile?.color ?? .blue)
                    }
                Text(app.displayName.components(separatedBy: " ").last ?? app.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
