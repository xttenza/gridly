# Changelog

All notable changes to Gridly are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [v1.3.3]

### Fixed
- **Edge / Chrome "Keychain Not Found"** — profile keychain is no longer set as the system default keychain. `login.keychain-db` stays the default so Chromium-based browsers can write passwords without error. The profile keychain is still prepended to the search list so MSAL reads find profile tokens first.
- **Subdomain work emails rejected as personal accounts** — `TenantDiscovery` now walks up the domain hierarchy (`user@mail.contoso.com` → tries `contoso.com` as fallback). Adds an OpenID Connect fallback for federated/hybrid tenants that don't surface correctly in Microsoft's UserRealm API. Fixes `user@main.intgin.net`-style addresses.

---

## [v1.2.0]

### Added
- **Tier 2: Apple User Enrollment** — MDM management scoped exclusively to the work volume. Company Portal guides enrollment; Gridly detects the MDM profile automatically via the `profiles` CLI.
- **Per-profile VPN** — `PerAppVPNManager` wraps `NETunnelProviderManager` to configure a tunnel that activates only for a specific profile's apps. Degrades gracefully in ad-hoc builds.
- `UserEnrollmentWizardView` — guided Tier 2 upgrade sheet with live step indicators and a System Settings deep link.
- `WizardPage` extracted as a shared layout container used by both wizard sheets.
- `CompanyProfileConfig` gains `mdmServerURL`, `mdmOrganisationName`, `isUserEnrollment`, `userEnrolledAt`, `vpnEndpoint`, `userPrincipalName`.

### Changed
- Profile card now shows "Upgrade to User Enrollment" button for Tier 1 profiles.
- Tier 2 profiles show an indigo badge and VPN endpoint label.
- `GridlyAgent` Xcode target now correctly declares `CSAuth` as a dependency (fixes build warning).

---

## [v1.1.0]

### Added
- **Tier 1: Microsoft Company Profile SSO Bridge** — connect a workspace profile to a Microsoft Entra ID tenant using Company Portal as a secure broker.
- `TenantDiscovery` — unauthenticated UserRealm + OpenID Connect tenant lookup.
- `CompanyPortalBridge` — MSAL broker integration (interactive, silent token acquisition, device registration detection, sign-out).
- `CompanyProfileManager` — wizard state machine (idle → discovering → tenant found → portal check → consent → authenticating → complete).
- `CompanyProfileWizardView` — 5-step guided setup sheet.
- `CompanyProfileStatusView` + `CompanyProfileSSOBanner` — profile card badges and "Connect Work Account" CTA.
- `LSApplicationQueriesSchemes` in `App/Info.plist` for MSAL broker detection (`msauthv2`, `msauthv3`).

### Changed
- `WorkspaceProfile` gains `companyConfig`, `isCompanyProfile`, `isSSOReady`.
- `Package.swift`: `CSWorkspace` and `CSUI` now correctly depend on `CSAuth`.

---

## [v1.0.0]

### Added
- **Workspace profiles** — create, unlock, lock, and delete AES-256 encrypted APFS sparse bundles.
- **Isolated HOME directories** — every app launched in a profile sees its volume as `$HOME`.
- **App launcher** — launch Microsoft Teams, Outlook, OneDrive, Edge, Slack, Zoom, and more scoped to a profile.
- **Per-profile Keychain** — credentials stored inside the encrypted volume; MSAL token caches fully isolated.
- **Compliance dashboard** — mount state, running apps, and compliance status at a glance.
- **Tamper-evident audit log** — HMAC-signed event log using GRDB with `DatabaseMigrator`.
- **GridlyAgent** LaunchAgent for background monitoring.
- **GridlyHelper** SMJobBless privileged helper for hdiutil operations.
- **GridlyMobile** — iPhone + iPad companion app (SwiftUI, `NavigationSplitView`).
- GitHub Actions CI (push) and release (tag) workflows.

---

## [v1.3.4]

### Fixed
- **Profiles lost on restart** — demo mode was writing the profile registry to a new random temp directory every launch. Now uses `~/Library/Application Support/Gridly/Demo/`, a stable path that survives app relaunches and updates.
- **Session email cannot be changed** — the status bar now shows a pencil icon (demo mode only) next to the signed-in email. Click it to type your own address; press Return or ✓ to confirm. The value is persisted in UserDefaults so it survives restarts. In production (MSAL-authenticated) mode the field remains read-only as it reflects your real Entra ID account.
- Demo profiles no longer start pre-filled with `jane.doe@contoso.com` — account identifier fields start blank so you fill in your own details.

