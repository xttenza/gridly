import SwiftUI
import CSCore
import CSAuth
import CSWorkspace

// MARK: - CompanyProfileWizardView

/// Step-by-step wizard that connects a WorkspaceProfile to a Microsoft company tenant.
/// Presented as a sheet from ProfileCardView / CreateProfileView.
///
/// Flow:
///   Email entry → Tenant discovery → Company Portal check → Privacy disclosure → Sign-in → Done
public struct CompanyProfileWizardView: View {

    // MARK: - Input

    /// The profile being configured. Updated with CompanyProfileConfig on completion.
    @Binding var profile: WorkspaceProfile

    var onComplete: (CompanyProfileConfig) -> Void
    var onCancel: () -> Void

    // MARK: - Environment

    /// Azure AD client ID registered for this Gridly installation.
    /// Injected by WorkspaceDashboardView via `.environment(\.entraClientID, …)`.
    /// Falls back to the generic Microsoft Office ID when unconfigured.
    @Environment(\.entraClientID) private var clientID

    // MARK: - State

    @StateObject private var manager = CompanyProfileManager()
    @State private var email: String = ""
    @State private var showPrivacyDetail = false

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Group {
                switch manager.step {
                case .idle:
                    emailStepView
                case .discoveringTenant:
                    progressView(message: "Looking up your organisation…")
                case .tenantFound(let info):
                    tenantConfirmView(info: info)
                case .checkingPortal:
                    progressView(message: "Checking for Company Portal…")
                case .portalMissing:
                    portalMissingView
                case .awaitingConsent(let info):
                    consentView(info: info)
                case .authenticating:
                    progressView(message: "Signing in with your work account…")
                case .complete(let config):
                    completeView(config: config)
                case .failed(let message):
                    failureView(message: message)
                }
            }
            .navigationTitle("Connect Work Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        manager.reset()
                        onCancel()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: - Step 1: Email entry

    private var emailStepView: some View {
        WizardPage(
            icon: "building.2.fill",
            iconColor: .blue,
            title: "Connect a Work Account",
            subtitle: "Enter your work email address to find your organisation's Microsoft tenant."
        ) {
            VStack(spacing: 16) {
                TextField("work@company.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onSubmit { submitEmail() }

                Button(action: submitEmail) {
                    Label("Find Organisation", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.trimmingCharacters(in: .whitespaces).count < 6
                          || !email.contains("@"))
            }

            infoBox(
                icon: "info.circle",
                color: .secondary,
                text: "No data is sent to Gridly. Discovery uses Microsoft's own public API."
            )
        }
    }

    // MARK: - Step 2: Tenant confirmation

    private func tenantConfirmView(info: TenantInfo) -> some View {
        WizardPage(
            icon: "checkmark.shield.fill",
            iconColor: .green,
            title: "Organisation Found",
            subtitle: "We found the following Microsoft tenant for your email domain."
        ) {
            VStack(spacing: 0) {
                tenantRow(label: "Organisation", value: info.displayName)
                Divider()
                tenantRow(label: "Domain", value: info.domain)
                Divider()
                tenantRow(label: "Tenant ID", value: String(info.tenantID.prefix(8)) + "…")
                if info.requiresConditionalAccess {
                    Divider()
                    tenantRow(
                        label: "Conditional Access",
                        value: "Required",
                        valueColor: .orange
                    )
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button("Not my organisation") {
                    email = ""
                    manager.reset()
                }
                .buttonStyle(.bordered)

                Button("This is correct →") {
                    Task { await manager.checkCompanyPortal(for: info) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 3: Portal missing

    private var portalMissingView: some View {
        WizardPage(
            icon: "exclamationmark.triangle.fill",
            iconColor: .orange,
            title: "Company Portal Required",
            subtitle: "Gridly uses Microsoft Company Portal as a secure SSO broker. It needs to be installed before you can connect."
        ) {
            VStack(spacing: 12) {
                featureRow(
                    icon: "lock.shield.fill", color: .blue,
                    title: "Why Company Portal?",
                    detail: "It stores your work credentials in the Secure Enclave — a hardware chip on your Mac. Gridly never touches your work password or PRT token."
                )
                featureRow(
                    icon: "person.badge.shield.checkmark.fill", color: .green,
                    title: "Only for work apps",
                    detail: "Company Portal handles SSO for Microsoft 365 apps only. Your personal apps and data are not affected."
                )
            }

            HStack(spacing: 12) {
                Button("Open App Store →") {
                    manager.openPortalInstallPage()
                }
                .buttonStyle(.borderedProminent)

                Button("Check again") {
                    if case .tenantFound(let info) = manager.step {
                        Task { await manager.checkCompanyPortal(for: info) }
                    } else {
                        Task { await manager.refreshPortalStatus() }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Step 4: Privacy consent

    private func consentView(info: TenantInfo) -> some View {
        let caps = CompanyProfileConfig.capabilities(for: .ssoOnly)
        return WizardPage(
            icon: "hand.raised.fill",
            iconColor: .indigo,
            title: "What Your Company Can See",
            subtitle: "Before you sign in, review exactly what \(info.displayName) can and cannot access on your Mac."
        ) {
            HStack(alignment: .top, spacing: 16) {
                // Can do
                VStack(alignment: .leading, spacing: 8) {
                    Label("Company **can**", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    ForEach(caps.canDo, id: \.self) { item in
                        Label(item, systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .imageScale(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Cannot do
                VStack(alignment: .leading, spacing: 8) {
                    Label("Company **cannot**", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    ForEach(caps.cannotDo, id: \.self) { item in
                        Label(item, systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .imageScale(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            Button("I understand — Sign in with \(info.displayName)") {
                Task {
                    guard let window = NSApp.keyWindow else { return }
                    _ = await manager.authenticate(
                        tenantInfo: info,
                        loginHint: email,
                        clientID: clientID,
                        presentingWindow: window
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
    }

    // MARK: - Step 5: Complete

    private func completeView(config: CompanyProfileConfig) -> some View {
        WizardPage(
            icon: "checkmark.seal.fill",
            iconColor: .green,
            title: "Work Account Connected",
            subtitle: "Gridly is now set up to use broker SSO for this profile. Microsoft 365 apps will sign in automatically."
        ) {
            VStack(spacing: 0) {
                tenantRow(label: "Organisation", value: config.tenantDisplayName)
                Divider()
                tenantRow(label: "Domain",       value: config.tenantDomain)
                Divider()
                tenantRow(label: "Mode",         value: config.tierLabel, valueColor: .green)
                Divider()
                tenantRow(
                    label: "Device in Entra ID",
                    value: config.isDeviceRegistered ? "Registered" : "Pending…",
                    valueColor: config.isDeviceRegistered ? .green : .secondary
                )
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            Button("Done") {
                onComplete(config)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    // MARK: - Failure

    private func failureView(message: String) -> some View {
        WizardPage(
            icon: "xmark.circle.fill",
            iconColor: .red,
            title: "Something Went Wrong",
            subtitle: message
        ) {
            HStack(spacing: 12) {
                Button("Try Again") {
                    manager.reset()
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    manager.reset()
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Progress

    private func progressView(message: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.4)
                .padding(.top, 60)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sub-views

    private func tenantRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(valueColor)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func featureRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func infoBox(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func submitEmail() {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@") else { return }
        Task { await manager.discoverTenant(email: trimmed) }
    }
}

// WizardPage is defined in WizardPage.swift (shared across wizard views)
