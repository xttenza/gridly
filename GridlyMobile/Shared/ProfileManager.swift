import SwiftUI
import Combine

// MARK: - ProfileManager (iOS)
//
// On iPad there are no APFS sparse bundles or subprocess calls.
// Profiles are lightweight JSON objects stored in UserDefaults.
// "Isolation" means routing each profile's apps through its own
// Microsoft account via URL scheme deep-links.

@MainActor
final class ProfileManager: ObservableObject {

    @Published private(set) var profiles: [Profile] = []
    @Published var activeProfileID: UUID?

    private let defaults = UserDefaults.standard
    private let key = "com.gridly.pad.profiles"

    init() { load() }

    // MARK: - Active profile

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    func activate(_ profile: Profile) {
        activeProfileID = profile.id
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx].lastAccessedAt = Date()
            save()
        }
    }

    // MARK: - CRUD

    @discardableResult
    func createProfile(name: String, account: String, colorName: String) -> Profile {
        let p = Profile(name: name, accountIdentifier: account, colorName: colorName)
        profiles.append(p)
        save()
        return p
    }

    func updateProfile(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            save()
        }
    }

    func deleteProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
        save()
    }

    // MARK: - Demo injection

    func injectDemoProfiles() {
        let work = Profile(
            id: UUID(),
            name: "Contoso Work",
            accountIdentifier: "jane.doe@contoso.com",
            colorName: "blue"
        )
        let client = Profile(
            id: UUID(),
            name: "Client — Fabrikam",
            accountIdentifier: "jane@fabrikam.com",
            colorName: "purple"
        )
        let dev = Profile(
            id: UUID(),
            name: "Dev / Staging",
            accountIdentifier: "",
            colorName: "orange"
        )
        profiles = [work, client, dev]
        activeProfileID = work.id
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: key)
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let loaded = try? JSONDecoder().decode([Profile].self, from: data)
        else { return }
        profiles = loaded
    }
}
