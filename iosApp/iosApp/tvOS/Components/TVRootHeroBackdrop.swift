#if os(tvOS)
import SwiftUI

/// Backdrop geometry used by item details.
/// tvOS content is rendered in a 16:9 logical viewport, so deriving the
/// height from the available width keeps the artwork request, crop, and mask
/// identical even when the detail hero itself is shorter than the viewport.
enum TVBackdropArtworkLayout {
    static let widthFraction: CGFloat = 0.64
    static let heightFraction: CGFloat = 0.70

    static func artworkSize(forViewportWidth viewportWidth: CGFloat) -> CGSize {
        let viewportHeight = viewportWidth * 9 / 16
        return CGSize(
            width: viewportWidth * widthFraction,
            height: viewportHeight * heightFraction
        )
    }
}

/// Shared corner falloff for movie and series details and their loading state.
struct TVBackdropArtworkFadeMask: View {
    var softensLeadingFade = false
    var body: some View {
        LinearGradient(
            stops: softensLeadingFade ? [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.40),
                .init(color: .black.opacity(0.82), location: 0.58),
                .init(color: .black.opacity(0.46), location: 0.76),
                .init(color: .black.opacity(0.12), location: 0.92),
                .init(color: .clear, location: 1.0),
            ] : [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.32),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .trailing,
            endPoint: .leading
        )
        .mask {
            LinearGradient(
                stops: softensLeadingFade ? [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.32),
                    .init(color: .black.opacity(0.94), location: 0.46),
                    .init(color: .black.opacity(0.78), location: 0.60),
                    .init(color: .black.opacity(0.50), location: 0.73),
                    .init(color: .black.opacity(0.18), location: 0.85),
                    .init(color: .clear, location: 0.96),
                ] : [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.38),
                    .init(color: .black.opacity(0.88), location: 0.52),
                    .init(color: .black.opacity(0.58), location: 0.68),
                    .init(color: .black.opacity(0.24), location: 0.81),
                    // Reach zero before the detail hero's lower boundary so
                    // its clip can never reveal a straight artwork edge.
                    .init(color: .clear, location: 0.90),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

#endif
