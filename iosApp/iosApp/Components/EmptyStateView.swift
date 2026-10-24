import SwiftUI

/// Displays a placeholder when a list or grid has no content.
struct EmptyStateView: View {
    let icon: String
    private let title: Text
    private let subtitle: Text?

    init(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(icon: icon, title: Text(title), subtitle: subtitle.map { Text($0) })
    }

    /// Shown verbatim. Disfavoured so literals take the localised init, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(icon: String, title: S, subtitle: String? = nil) {
        self.init(icon: icon, title: Text(title), subtitle: subtitle.map { Text($0) })
    }

    /// Mixes a localised and a verbatim string, e.g. `Text("Title")` and `Text(value)`.
    init(icon: String, title: Text, subtitle: Text? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.vividOnSurface.opacity(0.3))

            title
                .font(.vividSubheadline)
                .foregroundColor(.vividOnSurface)

            if let subtitle {
                subtitle
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, VividTheme.largePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
