import SwiftUI

/// Size-class-aware poster grid columns.
///
/// iPhone portrait and iPad in narrow split view report `.compact` and get
/// 3 columns — matching the original iPhone-only layout. iPad full-screen
/// and landscape report `.regular` and get 5 columns, so posters render at
/// their intended density instead of stretching to nearly 2× width.
///
enum AdaptiveColumns {
    /// iPad grids fill their container with evenly sized posters and small gaps.
    static func tabletPosterCount(containerWidth: CGFloat, spacing: CGFloat = 8) -> Int {
        max(1, Int((max(1, containerWidth) + spacing) / (160 + spacing)))
    }

    static func tabletPosterWidth(containerWidth: CGFloat, spacing: CGFloat = 8) -> CGFloat {
        let count = tabletPosterCount(containerWidth: containerWidth, spacing: spacing)
        return max(1, (containerWidth - CGFloat(count - 1) * spacing) / CGFloat(count))
    }

    static func posters(
        for sizeClass: UserInterfaceSizeClass?,
        posterSize: CardPosterSize = .standard,
        spacing: CGFloat = 12
    ) -> [GridItem] {
        let standardCount = (sizeClass == .regular) ? 5 : 3
        let count: Int
        switch posterSize {
        case .compact:
            count = sizeClass == .regular ? standardCount + 1 : standardCount
        case .standard:
            count = standardCount
        case .large:
            count = max(2, standardCount - 1)
        }
        return Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: count
        )
    }

    /// Keeps tvOS poster grids dense enough for compact artwork while making
    /// room for large artwork and its native focus lift. Six columns is the
    /// safe upper bound inside the standard 1,760-point content width.
    static func tvPosterCount(
        standardCount: Int,
        posterSize: CardPosterSize,
        minimumCount: Int = 3
    ) -> Int {
        switch posterSize {
        case .compact:
            return min(6, standardCount + 1)
        case .standard:
            return standardCount
        case .large:
            return max(minimumCount, standardCount - 1)
        }
    }

    /// Fits a fixed-density grid card inside its actual container while
    /// preserving the standard poster width whenever enough room is available.
    static func fittedPosterWidth(
        containerWidth: CGFloat,
        columnCount: Int,
        spacing: CGFloat,
        maximumWidth: CGFloat = VividTheme.posterCardWidth
    ) -> CGFloat {
        guard containerWidth > 0, columnCount > 0 else { return maximumWidth }
        let totalSpacing = CGFloat(max(0, columnCount - 1)) * spacing
        let availableWidth = max(1, containerWidth - totalSpacing)
        return min(maximumWidth, availableWidth / CGFloat(columnCount))
    }
}

extension View {
    /// Caps form/content width so text fields and buttons don't stretch
    /// edge-to-edge on iPad. iPhones are already narrower than the cap, so
    /// this is a no-op on phone. The second `frame` centers the capped view.
    func vividFormWidth(_ maxWidth: CGFloat = 600) -> some View {
        self
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
