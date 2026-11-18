import SwiftUI

/// Shared sizes, spacing and timing. Apple TV values are larger for viewing
/// from across the room.
enum VividTheme {
    #if os(tvOS)
    static let cornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 8
    static let cardCornerRadius: CGFloat = 18
    static let topBarIconHitSize: CGFloat = 44

    static let spacing: CGFloat = 24
    static let padding: CGFloat = 48
    static let smallPadding: CGFloat = 16
    static let largePadding: CGFloat = 60
    static let safePadding: CGFloat = 80

    static let posterCardWidth: CGFloat = 260
    static let posterCardHeight: CGFloat = 390
    /// A landscape card (Continue Watching, Next Up, episode rows and
    /// library cards) before Home's Large scale, which Home always uses:
    /// 400 by 222 points on screen.
    static let thumbnailCardWidth: CGFloat = 400 / CardPosterSize.large.scale
    static let thumbnailCardHeight: CGFloat = 222 / CardPosterSize.large.scale
    #else
    static let cornerRadius: CGFloat = 8
    static let smallCornerRadius: CGFloat = 6
    static let cardCornerRadius: CGFloat = 14
    static let topBarIconHitSize: CGFloat = 44

    static let spacing: CGFloat = 12
    static let padding: CGFloat = 16
    static let smallPadding: CGFloat = 8
    static let largePadding: CGFloat = 24
    static let safePadding: CGFloat = 16

    static let posterCardWidth: CGFloat = 120
    static let posterCardHeight: CGFloat = 198
    static let thumbnailCardWidth: CGFloat = 160
    static let thumbnailCardHeight: CGFloat = 90
    #endif

    static let backdropAspectRatio: CGFloat = 16 / 9

    static let fastDuration: Double = 0.12
    static let normalDuration: Double = 0.20
    static let slowDuration: Double = 0.30
    static let springAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.85)
}

#if os(tvOS)
extension VividTheme {
    /// The Apple TV shell bar and dense Home and collection grids.
    enum Skyline {
        static let safeAreaX: CGFloat = 88
        /// The bar hangs from the top edge as a notch, so pages take no
        /// extra inset for it.
        static let barTopInset: CGFloat = 0
        static let barHeight: CGFloat = 64
        static let tabSpacing: CGFloat = 8
        /// A poster in Home's rows and the rails that match them, on screen.
        static let railPosterWidth: CGFloat = 220
        /// The poster width of Home rows and the rails that match them,
        /// before Home's Large scale: 220 by 330 points on screen.
        static let densePosterCardWidth: CGFloat = railPosterWidth / CardPosterSize.large.scale
        /// A Cast & Crew photo on detail pages: 180 by 270 points.
        static let castPhotoWidth: CGFloat = 180
        /// Posters across a catalogue grid: Search, library pages, collection
        /// and studio pages. Seven across the 1,760-point safe width makes
        /// each poster about 217 by 326 points.
        static let posterGridColumns = 7
        /// The rows of a catalogue grid kept decoded around the screen. Eight
        /// rows of seven-across posters hold fewer decoded pixels than the
        /// earlier eight rows of six-across 260-point ones, so the band stays
        /// inside the decoded budget on Apple TVs with less memory.
        static let posterGridArtworkRows = 8
        /// The gap between a poster and its caption on Home's rows, which
        /// leaves room for the focus lift of a poster this size.
        static let posterCaptionGap: CGFloat = 24
        /// The same gap in grids and detail rails, whose cards sit closer
        /// together.
        static let posterGridCaptionGap: CGFloat = 20
        static let collectionGridColumnSpacing: CGFloat = 40
        static let collectionGridRowSpacing: CGFloat = 60
        static let collectionGridGroupHeaderSize: CGFloat = 22
    }
}
#endif
