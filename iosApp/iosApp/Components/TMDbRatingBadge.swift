import SwiftUI

/// TMDb's user score beside TMDb's Primary Short logo, for the detail page
/// metadata rows. The logo is two rows tall, so it is scaled to the row's
/// text height and stays about as wide as a quality badge.
struct TMDbRatingBadge: View {
    let rating: Double
    var logoHeight: CGFloat = 11
    var font: Font = .system(size: 14, weight: .semibold)
    var color: Color = .white

    static func label(for rating: Double) -> String {
        String(format: "%.1f", rating)
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
