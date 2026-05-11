import SwiftUI
import CSCore

public struct WorkspaceSettingsView: View {

    @AppStorage("lockTimeoutMinutes") private var lockTimeoutMinutes = 15
    @AppStorage("clipboardGuardEnabled") private var clipboardGuardEnabled = true
    @AppStorage("watermarkEnabled") private var watermarkEnabled = true
    @AppStorage("vpnAutoConnect") private var vpnAutoConnect = false
    @AppStorage("auditShippingEnabled") private var auditShippingEnabled = true

    @State private var showWipeConfirmation = false

    public var body: some View {
        Form {
            // ── Session ──────────────────────────────────────────────────────
            Section("Session") {
                Picker("Auto-lock after", selection: $lockTimeoutMinutes) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                .pickerStyle(.menu)
                .help("Workspace locks automatically after this period of inactivity.")
            }

            // ── Security ─────────────────────────────────────────────────────
            Section("Security") {
                Toggle("Clipboard Guard", isOn: $clipboardGuardEnabled)
                    .help("Clear clipboard when switching from corporate to personal apps.")
                Toggle("File Watermarking", isOn: $watermarkEnabled)
                    .help("Embed invisible watermarks in files copied from the workspace.")
                Toggle("Auto-connect VPN", isOn: $vpnAutoConnect)
                    .help("Connect to corporate VPN automatically when workspace unlocks.")
            }

            // ── Audit ─────────────────────────────────────────────────────────
            Section("Audit & Compliance") {
                Toggle("Ship Audit Logs", isOn: $auditShippingEnabled)
                    .help("Send audit events to your organization's SIEM system.")
            }

            // ── Browser ───────────────────────────────────────────────────────
            Section("Browser") {
                LabeledContent("Default Browser") {
                    Text("Microsoft Edge (Isolated Profile)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Downloads") {
                    Text("Workspace/Downloads")
                        .foregroundStyle(.secondary)
                        .font(.caption.monospaced())
                }
            }

            // ── About ─────────────────────────────────────────────────────────
            Section("About") {
                LabeledContent("Version") {
                    Text("\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Build") {
                    Text("Production / Hardened Runtime")
                        .foregroundStyle(.secondary)
                }
            }

            // ── Danger Zone ───────────────────────────────────────────────────
            Section {
                Button("Unenroll Device…", role: .destructive) {
                    showWipeConfirmation = true
                }
                .foregroundStyle(.red)
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Unenrolling will remove all corporate data from this device. Your personal files are never affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog(
            "Unenroll This Device?",
            isPresented: $showWipeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unenroll & Remove Corporate Data", role: .destructive) {
                // Trigger soft wipe via ViewModel
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all corporate workspace data from your Mac. Your personal files are safe and will not be affected.")
        }
    }
}

// MARK: - Privacy Transparency View

public struct PrivacyTransparencyView: View {

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your Privacy")
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 4)

                Text("Gridly is designed to protect corporate data while fully preserving your personal privacy. Here is exactly what your organization can and cannot see.")
                    .foregroundStyle(.secondary)

                visibilitySection(
                    title: "What your organization CAN see",
                    icon: "eye.fill",
                    color: .orange,
                    items: canSeeItems
                )

                visibilitySection(
                    title: "What your organization CANNOT see",
                    icon: "eye.slash.fill",
                    color: .green,
                    items: cannotSeeItems
                )

                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Technical Guarantee")
                                .font(.headline)
                            Text("The workspace runs in a cryptographically isolated APFS volume. Personal files are on a completely separate volume. IT administrators have no technical capability to access personal data — it is not a policy commitment alone, it is a technical boundary.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Privacy")
    }

    @ViewBuilder
    private func visibilitySection(title: String, icon: String, color: Color, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)

            ForEach(items, id: \.0) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .font(.caption)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.subheadline.weight(.medium))
                        Text(item.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private let canSeeItems: [(String, String)] = [
        ("Compliance Status",    "Whether your device meets security requirements"),
        ("macOS Version",        "Operating system version only"),
        ("Workspace App Usage",  "Which managed corporate apps were launched"),
        ("Corporate File Events","Read/write events inside the corporate workspace"),
        ("Device Serial Number", "Used for Intune device identity only"),
    ]

    private let cannotSeeItems: [(String, String)] = [
        ("Personal Files",          "Files outside the corporate workspace volume"),
        ("Personal Browser History","Any browsing outside the managed Edge profile"),
        ("Personal App Usage",      "Which personal apps you use"),
        ("Location",                "Your physical location is never collected"),
        ("Personal Communications", "Personal email, messages, and contacts"),
        ("Personal Photos",         "Camera roll and Photos library"),
        ("Keystrokes",              "No keylogging of any kind"),
    ]
}

// MARK: - Bundle Helpers

private extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "1" }
}
