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
    static let thumbnailCardWidth: CGFloat = 360
    static let thumbnailCardHeight: CGFloat = 200
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
        static let barTopInset: CGFloat = 56
        static let barHeight: CGFloat = 64
        static let tabSpacing: CGFloat = 8
        static let densePosterCardWidth: CGFloat = 176
        static let collectionGridColumnSpacing: CGFloat = 40
        static let collectionGridRowSpacing: CGFloat = 60
        static let collectionGridGroupHeaderSize: CGFloat = 22
    }
}
#endif
