#if os(tvOS)
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Set by Apple TV Home rows so cards reserve fixed caption heights and
    /// rows keep their height while artwork and text load.
    @Entry var tvHomeStableRows = false
}

/// Fixed measurements for Apple TV Home rows, worked out from the fonts the
/// cards use.
enum TVHomeRowGeometry {
    static let headingHeight: CGFloat = lineHeight(size: 36, weight: .semibold)
    static let headingSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 30
    static let cardPadding: CGFloat = 24

    private static let titleHeight: CGFloat = lineHeight(size: 20, weight: .medium)
    private static let metadataHeight: CGFloat = lineHeight(size: 18, weight: .regular)
    private static let titleToMetadata: CGFloat = 4
    private static let posterCaptionGap: CGFloat = 22
    private static let thumbnailCaptionGap: CGFloat = 14

    static func captionHeight(_ style: CardCaptionStyle) -> CGFloat {
        guard style.showsTitle else { return 0 }
        guard style.showsMetadata else { return titleHeight }
        return titleHeight + titleToMetadata + metadataHeight
    }

    /// The height of a whole row of cards, padding included.
    static func stripHeight(layout: MediaRowLayout, posterWidth: CGFloat, presentation: CardPresentationPreference) -> CGFloat {
        let scale = presentation.posterSize.scale
        let artworkHeight: CGFloat
        let captionGap: CGFloat
        switch layout {
        case .poster:
            artworkHeight = posterWidth * scale * VividTheme.posterCardHeight / VividTheme.posterCardWidth
            captionGap = posterCaptionGap
        case .thumbnail:
            artworkHeight = VividTheme.thumbnailCardHeight * scale
            captionGap = thumbnailCaptionGap
        }
        var height = artworkHeight
        if presentation.caption.showsTitle {
            height += captionGap + captionHeight(presentation.caption)
        }
        return height + cardPadding * 2
    }

    private static func lineHeight(size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        UIFont.systemFont(ofSize: size, weight: weight).lineHeight.rounded(.up)
    }
}
#endif
