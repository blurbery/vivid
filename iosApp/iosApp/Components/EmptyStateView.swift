import SwiftUI

/// Displays a placeholder when a list or grid has no content.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.vividOnSurface.opacity(0.3))

            Text(title)
                .font(.vividSubheadline)
                .foregroundColor(.vividOnSurface)

            if let subtitle {
                Text(subtitle)
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, VividTheme.largePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
