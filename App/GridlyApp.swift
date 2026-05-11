import SwiftUI
import os.log
import CSCore
import CSCrypto
import CSAuth
import CSWorkspace
import CSPolicy
import CSGraph
import CSAudit
import CSUI

private let log = Logger(subsystem: "com.gridly", category: "App")

/// True when launched with `--demo` OR when Gridly-Config.plist is absent.
/// Set to `true` early in AppDelegate.applicationWillFinishLaunching before the
/// window hierarchy reads it.
var isDemoMode = CommandLine.arguments.contains("--demo")

@main
struct GridlyApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Gridly") {
            if isDemoMode {
                DemoRootView()
            } else {
                RootView(container: delegate.container)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {}
            workspaceCommands
        }
    }

    private var workspaceCommands: some Commands {
        CommandMenu("Workspace") {
            Button("Lock Workspace") {
                if isDemoMode {
                    DemoState.shared.viewModel.lockWorkspace()
                } else {
                    delegate.container.dashboardViewModel.lockWorkspace()
                }
            }
            .keyboardShortcut("L", modifiers: [.command, .shift])

            Divider()

            Button("Sync Policy") {
                if isDemoMode {
                    DemoState.shared.viewModel.syncPolicy()
                } else {
                    delegate.container.dashboardViewModel.syncPolicy()
                }
            }
            .keyboardShortcut("R", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Demo Mode Root

/// Singleton so the view model survives SwiftUI view recreation.
@MainActor final class DemoState: ObservableObject {
    static let shared = DemoState()
    lazy var viewModel = DashboardViewModel.demo()
}

struct DemoRootView: View {
    @StateObject private var state = DemoState.shared
    private var vm: DashboardViewModel { state.viewModel }

    var body: some View {
        Group {
            if vm.isLocked {
                WorkspaceLockScreenView(
                    userPrincipalName: vm.session?.userPrincipalName ?? "demo@contoso.com"
                ) {
                    // In demo: unlock instantly
                    vm.isLocked = false
                }
            } else {
                WorkspaceDashboardView(viewModel: vm)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.isLocked)
    }
}

// MARK: - Root View (auth gate)

struct RootView: View {
    let container: AppContainer

    @State private var authState: AuthState = .checkingAuth

    enum AuthState {
        case checkingAuth
        case unauthenticated
        case authenticated
        case enrolling
    }

    var body: some View {
        Group {
            switch authState {
            case .checkingAuth:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Starting Gridly…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .unauthenticated:
                EnrollmentView(container: container) { session in
                    container.onAuthenticated(session: session)
                    authState = .authenticated
                }

            case .authenticated:
                if container.dashboardViewModel.isLocked {
                    WorkspaceLockScreenView(
                        userPrincipalName: container.dashboardViewModel.session?.userPrincipalName ?? ""
                    ) {
                        try await container.unlock()
                    }
                    .transition(.opacity)
                } else {
                    WorkspaceDashboardView(viewModel: container.dashboardViewModel)
                        .transition(.opacity)
                }

            case .enrolling:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Enrolling device with Intune…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: authState)
        .task { await checkInitialAuth() }
    }

    private func checkInitialAuth() async {
        do {
            let session = try await container.authProvider.acquireTokenSilent()
            container.onAuthenticated(session: session)
            authState = .authenticated
        } catch {
            authState = .unauthenticated
        }
    }
}

// MARK: - Enrollment View

struct EnrollmentView: View {
    let container: AppContainer
    let onSuccess: (WorkspaceSession) -> Void

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 80))
                .foregroundStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
                .shadow(color: .blue.opacity(0.3), radius: 16)

            VStack(spacing: 8) {
                Text("Gridly")
                    .font(.largeTitle.weight(.bold))
                Text("Sign in with your organizational account to access your secure workspace.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        if isAuthenticating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "person.badge.shield.checkmark.fill")
                        }
                        Text(isAuthenticating ? "Signing in…" : "Sign in with Microsoft")
                    }
                    .frame(minWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }

            Spacer()

            Text("By signing in you agree to your organization's Acceptable Use Policy.")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .padding(.bottom, 16)
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 480)
    }

    private func signIn() async {
        isAuthenticating = true
        errorMessage = nil
        do {
            guard let window = NSApp.keyWindow else { throw CSError.internalError("No window") }
            let session = try await container.authProvider.acquireTokenInteractive(presentingWindow: window)
            onSuccess(session)
        } catch {
            errorMessage = error.localizedDescription
        }
        isAuthenticating = false
    }
}
