import SwiftUI

public struct SessionTimeoutOverlay: View {
    let secondsRemaining: Int
    let onExtend: () -> Void
    let onLock: () -> Void

    public var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Animated lock icon
                ZStack {
                    Circle()
                        .fill(.orange.opacity(0.15))
                        .frame(width: 100, height: 100)
                    Image(systemName: "lock.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.orange)
                        .opacity(secondsRemaining <= 10 ? (secondsRemaining % 2 == 0 ? 1.0 : 0.4) : 1.0)
                        .animation(.easeInOut(duration: 0.5).repeatForever(), value: secondsRemaining)
                }

                VStack(spacing: 8) {
                    Text("Workspace Locking Soon")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)

                    Text("Due to inactivity, your workspace will lock in")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))

                    Text("\(secondsRemaining)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(secondsRemaining <= 10 ? .red : .orange)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.easeInOut, value: secondsRemaining)

                    Text(secondsRemaining == 1 ? "second" : "seconds")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }

                HStack(spacing: 16) {
                    Button("Lock Now", action: onLock)
                        .buttonStyle(.bordered)
                        .foregroundStyle(.white)
                        .tint(.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.white.opacity(0.4))
                        }

                    Button("Stay Active", action: onExtend)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .keyboardShortcut(.return)
                }
                .controlSize(.large)
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 24)
        }
    }
}

// MARK: - Lock Screen View (shown when workspace is locked)

public struct WorkspaceLockScreenView: View {
    public let userPrincipalName: String
    public let onUnlock: () async throws -> Void

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    public init(userPrincipalName: String, onUnlock: @escaping () async throws -> Void) {
        self.userPrincipalName = userPrincipalName
        self.onUnlock = onUnlock
    }

    public var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo / Branding
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom)
                        )
                        .shadow(color: .blue.opacity(0.3), radius: 12)

                    Text("Gridly")
                        .font(.largeTitle.weight(.bold))

                    Text("Locked")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                // User info
                VStack(spacing: 6) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(userPrincipalName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Unlock button
                VStack(spacing: 12) {
                    Button {
                        Task { await authenticate() }
                    } label: {
                        HStack {
                            if isAuthenticating {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "touchid")
                            }
                            Text(isAuthenticating ? "Authenticating…" : "Unlock with Touch ID")
                        }
                        .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isAuthenticating)
                    .keyboardShortcut(.return)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer()

                // Footer
                Text("Gridly • Workspace Protected")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, 16)
            }
            .padding(40)
        }
    }

    private func authenticate() async {
        isAuthenticating = true
        errorMessage = nil
        do {
            try await onUnlock()
        } catch {
            errorMessage = error.localizedDescription
        }
        isAuthenticating = false
    }
}
