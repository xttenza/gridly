import SwiftUI

// MARK: - AllAppsView (middle column for .apps tab)

struct AllAppsView: View {
    @EnvironmentObject private var profileManager: ProfileManager

    @State private var searchText = ""
    @State private var launchedApps: Set<String> = []
    @State private var launchError: String?

    private var activeProfile: Profile? { profileManager.activeProfile }

    private var filteredApps: [ManagedApp] {
        let all = ManagedApp.all
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let error = launchError {
                    errorBanner(error)
                        .padding(.horizontal, 20)
                }

                // Active profile selector hint
                activeProfileBanner
                    .padding(.horizontal, 20)

                // Apps grid
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(filteredApps) { app in
                        AllAppCard(
                            app: app,
                            profile: activeProfile,
                            launched: launchedApps.contains(app.id)
                        ) {
                            launch(app)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .padding(.top, 20)
        }
        .navigationTitle("Apps")
        .searchable(text: $searchText, prompt: "Search apps…")
    }

    // MARK: - Active Profile Banner

    private var activeProfileBanner: some View {
        Group {
            if let profile = activeProfile {
                HStack(spacing: 12) {
                    Circle()
                        .fill(profile.color.gradient)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.white)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launching as")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(profile.name)
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    Text(profile.accountIdentifier.isEmpty ? "No account" : profile.accountIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(14)
                .background(profile.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(profile.color.opacity(0.2), lineWidth: 1)
                )
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No active profile — go to Profiles to activate one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Error Banner

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

    // MARK: - Launch

    private func launch(_ app: ManagedApp) {
        let account = activeProfile?.accountIdentifier ?? ""
        var urlString: String?

        switch app.bundleID {
        case "com.microsoft.teams2":
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
                    UIApplication.shared.open(web)
                    launchedApps.insert(app.id)
                } else {
                    launchError = "\(app.displayName) could not be opened."
                }
            }
        }
    }
}

// MARK: - AllAppCard

struct AllAppCard: View {
    let app: ManagedApp
    let profile: Profile?
    let launched: Bool
    let onLaunch: () -> Void

    private var installed: Bool { app.isInstalled() }
    private var accent: Color { profile?.color ?? .blue }

    var body: some View {
        VStack(spacing: 12) {
            // Icon
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(accent.opacity(0.1))
                    .frame(height: 72)
                    .overlay {
                        Image(systemName: app.iconSystemName)
                            .font(.system(size: 30))
                            .foregroundStyle(accent)
                    }

                if launched {
                    Circle()
                        .fill(.green)
                        .frame(width: 16, height: 16)
                        .overlay { Circle().stroke(.background, lineWidth: 2) }
                        .offset(x: 5, y: -5)
                }
            }

            // Name + availability
            VStack(spacing: 4) {
                Text(app.displayName)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Circle()
                        .fill(installed ? .green : .secondary)
                        .frame(width: 6, height: 6)
                    Text(installed ? "Installed" : "Web fallback")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(installed ? .green : .secondary)
                }
            }

            // Launch button
            Button(action: onLaunch) {
                HStack(spacing: 6) {
                    if launched {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                    }
                    Text(launched ? "Opened" : "Open")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(launched ? .green : accent)
            .controlSize(.small)
            .disabled(launched)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}
