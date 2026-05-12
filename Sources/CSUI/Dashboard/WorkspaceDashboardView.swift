import SwiftUI
import CSCore
import CSAudit
import CSWorkspace

public struct WorkspaceDashboardView: View {

    @ObservedObject public var viewModel: DashboardViewModel

    private let columns = [
        GridItem(.flexible(minimum: 220), spacing: 16),
        GridItem(.flexible(minimum: 220), spacing: 16),
        GridItem(.flexible(minimum: 220), spacing: 16),
    ]

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(viewModel: viewModel)
        } detail: {
            detailContent
        }
        .navigationTitle("Gridly")
        .toolbar { toolbarContent }
        .overlay { timeoutOverlay }
        .alert("Compliance Issue", isPresented: $viewModel.showComplianceAlert) {
            Button("View Details") { viewModel.selectedTab = .compliance }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(viewModel.complianceState.description)
        }
        .onAppear { viewModel.refresh() }
        // Inject the app's Azure AD client ID so CompanyProfileStatusView /
        // CompanyProfileWizardView use the correct registration when calling MSAL.
        .environment(\.entraClientID, viewModel.entraClientID)
    }

    // MARK: - Detail Router

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            WorkspaceStatusBar(viewModel: viewModel)

            Group {
                switch viewModel.selectedTab {
                case .dashboard:
                    dashboardGrid
                case .profiles:
                    if let pm = viewModel.profileManager {
                        ProfileSwitcherView(profileManager: pm)
                    } else {
                        unavailable("Profile Manager unavailable in demo mode.")
                    }
                case .apps:
                    dashboardGrid   // reuse for now — full Apps tab in a future sprint
                case .files:
                    SecureFileExplorerView(workspaceURL: URL(fileURLWithPath: NSHomeDirectory()))
                case .compliance:
                    complianceDetail
                case .audit:
                    AuditLogView(auditLogger: viewModel.auditLogger)
                case .privacy:
                    PrivacyTransparencyView()
                case .settings:
                    WorkspaceSettingsView()
                }
            }
        }
    }

    // MARK: - Dashboard Grid

    private var dashboardGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ComplianceStatusCard(state: viewModel.complianceState)
                SecurityStatusCard(
                    tamperOK: viewModel.tamperCheckPassed,
                    vpnActive: viewModel.vpnActive,
                    auditOK: viewModel.auditIntegrityClean
                )
                SessionInfoCard(session: viewModel.session)

                Section {
                    ForEach(viewModel.managedApps) { app in
                        ManagedAppCard(app: app) {
                            viewModel.launch(app)
                        }
                    }
                } header: {
                    Text("Managed Applications")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(3)
                        .padding(.top, 8)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Compliance Detail

    private var complianceDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ComplianceStatusCard(state: viewModel.complianceState)
                if let report = viewModel.complianceReport {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last Sync: \(report.lastSyncDateTime.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(report.noncompliantReasons) { reason in
                            Label(reason.displayName, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { viewModel.syncPolicy() } label: {
                Label("Sync Policy", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isSyncing)

            Button(role: .destructive) { viewModel.lockWorkspace() } label: {
                Label("Lock", systemImage: "lock.fill")
            }
            .keyboardShortcut("L", modifiers: [.command, .shift])
        }
    }

    // MARK: - Timeout Overlay

    @ViewBuilder
    private var timeoutOverlay: some View {
        if viewModel.lockCountdownSeconds > 0 && viewModel.lockCountdownSeconds <= 60 {
            SessionTimeoutOverlay(
                secondsRemaining: viewModel.lockCountdownSeconds,
                onExtend: { viewModel.extendSession() },
                onLock:   { viewModel.lockWorkspace() }
            )
            .transition(.opacity)
            .animation(.easeInOut, value: viewModel.lockCountdownSeconds)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        List(selection: $viewModel.selectedTab) {
            Label("Dashboard",   systemImage: "square.grid.2x2.fill").tag(Tab.dashboard)
            Label("Profiles",    systemImage: "person.2.badge.gearshape.fill").tag(Tab.profiles)
            Label("Apps",        systemImage: "app.fill").tag(Tab.apps)
            Label("Files",       systemImage: "folder.fill").tag(Tab.files)
            Label("Compliance",  systemImage: "checkmark.shield.fill").tag(Tab.compliance)
            Label("Audit Log",   systemImage: "list.bullet.clipboard.fill").tag(Tab.audit)
            Label("Privacy",     systemImage: "eye.slash.fill").tag(Tab.privacy)
            Label("Settings",    systemImage: "gearshape.fill").tag(Tab.settings)
        }
        .listStyle(.sidebar)
        .navigationTitle("Gridly")
    }
}

// MARK: - Status Bar

struct WorkspaceStatusBar: View {
    @ObservedObject var viewModel: DashboardViewModel

    @State private var editingUPN = false
    @State private var upnDraft   = ""
    @FocusState private var upnFieldFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isLocked ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(viewModel.isLocked ? "Locked" : "Active")
                    .font(.caption.weight(.medium))
            }

            Divider().frame(height: 14)

            HStack(spacing: 4) {
                Image(systemName: viewModel.complianceState.systemImage)
                    .foregroundStyle(viewModel.complianceState.color)
                    .font(.caption)
                Text(viewModel.complianceState.displayName)
                    .font(.caption)
            }

            Divider().frame(height: 14)

            HStack(spacing: 4) {
                Image(systemName: viewModel.vpnActive ? "network.badge.shield.half.filled" : "network.slash")
                    .font(.caption)
                    .foregroundStyle(viewModel.vpnActive ? .green : .secondary)
                Text(viewModel.vpnActive ? "VPN Active" : "No VPN")
                    .font(.caption)
                    .foregroundStyle(viewModel.vpnActive ? .primary : .secondary)
            }

            Spacer()

            // Session identity — editable in demo mode, read-only in production.
            sessionIdentityView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var sessionIdentityView: some View {
        if editingUPN {
            // Inline editor — shown only in demo mode when user taps the pencil
            HStack(spacing: 4) {
                TextField("your@work-email.com", text: $upnDraft)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .focused($upnFieldFocused)
                    .frame(minWidth: 160, maxWidth: 240)
                    .onSubmit { saveUPN() }

                Button(action: saveUPN) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Button {
                    editingUPN = false
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 4) {
                let upn = viewModel.session?.userPrincipalName ?? ""
                if upn.isEmpty {
                    Text(viewModel.isDemoMode ? "Set your email…" : "Not signed in")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    Text(upn)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Pencil affordance — only in demo mode
                if viewModel.isDemoMode {
                    Button {
                        upnDraft = viewModel.session?.userPrincipalName ?? ""
                        editingUPN = true
                        // Slight delay so the field renders before we request focus
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            upnFieldFocused = true
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func saveUPN() {
        viewModel.updateSessionIdentity(upn: upnDraft)
        editingUPN = false
    }
}

// MARK: - Tab Enum

public enum Tab: String, Hashable {
    case dashboard, profiles, apps, files, compliance, audit, privacy, settings
}
