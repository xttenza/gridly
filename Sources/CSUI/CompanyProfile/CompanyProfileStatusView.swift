import SwiftUI
import CSCore
import CSWorkspace

// MARK: - CompanyProfileStatusView

/// Compact status badge shown on a profile card when a company (work) account
/// is connected, or a call-to-action button when one is not.
///
/// Usage:
/// ```swift
/// CompanyProfileStatusView(
///     profile: $profile,
///     profileManager: profileManager
/// )
/// ```
public struct CompanyProfileStatusView: View {

    @Binding var profile: WorkspaceProfile
    @ObservedObject public var profileManager: ProfileManager

    @State private var showWizard = false
    @State private var showUpgradeWizard = false
    @State private var showDisconnectConfirm = false

    public init(profile: Binding<WorkspaceProfile>, profileManager: ProfileManager) {
        self._profile = profile
        self.profileManager = profileManager
    }

    public var body: some View {
        Group {
            if let config = profile.companyConfig {
                connectedView(config: config)
            } else {
                connectButton
            }
        }
        .sheet(isPresented: $showWizard) {
            CompanyProfileWizardView(
                profile: $profile,
                onComplete: { config in
                    var updated = profile
                    updated.companyConfig = config
                    // Auto-fill the profile's account identifier from the signed-in UPN
                    if let upn = config.userPrincipalName, !upn.isEmpty {
                        updated.accountIdentifier = upn
                    }
                    profileManager.updateProfile(updated)
                    profile = updated
                },
                onCancel: { showWizard = false }
            )
        }
        .sheet(isPresented: $showUpgradeWizard) {
            if var config = profile.companyConfig {
                UserEnrollmentWizardView(
                    config: Binding(
                        get: { profile.companyConfig ?? config },
                        set: { config = $0 }
                    ),
                    onComplete: { upgraded in
                        var updated = profile
                        updated.companyConfig = upgraded
                        profileManager.updateProfile(updated)
                        profile = updated
                    },
                    onCancel: { showUpgradeWizard = false }
                )
            }
        }
        .confirmationDialog(
            "Disconnect Work Account?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                disconnectCompanyProfile()
            }
        } message: {
            Text("Your Microsoft SSO session will be removed from this profile. Work apps will need to sign in again.")
        }
    }

    // MARK: - Connected state

    private func connectedView(config: CompanyProfileConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main status badge row
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: ssoIcon(config: config))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ssoColor(config: config))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(config.tenantDisplayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(statusLabel(config: config))
                            .font(.system(size: 9))
                            .foregroundStyle(ssoColor(config: config))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(ssoColor(config: config).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

                Spacer()

                // Disconnect button
                Button {
                    showDisconnectConfirm = true
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Disconnect work account")
            }

            // Tier 2 upgrade prompt (only shown for Tier 1 profiles)
            if config.tier == .ssoOnly {
                Button {
                    showUpgradeWizard = true
                } label: {
                    Label("Upgrade to User Enrollment…", systemImage: "arrow.up.circle.fill")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.indigo)
                .help("Upgrade to full MDM management — scoped to your work volume only")
            }

            // VPN indicator (Tier 2 only)
            if config.tier == .userEnrolled, let vpn = config.vpnEndpoint {
                HStack(spacing: 5) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text("VPN: \(vpn)")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    // MARK: - Not-connected state

    private var connectButton: some View {
        Button {
            showWizard = true
        } label: {
            Label("Connect Work Account", systemImage: "building.2.fill")
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.blue)
        .help("Connect a Microsoft work or school account to enable SSO for this profile")
    }

    // MARK: - Helpers

    private func ssoIcon(config: CompanyProfileConfig) -> String {
        if !config.isAuthenticated             { return "exclamationmark.shield.fill" }
        if config.tier == .userEnrolled        { return "checkmark.shield.fill" }
        if config.isDeviceRegistered           { return "checkmark.shield.fill" }
        return "shield.fill"
    }

    private func ssoColor(config: CompanyProfileConfig) -> Color {
        if !config.isAuthenticated             { return .orange }
        if config.tier == .userEnrolled        { return .indigo }
        if config.isDeviceRegistered           { return .green }
        return .blue
    }

    private func statusLabel(config: CompanyProfileConfig) -> String {
        if !config.isAuthenticated             { return "Re-auth required" }
        if config.tier == .userEnrolled        { return "User Enrolled · MDM managed" }
        if config.isDeviceRegistered           { return "SSO · Entra registered" }
        return "SSO active"
    }

    private func disconnectCompanyProfile() {
        guard let config = profile.companyConfig else { return }
        // Sign out via a temporary manager (fire-and-forget; no wizard state needed)
        let mgr = CompanyProfileManager()
        mgr.disconnect(config: config)
        var updated = profile
        updated.companyConfig = nil
        updated.accountIdentifier = ""
        profileManager.updateProfile(updated)
        profile = updated
    }
}

// MARK: - CompanyProfileSSOBanner

/// Horizontal info strip shown at the top of the mounted-profile view when SSO
/// is active, reminding the user which tenant the profile is connected to.
public struct CompanyProfileSSOBanner: View {

    public let config: CompanyProfileConfig

    public init(config: CompanyProfileConfig) {
        self.config = config
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "building.2.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
            Text("Work SSO: \(config.tenantDisplayName)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.blue)
            Spacer()
            if config.isDeviceRegistered {
                Label("Entra ID", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}
