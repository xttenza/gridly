import SwiftUI
import CSCore
import CSWorkspace

// MARK: - ProfileCardView

/// A card representing one WorkspaceProfile. Shows mount state, account info,
/// passphrase unlock UI, and quick-launch buttons for managed apps.
public struct ProfileCardView: View {

    public let profile: WorkspaceProfile
    @ObservedObject public var profileManager: ProfileManager

    /// Bound to the parent view — sheets must present from outside LazyVGrid on macOS.
    @Binding var appLaunchProfile: WorkspaceProfile?
    @Binding var editProfile: WorkspaceProfile?

    @State private var passphrase = ""
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirm = false
    @FocusState private var passphraseFocused: Bool

    private var isMounted: Bool { profileManager.isMounted(profile) }
    private var mountState: ProfileMountState { profileManager.mountStates[profile.id] ?? .init() }

    public init(profile: WorkspaceProfile,
                profileManager: ProfileManager,
                appLaunchProfile: Binding<WorkspaceProfile?>,
                editProfile: Binding<WorkspaceProfile?>) {
        self.profile = profile
        self.profileManager = profileManager
        self._appLaunchProfile = appLaunchProfile
        self._editProfile = editProfile
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Divider().padding(.vertical, 10)
            if isMounted {
                mountedContent
            } else {
                lockedContent
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isMounted ? profile.color.swiftUIColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(isMounted ? 0.08 : 0.04), radius: isMounted ? 8 : 4, y: 2)
        .confirmationDialog(
            "Delete '\(profile.name)'?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Profile & All Data", role: .destructive) {
                Task { try? await profileManager.deleteProfile(profile) }
            }
        } message: {
            Text("The encrypted volume and all data inside it will be permanently erased. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 10) {
            // Color dot + lock indicator
            ZStack {
                Circle()
                    .fill(profile.color.swiftUIColor.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: isMounted ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(1)
                if !profile.accountIdentifier.isEmpty {
                    Text(profile.accountIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No account configured")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Status badge
            statusBadge

            // Context menu
            Menu {
                if isMounted {
                    Button("Launch Apps…") { appLaunchProfile = profile }
                    Button("Lock Profile") { Task { try? await profileManager.unmount(profile) } }
                    Divider()
                }
                Button("Edit Profile…") { editProfile = profile }
                Divider()
                Button("Delete Profile…", role: .destructive) { showingDeleteConfirm = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
    }

    private var statusBadge: some View {
        Group {
            if isMounted {
                Label("Unlocked", systemImage: "checkmark.shield.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(profile.color.swiftUIColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(profile.color.swiftUIColor.opacity(0.12), in: Capsule())
            } else {
                Label("Locked", systemImage: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    // MARK: - Mounted Content

    private var mountedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Running-apps summary
            let running = mountState.runningAppBundleIDs
            if !running.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "app.fill")
                        .font(.caption)
                        .foregroundStyle(profile.color.swiftUIColor)
                    Text("\(running.count) app\(running.count == 1 ? "" : "s") running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Quick-launch row (first 4 installed apps)
            let statuses = profileManager.appStatuses(for: profile).filter(\.isInstalled).prefix(4)
            if !statuses.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(statuses)) { status in
                        quickLaunchButton(status)
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Button {
                    appLaunchProfile = profile
                } label: {
                    Label("All Apps", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { try? await profileManager.unmount(profile) }
                } label: {
                    Label("Lock", systemImage: "lock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
    }

    private func quickLaunchButton(_ status: ProfileAppStatus) -> some View {
        Button {
            try? profileManager.launchApp(status.app, in: profile)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: status.app.iconSystemName)
                    .font(.system(size: 20))
                    .foregroundStyle(profile.color.swiftUIColor)
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text(status.app.displayName.components(separatedBy: " ").last ?? status.app.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help("Launch \(status.app.displayName) in \(profile.name)")
    }

    // MARK: - Locked Content

    private var lockedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter passphrase to unlock")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .focused($passphraseFocused)
                .onSubmit { Task { await unlock() } }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await unlock() }
            } label: {
                Group {
                    if isUnlocking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Unlocking…")
                        }
                    } else {
                        Label("Unlock", systemImage: "lock.open")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(profile.color.swiftUIColor)
            .disabled(passphrase.isEmpty || isUnlocking)
        }
        .onAppear { passphraseFocused = false }
    }

    private func unlock() async {
        isUnlocking = true
        errorMessage = nil
        do {
            try await profileManager.mount(profile, passphrase: passphrase)
            passphrase = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isUnlocking = false
    }
}

