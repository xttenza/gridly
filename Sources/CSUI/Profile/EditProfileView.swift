import SwiftUI
import CSCore
import CSWorkspace

// MARK: - EditProfileView

/// Sheet for editing mutable fields of an existing workspace profile:
/// display name, account identifier, and accent color.
/// Passphrase is intentionally not editable here — changing an APFS sparse-bundle
/// passphrase requires hdiutil and is handled separately (not yet implemented in UI).
public struct EditProfileView: View {

    @ObservedObject public var profileManager: ProfileManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var accountID: String
    @State private var selectedColor: WorkspaceProfile.ProfileColor

    private let original: WorkspaceProfile

    public init(profile: WorkspaceProfile, profileManager: ProfileManager) {
        self.original       = profile
        self.profileManager = profileManager
        _name          = State(initialValue: profile.name)
        _accountID     = State(initialValue: profile.accountIdentifier)
        _selectedColor = State(initialValue: profile.color)
    }

    // MARK: - Validation

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasChanges: Bool {
        name != original.name
        || accountID != original.accountIdentifier
        || selectedColor != original.color
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Profile")
                        .font(.title2.weight(.semibold))
                    Text("Changes take effect immediately and are saved to the registry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            // Form
            VStack(alignment: .leading, spacing: 22) {
                section("Profile Identity") {
                    LabeledEditField("Name") {
                        TextField("Profile name", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledEditField("Account") {
                        TextField("jane@company.com (optional)", text: $accountID)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledEditField("Color") {
                        colorPicker
                    }
                }

                // Preview card
                section("Preview") {
                    previewCard
                }
            }
            .padding(24)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Changes") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || !hasChanges)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
    }

    // MARK: - Color Picker

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

    // MARK: - Preview Card

    private var previewCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(selectedColor.swiftUIColor.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Profile Name" : name)
                    .font(.headline)
                    .foregroundStyle(name.trimmingCharacters(in: .whitespaces).isEmpty ? .tertiary : .primary)
                if !accountID.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(accountID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No account configured")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Label("Unlocked", systemImage: "checkmark.shield.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(selectedColor.swiftUIColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(selectedColor.swiftUIColor.opacity(0.12), in: Capsule())
        }
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selectedColor.swiftUIColor.opacity(0.4), lineWidth: 1.5)
        )
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

    private func save() {
        var updated = original
        updated.name              = name.trimmingCharacters(in: .whitespaces)
        updated.accountIdentifier = accountID.trimmingCharacters(in: .whitespaces)
        updated.color             = selectedColor
        profileManager.updateProfile(updated)
        dismiss()
    }
}

// MARK: - LabeledEditField

private struct LabeledEditField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label   = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
                .padding(.trailing, 10)
            content
        }
    }
}
