<div align="center">

# Gridly

**Workspace Profile Manager for macOS & iPadOS**

Keep your work, personal, and client identities completely separate — different Microsoft accounts, different browser sessions, different everything — all from one clean interface.

[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://www.apple.com/macos)
[![iPadOS 16+](https://img.shields.io/badge/iPadOS-16%2B-blue.svg)](https://www.apple.com/ipados)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

</div>

---

## What is Gridly?

Gridly lets you define named **workspace profiles** — each one tied to a specific Microsoft account (or any identity). Switching profiles instantly switches which account is active across Teams, Outlook, OneDrive, Word, Excel, Slack, Zoom, and Edge.

On **macOS**, each profile gets its own encrypted APFS volume and isolated browser session, so cookies, cached credentials, and local data never bleed across identities. On **iPad**, profiles track accounts and launch apps into the correct account via iOS deep-links.

---

## Features

### macOS App
- **Encrypted APFS volumes** — each profile lives on its own AES-256 sparse bundle, mounted only when active
- **Account-level isolation** — Microsoft 365, Teams, and browser sessions are scoped per profile
- **Per-profile browser sessions** — Edge and Chrome launched with dedicated `--user-data-dir` paths
- **Compliance dashboard** — VPN status, Intune compliance state, session health at a glance
- **Signed audit log** — every profile switch and app launch is HMAC-SHA256 signed and stored in SQLite
- **Policy cache** — encrypted local cache of Entra ID / Intune policies with TTL enforcement
- **Background agent** — `GridlyAgent` keeps volumes in sync and enforces idle timeouts
- **Privileged helper** — `GridlyHelper` handles SMJobBless tasks without requiring persistent root
- **Per-app VPN** (Network Extension) — route only managed-app traffic through the corporate tunnel
- **Persistent data** — all data lives in `~/Library/Application Support/Gridly/`, survives updates
- **Versioned DB migrations** — GRDB `DatabaseMigrator` ensures schema upgrades never lose data

### iPad App (GridlyPad)
- **Three-column layout** — sidebar navigation, profile list, and detail view
- **Account-level isolation** — tracks Microsoft identity per profile, launches apps via URL schemes
- **Deep-link launch** — `msteams://`, `ms-outlook://`, `ms-onedrive://`, `ms-word://`, `ms-excel://`, `slack://`, `zoomus://`, `microsoft-edge-http://`
- **Web fallback** — if an app isn't installed, opens the web version automatically
- **Audit log** — filterable event history for profile switches and app launches
- **UserDefaults persistence** — profile data survives app restarts and updates

---

## Architecture

### macOS — Module Map

```
Gridly.app
├── App/                    — SwiftUI entry point, AppDelegate, DI root (AppContainer)
├── Sources/
│   ├── CSCore/             — Shared models, errors, logging (WorkspaceProfile, AuditEntry…)
│   ├── CSCrypto/           — AES-GCM encryption, HMAC signing, Keychain manager
│   ├── CSAuth/             — Entra ID / MSAL token acquisition and refresh
│   ├── CSWorkspace/        — APFS volume lifecycle, profile manager, app launcher
│   ├── CSPolicy/           — Intune policy fetching, local encrypted cache, enforcer
│   ├── CSAudit/            — Append-only SQLite audit log with HMAC integrity
│   ├── CSGraph/            — Microsoft Graph API calls (user info, device compliance)
│   └── CSUI/               — SwiftUI views: dashboard, profile switcher, app launcher
├── Agent/                  — GridlyAgent (launchd daemon, idle timeout, volume sync)
├── Helper/                 — GridlyHelper (SMJobBless privileged helper)
└── NetworkExtension/       — GridlyNE (per-app VPN packet tunnel)
```

### iPad — Module Map

```
GridlyPad/
├── GridlyPadApp.swift      — @main, AppState, Tab enum
├── RootView.swift          — NavigationSplitView (sidebar | content | detail)
├── Models/
│   ├── Profile.swift       — Profile struct, ManagedApp, URL schemes
│   └── ProfileManager.swift — UserDefaults persistence, demo data, CRUD
└── Views/
    ├── DashboardView.swift  — Status cards, active profile, quick-launch grid
    ├── ProfileListView.swift — List with swipe actions, create/edit sheets
    ├── ProfileDetailView.swift — Per-profile app grid with deep-link launch
    ├── AllAppsView.swift    — Full app catalog with active-profile context
    ├── AuditLogView.swift   — Filterable event log with demo seeding
    └── SettingsView.swift   — VPN, compliance, biometric, about
```

### Data Flow

```
User switches profile
        │
        ▼
ProfileManager.activate()
        │
        ├─► WorkspaceVolumeManager  — mount encrypted APFS volume
        ├─► KeychainManager         — unlock profile keychain
        ├─► BrowserProfileManager   — point Edge/Chrome to profile data dir
        ├─► IsolatedAppLauncher     — launch apps with correct identity
        └─► AuditLogger             — sign and persist the switch event
```

---

## Requirements

| Target | Requirement |
|--------|-------------|
| macOS app | macOS 13 Ventura or later |
| iPad app | iPadOS 16 or later |
| Xcode | 15 or later |
| Swift | 5.9 or later |

### Dependencies (Swift Package Manager)

| Package | Purpose |
|---------|---------|
| [MSAL](https://github.com/AzureAD/microsoft-authentication-library-for-objc) | Microsoft Entra ID authentication |
| [GRDB](https://github.com/groue/GRDB.swift) | SQLite — audit log and policy cache |

---

## Building

### Prerequisites

```bash
brew install xcodegen
```

### 1. Clone and generate the project

```bash
git clone https://github.com/yourname/gridly.git
cd gridly
xcodegen generate
```

### 2. Build for your Mac (no Apple Developer account required)

```bash
xcodebuild -scheme GridlyLocal -configuration Release build \
  CONFIGURATION_BUILD_DIR=/tmp/GridlyRelease
```

The app will be at `/tmp/GridlyRelease/Gridly.app`. Drag it to `/Applications`.

> **First launch:** right-click → Open (Gatekeeper prompt for ad-hoc signed apps). After that it opens normally.

### 3. Build the iPad app

Open `Gridly.xcodeproj` in Xcode → select the **GridlyPad** scheme → choose an iPad simulator → ▶ Run.

### 4. Production build (requires Apple Developer Program)

1. Change `CODE_SIGN_IDENTITY: "-"` → `CODE_SIGN_IDENTITY: "Developer ID Application"` in `project.yml`
2. Set your Team ID in `DEVELOPMENT_TEAM`
3. Run `xcodegen generate`, build, archive, then notarize:

```bash
xcrun notarytool submit Gridly.dmg \
  --apple-id your@email.com \
  --team-id YOURTEAMID \
  --password your-app-specific-password \
  --wait
xcrun stapler staple Gridly.dmg
```

---

## Configuration (Production Mode)

Without a config file Gridly starts in **demo mode** — three pre-loaded profiles, full UI, and persistent storage all work. To connect to a real Microsoft tenant:

1. Register an app in [Entra ID (Azure Portal)](https://entra.microsoft.com)
2. Copy `App/Resources/Gridly-Config.plist.example` → `App/Resources/Gridly-Config.plist`
3. Fill in your values:

```xml
<dict>
    <key>EntraClientID</key>    <string>xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx</string>
    <key>EntraTenantID</key>    <string>xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx</string>
    <key>AuditEndpointURL</key> <string>https://your-backend/api/audit</string>
</dict>
```

> `Gridly-Config.plist` is in `.gitignore` — never commit real credentials.

---

## Data & Privacy

All data is stored **locally on-device only**:

| Data | Location | Format |
|------|----------|--------|
| Profile list | `~/Library/Application Support/Gridly/Profiles/registry.json` | JSON |
| Policy cache | `~/Library/Application Support/Gridly/policy.db` | SQLite (AES-GCM encrypted payloads) |
| Audit log | `~/Library/Application Support/Gridly/audit.db` | SQLite (HMAC-signed rows) |
| Profile volumes | `~/Library/Application Support/Gridly/<id>.sparsebundle` | Encrypted APFS |

Nothing is transmitted anywhere unless you configure an `AuditEndpointURL`. No analytics, no telemetry, no third-party trackers.

---

## Database Migrations

Gridly uses [GRDB's `DatabaseMigrator`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/migrations) for safe schema upgrades. Each named migration runs exactly once and is tracked in a `grdb_migrations` table — upgrading from any previous version never loses data.

To add a column in a future version, append a new migration and never touch the old ones:

```swift
migrator.registerMigration("v2_add_device_id") { db in
    try db.alter(table: "audit_log") { t in
        t.add(column: "deviceID", .text)
    }
}
```

---

## Contributing

Pull requests are welcome. For major changes please open an issue first to discuss the approach.

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Commit your changes
4. Push and open a pull request

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

## Support the Project

Gridly is free and open source. If it saves you time or headaches, a coffee is always appreciated ☕

| | |
|:---:|:---:|
| **PayPal** | **Ethereum** |
| [paypal.me/xttenza](https://paypal.me/xttenza) | `0x5089CaF24B39b0dFe33336C368C8676b3Be397df` |
| [![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-0070ba.svg?logo=paypal&logoColor=white)](https://paypal.me/xttenza) | [![Donate ETH](https://img.shields.io/badge/Donate-ETH-627EEA.svg?logo=ethereum&logoColor=white)](https://etherscan.io/address/0x5089CaF24B39b0dFe33336C368C8676b3Be397df) |

No pressure — the app is free either way. Thank you for using Gridly!
