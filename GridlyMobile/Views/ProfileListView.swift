import SwiftUI

// MARK: - ProfileListView (middle column)

struct ProfileListView: View {

    @Binding var selectedProfile: Profile?
    @EnvironmentObject private var profileManager: ProfileManager
    @State private var showingCreate = false
    @State private var editingProfile: Profile?

    var body: some View {
        List(profileManager.profiles, selection: $selectedProfile) { profile in
            ProfileRow(profile: profile,
                       isActive: profileManager.activeProfileID == profile.id)
                .tag(profile)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        profileManager.deleteProfile(profile)
                        if selectedProfile == profile { selectedProfile = nil }
                    } label: { Label("Delete", systemImage: "trash") }

                    Button { editingProfile = profile } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        profileManager.activate(profile)
                    } label: {
                        Label("Activate", systemImage: "checkmark.circle.fill")
                    }
                    .tint(.green)
                }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreate = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateProfileSheet()
        }
        .sheet(item: $editingProfile) { profile in
            EditProfileSheet(profile: profile)
        }
    }
}

// MARK: - ProfileRow

struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(profile.color.gradient)
                    .frame(width: 44, height: 44)
                Image(systemName: isActive ? "checkmark.shield.fill" : "person.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 18, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(profile.name)
                        .font(.headline)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(profile.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(profile.color.opacity(0.12), in: Capsule())
                    }
                }
                Text(profile.accountIdentifier.isEmpty ? "No account" : profile.accountIdentifier)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @EnvironmentObject private var profileManager: ProfileManager
    @Environment(\.dismiss) private var dismiss

    @State private var name       = ""
    @State private var account    = ""
    @State private var colorName  = "blue"

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile Details") {
                    TextField("Display Name", text: $name)
                    TextField("Email / Account (optional)", text: $account)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }

                Section("Colour") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 6), spacing: 12) {
                        ForEach(Profile.colorOptions, id: \.0) { option in
                            Circle()
                                .fill(option.1.gradient)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if colorName == option.0 {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                }
                                .onTapGesture { colorName = option.0 }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Live preview
                Section("Preview") {
                    ProfileRow(
                        profile: Profile(name: name.isEmpty ? "Profile Name" : name,
                                         accountIdentifier: account,
                                         colorName: colorName),
                        isActive: false
                    )
                }
            }
            .navigationTitle("New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        profileManager.createProfile(name: name, account: account, colorName: colorName)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Edit Profile Sheet

struct EditProfileSheet: View {
    let profile: Profile
    @EnvironmentObject private var profileManager: ProfileManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var account: String
    @State private var colorName: String

    init(profile: Profile) {
        self.profile  = profile
        _name         = State(initialValue: profile.name)
        _account      = State(initialValue: profile.accountIdentifier)
        _colorName    = State(initialValue: profile.colorName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile Details") {
                    TextField("Display Name", text: $name)
                    TextField("Email / Account", text: $account)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }
                Section("Colour") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 6), spacing: 12) {
                        ForEach(Profile.colorOptions, id: \.0) { option in
                            Circle()
                                .fill(option.1.gradient)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if colorName == option.0 {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                }
                                .onTapGesture { colorName = option.0 }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = profile
                        updated.name              = name
                        updated.accountIdentifier = account
                        updated.colorName         = colorName
                        profileManager.updateProfile(updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
