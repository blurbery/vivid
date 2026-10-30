import SwiftUI

/// A centred symbol, title and optional subtitle for a page with nothing to
/// show. Fills the space it's offered.
struct EmptyStateView: View {
    private let icon: String
    private let title: Text
    private let subtitle: Text?

    init(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.icon = icon
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
    }

    /// Shows the text as it is. Disfavoured so literals stay localised.
    @_disfavoredOverload
    init<S: StringProtocol>(icon: String, title: S, subtitle: String? = nil) {
        self.icon = icon
        self.title = Text(verbatim: String(title))
        self.subtitle = subtitle.map { Text(verbatim: $0) }
    }

    init(icon: String, title: Text, subtitle: Text? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.vividOnSurface.opacity(0.3))
            title
                .font(.vividSubheadline)
                .foregroundStyle(Color.vividOnSurface)
            if let subtitle {
                subtitle
                    .font(.vividCaption)
                    .foregroundStyle(Color.vividSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, VividTheme.largePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The full-page loading screen: the animated mark over the page backdrop.
struct LoadingView: View {
    var usesPageBackground: Bool = false

    var body: some View {
        ZStack {
            VividPageBackdrop()
            VStack(spacing: 20) {
                VividGlideLogo(size: 132)
                ProgressView()
                    .tint(Color.vividOnSurface)
                    .scaleEffect(1.2)
            }
        }
    }
}
