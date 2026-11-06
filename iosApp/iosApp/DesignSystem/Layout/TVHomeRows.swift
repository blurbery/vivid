#if os(tvOS)
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Set by Apple TV Home rows so cards reserve fixed caption heights and
    /// rows keep their height while artwork and text load.
    @Entry var tvHomeStableRows = false

    /// Set by Apple TV Home rows holding an episode, so every card keeps
    /// room for the episode line that Title Only still shows.
    @Entry var tvHomeRowHasEpisodes = false
}

extension ResolvedSection {
    /// Whether any card in the row is an episode.
    var tvHomeHasEpisodes: Bool { items.contains(where: EpisodeCardCaption.isEpisode) }
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

    /// The height of a whole row of cards, padding included. Rows holding an
    /// episode keep room for the episode line.
    static func stripHeight(
        layout: MediaRowLayout,
        posterWidth: CGFloat,
        presentation: CardPresentationPreference,
        hasEpisodes: Bool = false
    ) -> CGFloat {
        let scale = presentation.posterSize.scale
        let caption = presentation.caption.forEpisodes(hasEpisodes)
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
        if caption.showsTitle {
            height += captionGap + captionHeight(caption)
        }
        return height + cardPadding * 2
    }

    private static func lineHeight(size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        UIFont.systemFont(ofSize: size, weight: weight).lineHeight.rounded(.up)
    }
}
#endif
