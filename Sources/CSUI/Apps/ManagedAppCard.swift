import SwiftUI
import CSCore

public struct ManagedAppCard: View {

    let app: ManagedApp
    let onLaunch: () -> Void

    @State private var isHovered = false
    @State private var isLaunching = false

    public init(app: ManagedApp, onLaunch: @escaping () -> Void) {
        self.app = app
        self.onLaunch = onLaunch
    }

    public var body: some View {
        Button(action: handleLaunch) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(appGradient)
                        .frame(width: 52, height: 52)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

                    if isLaunching {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: app.iconSystemName)
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                    }
                }

                Text(app.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                installBadge
            }
            .frame(width: 88, height: 110)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(!app.isEnabled || app.installStatus == .notInstalled)
        .help(helpText)
    }

    @ViewBuilder
    private var installBadge: some View {
        switch app.installStatus {
        case .installed:
            EmptyView()
        case .notInstalled:
            Text("Not installed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .updateAvailable:
            Label("Update", systemImage: "arrow.up.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .installing:
            Label("Installing", systemImage: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .error:
            Label("Error", systemImage: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private var appGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors(for: app.category),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func gradientColors(for category: ManagedApp.AppCategory) -> [Color] {
        switch category {
        case .communication: return [.blue, .cyan]
        case .productivity:  return [.indigo, .purple]
        case .storage:       return [.teal, .green]
        case .security:      return [.orange, .red]
        case .internal_:     return [.gray, .secondary]
        }
    }

    private var helpText: String {
        switch app.installStatus {
        case .notInstalled: return "\(app.displayName) is not installed. Contact IT to install it."
        case .installed, .updateAvailable: return "Open \(app.displayName) in corporate workspace"
        case .installing: return "\(app.displayName) is being installed…"
        case .error: return "\(app.displayName) has an installation error. Contact IT support."
        }
    }

    private func handleLaunch() {
        guard !isLaunching else { return }
        isLaunching = true
        onLaunch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isLaunching = false
        }
    }
}

// MARK: - App Launcher Full View

public struct AppLauncherView: View {

    @ObservedObject var viewModel: DashboardViewModel
    @State private var searchText = ""
    @State private var selectedCategory: ManagedApp.AppCategory? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search + filter bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 16)

            // Category pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryPill(nil, label: "All")
                    ForEach(ManagedApp.AppCategory.allCases, id: \.self) { cat in
                        categoryPill(cat, label: cat.rawValue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            // App grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(filteredApps) { app in
                        ManagedAppCard(app: app) { viewModel.launch(app) }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Applications")
    }

    private var filteredApps: [ManagedApp] {
        viewModel.managedApps
            .filter { app in
                (selectedCategory == nil || app.category == selectedCategory) &&
                (searchText.isEmpty || app.displayName.localizedCaseInsensitiveContains(searchText))
            }
    }

    @ViewBuilder
    private func categoryPill(_ category: ManagedApp.AppCategory?, label: String) -> some View {
        Button {
            selectedCategory = category
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selectedCategory == category
                            ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(selectedCategory == category ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
