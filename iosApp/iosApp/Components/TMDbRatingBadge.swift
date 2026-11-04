import SwiftUI

/// A loaded score tied to its title and TMDb connection, so a reused view
/// never shows another title's score, or one from a connection or profile
/// that has since changed.
struct TMDbRatingResult {
    let contentId: String
    let context: String
    let value: Double

    @MainActor
    func value(for contentId: String) -> Double? {
        guard self.contentId == contentId, context == TVTMDbStore.shared.contextKey else { return nil }
        return value
    }
}

/// TMDb's user score beside TMDb's Primary Short logo, for the detail page
/// metadata rows. The logo is two rows tall, so it is scaled to the row's
/// text height and stays about as wide as a quality badge.
struct TMDbRatingBadge: View {
    let rating: Double
    var logoHeight: CGFloat = 11
    var font: Font = .system(size: 14, weight: .semibold)
    var color: Color = .white

    /// One decimal place with a full stop in every language, as TMDb shows it.
    static func label(for rating: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rating)
    }

    var body: some View {
        HStack(spacing: logoHeight * 0.35) {
            Image("TMDbRatingMark")
                .resizable()
                .scaledToFit()
                .frame(height: logoHeight)
            Text(Self.label(for: rating))
                .font(font)
                .foregroundStyle(color)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TMDb rating \(Self.label(for: rating)) out of 10")
    }
}
