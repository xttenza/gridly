import SwiftUI

// MARK: - ProfileDetailView (right column)

struct ProfileDetailView: View {

    let profile: Profile
    @EnvironmentObject private var profileManager: ProfileManager
    @State private var launchError: String?
    @State private var launchedApps: Set<String> = []

    private var isActive: Bool { profileManager.activeProfileID == profile.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                profileHeader
                if let error = launchError { errorBanner(error) }
                isolationInfoCard
                appsGrid
            }
            .padding(24)
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
    }

    // MARK: - Header card

    private var profileHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(profile.color.gradient)
                    .frame(width: 64, height: 64)
                    .shadow(color: profile.color.opacity(0.4), radius: 10, y: 4)
                Image(systemName: isActive ? "checkmark.shield.fill" : "person.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 26, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.title2.weight(.bold))
                Text(profile.accountIdentifier.isEmpty ? "No account configured" : profile.accountIdentifier)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isActive {
                    Label("Active workspace", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(profile.color)
                }
            }
            Spacer()

            if !isActive {
                Button {
                    profileManager.activate(profile)
                } label: {
                    Label("Activate", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .tint(profile.color)
            }
        }
        .padding(20)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Isolation info

    private var isolationInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Isolation on iPad", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(profile.color)

            Text("iOS already isolates every app in its own sandbox. Gridly adds **account-level isolation**: each profile tracks which Microsoft account is in use, and opens apps via dedicated deep-links tied to that identity.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                isolationPill("Keychain",  icon: "key.fill",            color: .blue)
                isolationPill("Sandboxed", icon: "lock.fill",           color: .green)
                isolationPill("Deep-Link", icon: "arrow.up.right.square", color: .purple)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private func isolationPill(_ label: String, icon: String, color: Color) -> some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Apps grid

    private var appsGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Managed Apps")
                .font(.title3.weight(.semibold))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 14)],
                spacing: 14
            ) {
                ForEach(ManagedApp.all) { app in
                    AppCell(
                        app: app,
                        profile: profile,
                        launched: launchedApps.contains(app.id),
                        onLaunch: { launch(app) }
                    )
                }
            }
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ msg: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(msg).font(.caption)
            Spacer()
            Button { launchError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    profileManager.activate(profile)
                } label: {
                    Label("Set as Active", systemImage: "checkmark.shield")
                }
                .disabled(isActive)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Launch

    private func launch(_ app: ManagedApp) {
        // Build account-scoped URL if app supports it
        let account = profile.accountIdentifier
        var urlString: String?

        switch app.bundleID {
        case "com.microsoft.teams2":
            // Teams supports login_hint parameter on web
            let hint = account.isEmpty ? "" : "?login_hint=\(account)"
            urlString = app.isInstalled()
                ? "msteams://"
                : "https://teams.microsoft.com\(hint)"
        case "com.microsoft.outlookipad":
            urlString = app.isInstalled() ? "ms-outlook://" : app.webURL
        default:
            urlString = app.isInstalled()
                ? (app.urlScheme.map { $0 + "://" })
                : app.webURL
        }

        guard let str = urlString, let url = URL(string: str) else {
            launchError = "Could not build URL for \(app.displayName)"
            return
        }

        UIApplication.shared.open(url) { success in
            Task { @MainActor in
                if success {
                    launchedApps.insert(app.id)
                } else if let web = URL(string: app.webURL) {
                    // App not installed — open web fallback
                    UIApplication.shared.open(web)
                    launchedApps.insert(app.id)
                } else {
                    launchError = "\(app.displayName) could not be opened."
                }
            }
        }
    }
}

// MARK: - AppCell

struct AppCell: View {
    let app: ManagedApp
    let profile: Profile
    let launched: Bool
    let onLaunch: () -> Void

    private var installed: Bool { app.isInstalled() }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(profile.color.opacity(0.1))
                    .frame(height: 64)
                    .overlay {
                        Image(systemName: app.iconSystemName)
                            .font(.system(size: 26))
                            .foregroundStyle(profile.color)
                    }

                if launched {
                    Circle()
                        .fill(.green)
                        .frame(width: 14, height: 14)
                        .overlay { Circle().stroke(.background, lineWidth: 2) }
                        .offset(x: 4, y: -4)
                }
            }

            Text(app.displayName)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            // Availability badge
            if installed {
                Text("Installed")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.12), in: Capsule())
            } else {
                Text("Web fallback")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }

            Button(action: onLaunch) {
                Text(launched ? "Opened ✓" : "Open")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(launched ? .green : profile.color)
            .controlSize(.small)
            .disabled(launched)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}
