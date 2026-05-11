import SwiftUI

// MARK: - Profile

struct Profile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var accountIdentifier: String
    var colorName: String       // stored as string for Codable
    var createdAt: Date = Date()
    var lastAccessedAt: Date?

    var color: Color {
        switch colorName {
        case "blue":   return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "green":  return .green
        case "red":    return .red
        case "teal":   return .teal
        default:       return .blue
        }
    }

    static let colorOptions: [(String, Color)] = [
        ("blue", .blue), ("purple", .purple), ("orange", .orange),
        ("green", .green), ("teal", .teal), ("red", .red)
    ]
}

// MARK: - ManagedApp

struct ManagedApp: Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let iconSystemName: String
    /// URL scheme used to open the app on iOS (nil = not installed / web-only)
    let urlScheme: String?
    /// Web URL fallback — opens in Safari if app not installed
    let webURL: String

    func isInstalled() -> Bool {
        guard let scheme = urlScheme,
              let url = URL(string: scheme + "://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    static let all: [ManagedApp] = [
        ManagedApp(bundleID: "com.microsoft.teams2",
                   displayName: "Microsoft Teams",
                   iconSystemName: "video.bubble.fill",
                   urlScheme: "msteams",
                   webURL: "https://teams.microsoft.com"),
        ManagedApp(bundleID: "com.microsoft.outlookipad",
                   displayName: "Microsoft Outlook",
                   iconSystemName: "envelope.fill",
                   urlScheme: "ms-outlook",
                   webURL: "https://outlook.office.com"),
        ManagedApp(bundleID: "com.microsoft.OneDrive",
                   displayName: "OneDrive",
                   iconSystemName: "icloud.fill",
                   urlScheme: "ms-onedrive",
                   webURL: "https://onedrive.live.com"),
        ManagedApp(bundleID: "com.microsoft.Office.Word",
                   displayName: "Microsoft Word",
                   iconSystemName: "doc.fill",
                   urlScheme: "ms-word",
                   webURL: "https://www.office.com/launch/word"),
        ManagedApp(bundleID: "com.microsoft.Office.Excel",
                   displayName: "Microsoft Excel",
                   iconSystemName: "tablecells.fill",
                   urlScheme: "ms-excel",
                   webURL: "https://www.office.com/launch/excel"),
        ManagedApp(bundleID: "com.tinyspeck.slackmacgap",
                   displayName: "Slack",
                   iconSystemName: "message.fill",
                   urlScheme: "slack",
                   webURL: "https://app.slack.com"),
        ManagedApp(bundleID: "us.zoom.videomeetings",
                   displayName: "Zoom",
                   iconSystemName: "video.fill",
                   urlScheme: "zoomus",
                   webURL: "https://zoom.us/join"),
        ManagedApp(bundleID: "com.microsoft.msedge",
                   displayName: "Microsoft Edge",
                   iconSystemName: "globe",
                   urlScheme: "microsoft-edge-http",
                   webURL: "https://www.microsoft.com/edge"),
    ]
}
