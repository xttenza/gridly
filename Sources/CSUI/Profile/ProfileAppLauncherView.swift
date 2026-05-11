import SwiftUI
import CSCore
import CSWorkspace

// MARK: - ProfileAppLauncherView

/// Sheet shown when the user taps "All Apps" on a mounted profile.
/// Displays all managed apps with install state and a Launch button each.
public struct ProfileAppLauncherView: View {

    public let profile: WorkspaceProfile
    @ObservedObject public var profileManager: ProfileManager
    @Environment(\.dismiss) private var dismiss

    @State private var launchError: String?
    @State private var recentlyLaunched: Set<String> = []

    private var statuses: [ProfileAppStatus] {
        profileManager.appStatuses(for: profile)
    }

    public init(profile: WorkspaceProfile, profileManager: ProfileManager) {
        self.profile = profile
        self.profileManager = profileManager
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Circle()
                    .fill(profile.color.swiftUIColor.gradient)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.headline)
                    Text("Select an app to launch in this isolated profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let error = launchError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption)
                    Spacer()
                    Button { launchError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.1))
            }

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    spacing: 12
                ) {
                    ForEach(statuses) { status in
                        appCell(status)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer: isolation reminder
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("Apps launched here run in an isolated HOME — they cannot access data from other profiles or your personal account.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 540, height: 520)
    }

    // MARK: - App Cell

    private func appCell(_ status: ProfileAppStatus) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // App icon placeholder
                RoundedRectangle(cornerRadius: 16)
                    .fill(status.isInstalled
                          ? profile.color.swiftUIColor.opacity(0.12)
                          : Color.secondary.opacity(0.08))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: status.app.iconSystemName)
                            .font(.system(size: 28))
                            .foregroundStyle(status.isInstalled
                                             ? profile.color.swiftUIColor
                                             : .secondary)
                    }

                // Running indicator
                if recentlyLaunched.contains(status.app.bundleID) {
                    Circle()
                        .fill(.green)
                        .frame(width: 12, height: 12)
                        .overlay { Circle().stroke(.background, lineWidth: 2) }
                }
            }

            Text(status.app.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Isolation quality badge
            let iso = IsolatedAppLauncher.isolationDescription(for: status.app.bundleID)
            Label(iso.label, systemImage: iso.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isoColor(iso.label))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isoColor(iso.label).opacity(0.12), in: Capsule())
                .help(iso.detail)

            if status.isInstalled {
                Button {
                    launch(status.app)
                } label: {
                    Text(recentlyLaunched.contains(status.app.bundleID) ? "Launched ✓" : "Launch")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(recentlyLaunched.contains(status.app.bundleID)
                      ? .green
                      : profile.color.swiftUIColor)
                .controlSize(.small)
                .disabled(recentlyLaunched.contains(status.app.bundleID))
            } else {
                Text("Not installed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func isoColor(_ label: String) -> Color {
        switch label {
        case "Full":     return .green
        case "Keychain": return .blue
        default:         return .orange
        }
    }

    // MARK: - Launch

    private func launch(_ app: ManagedApp) {
        do {
            try profileManager.launchApp(app, in: profile)
            recentlyLaunched.insert(app.bundleID)
        } catch {
            launchError = error.localizedDescription
        }
    }
}

