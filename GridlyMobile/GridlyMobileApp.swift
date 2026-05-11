import SwiftUI

@main
struct GridlyMobileApp: App {

    @StateObject private var profileManager = ProfileManager()
    @StateObject private var appState      = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(profileManager)
                .environmentObject(appState)
                .onAppear {
                    if profileManager.profiles.isEmpty {
                        // First launch — load demo data
                        profileManager.injectDemoProfiles()
                    }
                }
        }
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: Tab = .profiles
    @Published var complianceLabel  = "Compliant"
    @Published var complianceColor: Color = .green
    @Published var vpnActive        = false
    @Published var sessionLabel     = "Active"

    enum Tab: String, CaseIterable {
        case profiles   = "Profiles"
        case dashboard  = "Dashboard"
        case apps       = "Apps"
        case auditLog   = "Audit Log"
        case settings   = "Settings"

        var icon: String {
            switch self {
            case .profiles:  return "person.2.badge.gearshape.fill"
            case .dashboard: return "gauge.with.dots.needle.67percent"
            case .apps:      return "square.grid.2x2.fill"
            case .auditLog:  return "list.clipboard.fill"
            case .settings:  return "gearshape.fill"
            }
        }
    }
}
