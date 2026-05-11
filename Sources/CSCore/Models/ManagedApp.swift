import Foundation

public struct ManagedApp: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let bundleID: String
    public let version: String?
    public let iconSystemName: String
    public let launchArguments: [String]
    public let environmentVariables: [String: String]
    public let requiredVPN: Bool
    public let dataDirectoryRelativePath: String?
    public var installStatus: InstallStatus
    public var isEnabled: Bool
    public let category: AppCategory

    public enum InstallStatus: String, Codable, Sendable {
        case installed
        case notInstalled
        case updateAvailable
        case installing
        case error
    }

    public enum AppCategory: String, Codable, Sendable, CaseIterable {
        case communication = "Communication"
        case productivity  = "Productivity"
        case storage       = "Storage"
        case security      = "Security"
        case internal_     = "Internal"

        public var systemImage: String {
            switch self {
            case .communication: return "message.fill"
            case .productivity:  return "doc.fill"
            case .storage:       return "internaldrive.fill"
            case .security:      return "lock.shield.fill"
            case .internal_:     return "building.2.fill"
            }
        }
    }

    public init(
        id: String,
        displayName: String,
        bundleID: String,
        version: String? = nil,
        iconSystemName: String,
        launchArguments: [String] = [],
        environmentVariables: [String: String] = [:],
        requiredVPN: Bool = false,
        dataDirectoryRelativePath: String? = nil,
        installStatus: InstallStatus = .notInstalled,
        isEnabled: Bool = true,
        category: AppCategory = .productivity
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.version = version
        self.iconSystemName = iconSystemName
        self.launchArguments = launchArguments
        self.environmentVariables = environmentVariables
        self.requiredVPN = requiredVPN
        self.dataDirectoryRelativePath = dataDirectoryRelativePath
        self.installStatus = installStatus
        self.isEnabled = isEnabled
        self.category = category
    }

    public var isInstalled: Bool { installStatus == .installed || installStatus == .updateAvailable }

    // Default Microsoft 365 managed apps
    public static let defaultApps: [ManagedApp] = [
        ManagedApp(
            id: "edge",
            displayName: "Microsoft Edge",
            bundleID: "com.microsoft.edgemac",
            iconSystemName: "globe",
            launchArguments: ["--no-first-run", "--disable-sync"],
            dataDirectoryRelativePath: "Apps/Edge",
            category: .productivity
        ),
        ManagedApp(
            id: "teams",
            displayName: "Microsoft Teams",
            bundleID: "com.microsoft.teams2",
            iconSystemName: "video.fill",
            environmentVariables: ["MS_TEAMS_HOME": "Apps/Teams"],
            dataDirectoryRelativePath: "Apps/Teams",
            category: .communication
        ),
        ManagedApp(
            id: "outlook",
            displayName: "Microsoft Outlook",
            bundleID: "com.microsoft.Outlook",
            iconSystemName: "envelope.fill",
            dataDirectoryRelativePath: "Apps/Outlook",
            category: .communication
        ),
        ManagedApp(
            id: "onedrive",
            displayName: "OneDrive",
            bundleID: "com.microsoft.OneDrive-mac",
            iconSystemName: "icloud.fill",
            dataDirectoryRelativePath: "Apps/OneDrive",
            category: .storage
        ),
        ManagedApp(
            id: "word",
            displayName: "Microsoft Word",
            bundleID: "com.microsoft.Word",
            iconSystemName: "doc.text.fill",
            dataDirectoryRelativePath: "Apps/Word",
            category: .productivity
        ),
        ManagedApp(
            id: "excel",
            displayName: "Microsoft Excel",
            bundleID: "com.microsoft.Excel",
            iconSystemName: "tablecells.fill",
            dataDirectoryRelativePath: "Apps/Excel",
            category: .productivity
        ),
        ManagedApp(
            id: "powerpoint",
            displayName: "Microsoft PowerPoint",
            bundleID: "com.microsoft.Powerpoint",
            iconSystemName: "rectangle.on.rectangle.angled.fill",
            dataDirectoryRelativePath: "Apps/PowerPoint",
            category: .productivity
        ),
    ]
}
