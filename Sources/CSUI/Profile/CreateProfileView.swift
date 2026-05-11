import SwiftUI
import CSCore
import CSWorkspace

// MARK: - CreateProfileView

/// Sheet for creating a new workspace profile.
public struct CreateProfileView: View {

    @ObservedObject public var profileManager: ProfileManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var accountID = ""
    @State private var selectedColor: WorkspaceProfile.ProfileColor
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var sizeGB = 10
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showPassphrase = false

    private let sizeOptions = [5, 10, 20, 50, 100]

    public init(profileManager: ProfileManager) {
        self.profileManager = profileManager
        _selectedColor = State(initialValue: WorkspaceProfile.ProfileColor.next(after: profileManager.profiles))
    }

    // MARK: - Validation

    private var passphrasesMismatch: Bool {
        !confirmPassphrase.isEmpty && passphrase != confirmPassphrase
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && passphrase.count >= 8
        && passphrase == confirmPassphrase
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Workspace Profile")
                        .font(.title2.weight(.semibold))
                    Text("Creates an isolated, AES-256 encrypted APFS volume for this profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    // ── Profile Identity ─────────────────────────────────────
                    section("Profile Identity") {
                        LabeledField("Name") {
                            TextField("e.g. Contoso Work, Client A", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField("Account (optional)") {
                            TextField("jane.doe@company.com", text: $accountID)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledField("Color") {
                            colorPicker
                        }
                    }

                    // ── Encryption ───────────────────────────────────────────
                    section("Encryption Passphrase") {
                        Text("This passphrase encrypts the AES-256 APFS volume. It is never sent off-device — not even to Intune. If lost, data is irrecoverable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        LabeledField("Passphrase") {
                            HStack {
                                if showPassphrase {
                                    TextField("At least 8 characters", text: $passphrase)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    SecureField("At least 8 characters", text: $passphrase)
                                        .textFieldStyle(.roundedBorder)
                                }
                                Button {
                                    showPassphrase.toggle()
                                } label: {
                                    Image(systemName: showPassphrase ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        LabeledField("Confirm") {
                            SecureField("Repeat passphrase", text: $confirmPassphrase)
                                .textFieldStyle(.roundedBorder)
                                .overlay(alignment: .trailing) {
                                    if passphrasesMismatch {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.red)
                                            .padding(.trailing, 6)
                                    }
                                }
                        }

                        if passphrasesMismatch {
                            Text("Passphrases do not match.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if passphrase.count > 0 && passphrase.count < 8 {
                            Text("Passphrase must be at least 8 characters.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    // ── Storage ──────────────────────────────────────────────
                    section("Volume Size") {
                        HStack(spacing: 12) {
                            ForEach(sizeOptions, id: \.self) { gb in
                                Group {
                                    if gb == sizeGB {
                                        Button("\(gb) GB") { sizeGB = gb }.buttonStyle(.borderedProminent)
                                    } else {
                                        Button("\(gb) GB") { sizeGB = gb }.buttonStyle(.bordered)
                                    }
                                }
                                .controlSize(.small)
                            }
                            Spacer()
                        }
                        Text("Sparse bundles only consume the space actually used, so you can size generously.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // ── Isolation Explainer ──────────────────────────────────
                    section("What gets isolated") {
                        isolationGrid
                    }

                }
                .padding(24)
            }

            Divider()

            // Footer buttons
            HStack {
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    Task { await createProfile() }
                } label: {
                    Group {
                        if isCreating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Creating…")
                            }
                        } else {
                            Text("Create Profile")
                        }
                    }
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
    }

    // MARK: - Subviews

    private var colorPicker: some View {
        HStack(spacing: 8) {
            ForEach(WorkspaceProfile.ProfileColor.allCases, id: \.self) { color in
                Button {
                    selectedColor = color
                } label: {
                    Circle()
                        .fill(color.swiftUIColor.gradient)
                        .frame(width: 24, height: 24)
                        .overlay {
                            if selectedColor == color {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(color.displayName)
            }
        }
    }

    private var isolationGrid: some View {
        let items: [(String, String)] = [
            ("lock.doc.fill",           "Encrypted APFS volume per profile"),
            ("house.fill",              "Separate HOME directory — apps store data inside the volume"),
            ("person.badge.key.fill",   "Separate MSAL token cache — distinct Entra ID sessions"),
            ("app.badge.fill",          "open -n forces separate process — two Teams can run at once"),
            ("network",                 "Per-app VPN routes only this profile's traffic through the tunnel"),
            ("shield.lefthalf.filled",  "Lock one profile without affecting others"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(items, id: \.0) { icon, text in
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(selectedColor.swiftUIColor)
                        .frame(width: 20)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            content()
        }
    }

    private func createProfile() async {
        isCreating = true
        errorMessage = nil
        do {
            _ = try await profileManager.createProfile(
                name: name.trimmingCharacters(in: .whitespaces),
                accountIdentifier: accountID.trimmingCharacters(in: .whitespaces),
                color: selectedColor,
                passphrase: passphrase,
                sizeGB: sizeGB
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }
}

// MARK: - LabeledField helper

private struct LabeledField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
                .padding(.trailing, 10)
            content
        }
    }
}
