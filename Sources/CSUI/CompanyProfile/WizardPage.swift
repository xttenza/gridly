import SwiftUI

// MARK: - WizardPage

/// Shared layout container used by all company-profile wizard views.
/// Renders a centred header (icon, title, subtitle) above arbitrary step content.
struct WizardPage<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(iconColor.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: icon)
                            .font(.system(size: 32))
                            .foregroundStyle(iconColor)
                    }
                    Text(title)
                        .font(.title2.weight(.bold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Step content
                content()
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }
}
