import SwiftUI
import CSCore
import CSWorkspace

// MARK: - ProfileSwitcherView

/// Top-level view for the Profiles tab.
/// Shows all configured workspace profiles as cards; lets the user create new ones,
/// mount/unmount them, and launch apps inside isolated contexts.
public struct ProfileSwitcherView: View {

    @ObservedObject public var profileManager: ProfileManager
    @State private var showingCreate = false

    /// Lifted sheet state — sheets inside LazyVGrid cannot present reliably on macOS.
    /// The ProfileSwitcherView owns these and passes bindings down to each card.
    @State private var appLaunchProfile: WorkspaceProfile?
    @State private var editProfile: WorkspaceProfile?

    public init(profileManager: ProfileManager) {
        self.profileManager = profileManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingCreate) {
            CreateProfileView(profileManager: profileManager)
        }
        .sheet(item: $appLaunchProfile) { profile in
            ProfileAppLauncherView(profile: profile, profileManager: profileManager)
        }
        .sheet(item: $editProfile) { profile in
            EditProfileView(profile: profile, profileManager: profileManager)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace Profiles")
                    .font(.title2.weight(.semibold))
                Text("Each profile runs in a fully isolated encrypted context — separate accounts, data, and sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingCreate = true
            } label: {
                Label("New Profile", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if profileManager.profiles.isEmpty {
            emptyState
        } else {
            ScrollView {
                profileGrid
                    .padding(20)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.badge.shield.checkmark.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("No Workspace Profiles")
                    .font(.title3.weight(.semibold))
                Text("Create a profile to run managed apps with completely\nisolated accounts, sessions, and data storage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Create First Profile") {
                showingCreate = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Isolation diagram
            isolationDiagram
                .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var profileGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
            spacing: 16
        ) {
            ForEach(profileManager.profiles) { profile in
                ProfileCardView(
                    profile: profile,
                    profileManager: profileManager,
                    appLaunchProfile: $appLaunchProfile,
                    editProfile: $editProfile
                )
            }
        }
    }

    /// Visual explanation of profile isolation — shown in the empty state.
    private var isolationDiagram: some View {
        HStack(spacing: 0) {
            diagramColumn(color: .blue, label: "Work Profile",
                          items: ["Contoso Teams", "Outlook Work", "Work OneDrive"])
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .frame(width: 60)
            diagramColumn(color: .purple, label: "Client Profile",
                          items: ["Client Slack", "Client Chrome", "Client Drive"])
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 520)
    }

    private func diagramColumn(color: Color, label: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: "person.crop.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                HStack(spacing: 6) {
                    Circle().fill(color.opacity(0.3)).frame(width: 6, height: 6)
                    Text(item).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
