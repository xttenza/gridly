import SwiftUI

// MARK: - entraClientID Environment Key

private struct EntraClientIDKey: EnvironmentKey {
    static let defaultValue: String = ""
}

public extension EnvironmentValues {
    /// The Azure AD client ID registered for this Gridly installation.
    /// Injected at the root by WorkspaceDashboardView and consumed by
    /// CompanyProfileStatusView / CompanyProfileWizardView.
    var entraClientID: String {
        get { self[EntraClientIDKey.self] }
        set { self[EntraClientIDKey.self] = newValue }
    }
}
