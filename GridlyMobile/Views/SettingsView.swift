import SwiftUI

// MARK: - SettingsView (middle column for .settings tab)

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var profileManager: ProfileManager

    @AppStorage("gridly.vpnEnabled")         private var vpnEnabled      = false
    @AppStorage("gridly.complianceEnabled")  private var complianceCheck = true
    @AppStorage("gridly.auditEnabled")       private var auditEnabled    = true
    @AppStorage("gridly.biometricLock")      private var biometricLock   = false
    @AppStorage("gridly.defaultBrowser")     private var defaultBrowser  = "Edge"

    @State private var showResetAlert = false
    @State private var showAbout      = false

    var body: some View {
        List {
            // MARK: Network
            Section {
                Toggle(isOn: $vpnEnabled) {
                    Label("VPN", systemImage: "network.badge.shield.half.filled")
                }
                .onChange(of: vpnEnabled) { v in appState.vpnActive = v }

                Picker(selection: $defaultBrowser) {
                    Text("Microsoft Edge").tag("Edge")
                    Text("Google Chrome").tag("Chrome")
                    Text("Safari").tag("Safari")
                } label: {
                    Label("Default Browser", systemImage: "globe")
                }
            } header: {
                Text("Network")
            } footer: {
                Text("VPN status is simulated. In a managed deployment, this reflects the actual device VPN state.")
            }

            // MARK: Compliance
            Section {
                Toggle(isOn: $complianceCheck) {
                    Label("Compliance Checks", systemImage: "checkmark.shield.fill")
                }
                .onChange(of: complianceCheck) { v in
                    appState.complianceLabel = v ? "Compliant" : "Unchecked"
                    appState.complianceColor = v ? .green : .secondary
                }

                Toggle(isOn: $auditEnabled) {
                    Label("Audit Logging", systemImage: "list.clipboard.fill")
                }
            } header: {
                Text("Compliance")
            } footer: {
                Text("Audit logging records profile switches and app launches locally on this device.")
            }

            // MARK: Security
            Section {
                Toggle(isOn: $biometricLock) {
                    Label("Require Face ID / Touch ID", systemImage: "faceid")
                }
            } header: {
                Text("Security")
            } footer: {
                Text("When enabled, Gridly will require biometric authentication on each launch.")
            }

            // MARK: Profiles
            Section("Profiles") {
                HStack {
                    Label("Total Profiles", systemImage: "person.2.fill")
                    Spacer()
                    Text("\(profileManager.profiles.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let active = profileManager.activeProfile {
                    HStack {
                        Label("Active Profile", systemImage: "checkmark.shield.fill")
                        Spacer()
                        Text(active.name)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(role: .destructive) {
                    showResetAlert = true
                } label: {
                    Label("Reset to Demo Data", systemImage: "arrow.counterclockwise")
                }
            }

            // MARK: About
            Section("About") {
                Button {
                    showAbout = true
                } label: {
                    HStack {
                        Label("About Gridly", systemImage: "info.circle.fill")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)

                HStack {
                    Label("Version", systemImage: "tag.fill")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle("Settings")
        .alert("Reset Profiles?", isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) {
                profileManager.resetToDemo()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all existing profiles and restore the three demo profiles.")
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
    }
}

// MARK: - AboutSheet

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Logo
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.055, green: 0.071, blue: 0.212),
                                             Color(red: 0.203, green: 0.188, blue: 0.471)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 100, height: 100)
                            .shadow(color: .indigo.opacity(0.4), radius: 16, y: 6)

                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(20)), count: 3), spacing: 5) {
                            ForEach(gridCells, id: \.0) { cell in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(cell.1)
                                    .frame(width: 20, height: 20)
                            }
                        }
                    }

                    VStack(spacing: 6) {
                        Text("Gridly")
                            .font(.largeTitle.weight(.bold))
                        Text("Version 1.0.0")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        featureRow(icon: "person.2.badge.gearshape.fill", color: .indigo,
                                   title: "Multi-Profile Workspaces",
                                   detail: "Keep work, personal, and client identities completely separate.")
                        featureRow(icon: "lock.shield.fill", color: .blue,
                                   title: "Account-Level Isolation",
                                   detail: "Each profile tracks its Microsoft identity and launches apps with the correct account.")
                        featureRow(icon: "arrow.up.right.square.fill", color: .purple,
                                   title: "Deep-Link Launch",
                                   detail: "Open Teams, Outlook, OneDrive, and more directly into the right account.")
                        featureRow(icon: "checkmark.shield.fill", color: .green,
                                   title: "Compliance Aware",
                                   detail: "Monitor VPN status and compliance state from one central dashboard.")
                    }
                    .padding(20)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))

                    Text("Built with ❤️ using SwiftUI")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(28)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func featureRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // 3×3 grid cells for logo reproduction
    private var gridCells: [(Int, Color)] {
        let blue   = Color(red: 0.314, green: 0.647, blue: 1.0)
        let purple = Color(red: 0.471, green: 0.392, blue: 0.941)
        let white  = Color.white
        let dim    = Color.white.opacity(0.15)
        return [
            (0, blue),   (1, dim),    (2, purple),
            (3, dim),    (4, white),  (5, dim),
            (6, purple), (7, dim),    (8, blue),
        ]
    }
}

// MARK: - ProfileManager extension

extension ProfileManager {
    func resetToDemo() {
        // Clear all and re-inject demo
        for p in profiles { deleteProfile(p) }
        injectDemoProfiles()
    }
}
