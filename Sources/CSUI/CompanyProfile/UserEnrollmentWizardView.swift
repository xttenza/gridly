import SwiftUI
import CSCore
import CSWorkspace

// MARK: - UserEnrollmentWizardView

/// Guides the user through Apple User Enrollment (Tier 2 upgrade) from Tier 1 SSO.
///
/// Presented as a sheet from CompanyProfileStatusView when the user taps
/// "Upgrade to User Enrollment".
public struct UserEnrollmentWizardView: View {

    // MARK: - Input

    @Binding var config: CompanyProfileConfig
    var onComplete: (CompanyProfileConfig) -> Void
    var onCancel: () -> Void

    // MARK: - State

    @StateObject private var coordinator = UserEnrollmentCoordinator()
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Group {
                switch coordinator.step {
                case .idle, .checkingRequirements:
                    progressView(message: "Checking requirements…")

                case .awaitingConsent(let tenantName):
                    consentView(tenantName: tenantName)

                case .enrollingInCompanyPortal:
                    progressView(message: "Opening Company Portal…")

                case .detectingMDMProfile(let attempt):
                    detectingView(attempt: attempt)

                case .configuringVPN:
                    progressView(message: "Configuring per-profile VPN…")

                case .complete(let updatedConfig):
                    completeView(updatedConfig: updatedConfig)

                case .failed(let message):
                    failureView(message: message)
                }
            }
            .navigationTitle("Upgrade to User Enrollment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.reset()
                        onCancel()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 440)
        .task { await coordinator.startUpgrade(config: config) }
    }

    // MARK: - Consent

    private func consentView(tenantName: String) -> some View {
        let caps = CompanyProfileConfig.capabilities(for: .userEnrolled)
        return WizardPage(
            icon: "building.2.crop.circle.fill",
            iconColor: .indigo,
            title: "Upgrade to User Enrollment",
            subtitle: "This upgrades your \(tenantName) profile to full MDM management, scoped exclusively to your work volume."
        ) {
            // What changes vs Tier 1
            VStack(alignment: .leading, spacing: 10) {
                Label("What's new in Tier 2", systemImage: "arrow.up.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)

                HStack(alignment: .top, spacing: 16) {
                    // Can do
                    VStack(alignment: .leading, spacing: 6) {
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
                    VStack(alignment: .leading, spacing: 6) {
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
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            // How it works
            VStack(alignment: .leading, spacing: 8) {
                featureRow(
                    icon: "externaldrive.fill.badge.checkmark", color: .blue,
                    title: "Separate managed volume",
                    detail: "macOS creates a second encrypted APFS volume scoped to the MDM channel. Work apps, certificates, and data land there — never on your personal volume."
                )
                featureRow(
                    icon: "network.badge.shield.half.filled", color: .green,
                    title: "Per-profile VPN",
                    detail: "After enrollment, Gridly configures a VPN tunnel that activates only for this profile's apps. Your personal traffic is never routed through the work VPN."
                )
                featureRow(
                    icon: "creditcard.viewfinder", color: .orange,
                    title: "Synthetic device ID",
                    detail: "Apple presents your company's MDM with a synthetic serial number — they never learn your real hardware ID."
                )
            }

            Button("I understand — Enrol with \(tenantName)") {
                Task { await coordinator.beginEnrollment(config: config) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
    }

    // MARK: - Detecting

    private func detectingView(attempt: Int) -> some View {
        WizardPage(
            icon: "magnifyingglass.circle.fill",
            iconColor: .blue,
            title: "Waiting for Enrolment",
            subtitle: "Complete the enrolment steps in Company Portal, then return here."
        ) {
            // Progress bar
            VStack(spacing: 8) {
                ProgressView(value: coordinator.progress)
                    .progressViewStyle(.linear)
                Text("Checking for MDM profile… (attempt \(attempt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Steps guide
            VStack(alignment: .leading, spacing: 10) {
                enrollmentStep(number: 1, title: "Open Company Portal", done: true)
                enrollmentStep(number: 2, title: "Sign in with your work account", done: attempt > 2)
                enrollmentStep(number: 3, title: "Tap 'Enrol Device' and follow prompts", done: attempt > 6)
                enrollmentStep(number: 4, title: "Approve profile in System Settings", done: false)
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    coordinator.openProfilesPreferencePane()
                }
                .buttonStyle(.bordered)

                Button("Check again") {
                    Task { await coordinator.checkNow(config: config) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Complete

    private func completeView(updatedConfig: CompanyProfileConfig) -> some View {
        WizardPage(
            icon: "checkmark.seal.fill",
            iconColor: .green,
            title: "User Enrollment Complete",
            subtitle: "Your work profile is now fully managed. The company's policies apply only to the managed volume."
        ) {
            VStack(spacing: 0) {
                infoRow(label: "Organisation",  value: updatedConfig.tenantDisplayName)
                Divider()
                infoRow(label: "Tier",          value: updatedConfig.tierLabel, valueColor: .indigo)
                Divider()
                infoRow(label: "MDM",           value: updatedConfig.mdmOrganisationName ?? "Intune", valueColor: .green)
                Divider()
                infoRow(
                    label: "VPN",
                    value: updatedConfig.vpnEndpoint ?? "Not configured",
                    valueColor: updatedConfig.vpnEndpoint != nil ? .blue : .secondary
                )
                Divider()
                infoRow(
                    label: "Managed Volume",
                    value: updatedConfig.isUserEnrollment ? "Scoped (User Enrolled)" : "Full Device",
                    valueColor: updatedConfig.isUserEnrollment ? .green : .orange
                )
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            Button("Done") {
                onComplete(updatedConfig)
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
            title: "Enrollment Failed",
            subtitle: message
        ) {
            HStack(spacing: 12) {
                Button("Try Again") {
                    Task { await coordinator.startUpgrade(config: config) }
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    coordinator.reset()
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Progress spinner

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

    private func enrollmentStep(number: Int, title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.15) : Color.secondary.opacity(0.10))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(done ? .primary : .secondary)
            Spacer()
        }
    }

    private func featureRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func infoRow(label: String, value: String, valueColor: Color = .primary) -> some View {
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
}
