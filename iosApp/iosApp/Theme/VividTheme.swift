import SwiftUI

/// Central design token repository for Vivid’s monochrome theme.
/// On tvOS, spacing/radius tokens are scaled up to match 10-foot viewing distance.
struct VividTheme {

    // MARK: - Corner Radii

    #if os(tvOS)
    /// Standard card/poster corner radius (12pt on tvOS, larger so focus rings read well)
    static let cornerRadius: CGFloat = 12
    /// Smaller elements like episode thumbnail corners
    static let smallCornerRadius: CGFloat = 8
    /// Card container radius
    static let cardCornerRadius: CGFloat = 18
    #else
    /// Standard card/poster corner radius (8pt)
    static let cornerRadius: CGFloat = 8
    /// Smaller elements like episode thumbnail corners (6pt)
    static let smallCornerRadius: CGFloat = 6
    /// Card container radius (14pt)
    static let cardCornerRadius: CGFloat = 14
    #endif

    // MARK: - Top Bar

    /// Tap-target frame for chrome-free top-bar icon buttons (Search / Cast).
    /// The glyph stays small; the frame keeps a comfortable 44pt hit area and
    /// sets the rhythm for the evenly spaced top-right cluster.
    static let topBarIconHitSize: CGFloat = 44
    /// Gap between top-bar action items (cast / search / profile). Tuned so the
    /// visible spacing between glyphs reads like Plex's top-right cluster.
    static let topBarIconSpacing: CGFloat = 2

    // MARK: - Spacing

    #if os(tvOS)
    /// Base spacing unit — scaled up for TV
    static let spacing: CGFloat = 24
    /// Standard content padding
    static let padding: CGFloat = 48
    /// Compact padding
    static let smallPadding: CGFloat = 16
    /// Large section spacing
    static let largePadding: CGFloat = 60
    /// Screen safe-area padding — tvOS always wants overscan
    static let safePadding: CGFloat = 80
    #else
    /// Base spacing unit (12pt)
    static let spacing: CGFloat = 12
    /// Standard content padding (16pt)
    static let padding: CGFloat = 16
    /// Compact padding (8pt)
    static let smallPadding: CGFloat = 8
    /// Large section spacing (24pt)
    static let largePadding: CGFloat = 24
    /// No extra overscan padding on iOS
    static let safePadding: CGFloat = 16
    #endif

    // MARK: - Media Aspect Ratios

    /// Backdrop/banner image (16:9)
    static let backdropAspectRatio: CGFloat = 16.0 / 9.0

    // MARK: - Media Card Dimensions

    #if os(tvOS)
    /// Poster card width in a media row
    static let posterCardWidth: CGFloat = 260
    /// Poster card height matching aspect ratio
    static let posterCardHeight: CGFloat = 390
    /// Episode/thumbnail card width
    static let thumbnailCardWidth: CGFloat = 360
    /// Episode/thumbnail card height
    static let thumbnailCardHeight: CGFloat = 200
    #else
    static let posterCardWidth: CGFloat = 120
    static let posterCardHeight: CGFloat = 198
    static let thumbnailCardWidth: CGFloat = 160
    static let thumbnailCardHeight: CGFloat = 90
    #endif

    // MARK: - Animation Durations

    /// Fast — focus state changes, hover effects (120ms)
    static let fastDuration: Double = 0.12

    /// Normal — tab transitions, chip selection (200ms)
    static let normalDuration: Double = 0.20

    /// Slow — image crossfades, content reveals (300ms)
    static let slowDuration: Double = 0.30

    /// Standard spring animation
    static let springAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)

    #if os(tvOS)
    // MARK: - Skyline chrome metrics (tvOS)

    /// Skyline navigation chrome tokens (design guide §4–§5). Values are
    /// mockup pixels at 1920×1080, which render 1:1 as points on tvOS.
    enum Skyline {
        /// Root horizontal inset for chrome and content — `safeArea.x`.
        static let safeAreaX: CGFloat = 88
        /// Top bar offset from the screen's top edge — `safeArea.top`.
        static let barTopInset: CGFloat = 56
        /// Top bar row height.
        static let barHeight: CGFloat = 64
        /// Gap between tab capsules in the bar's center cluster.
        static let tabSpacing: CGFloat = 8

        /// Top inset for library-tab content that has no hero of its own
        /// (grids, chip clouds): clears the bar and the pill row.
        static let libraryContentTopInset: CGFloat = 216

        /// Poster width shared by Home and related-title rows.
        static let densePosterCardWidth: CGFloat = 176

        // MARK: Collections poster grid (§6.3)

        /// Collections render as standard 2:3 poster tiles (the canonical
        /// `posterCardWidth` poster) in a grid that mirrors the library Browse
        /// grid, so a collection reads as a first-class browseable card.
        /// 6 flexible columns within the safe area.
        static let collectionGridColumnCount = 6
        static let collectionGridColumnSpacing: CGFloat = 40
        static let collectionGridRowSpacing: CGFloat = 60
        /// Mono group-header size for the collections grid (§6.3, mono
        /// header style — the dropdown mono grammar at grid scale).
        static let collectionGridGroupHeaderSize: CGFloat = 22
    }
    #endif
}
