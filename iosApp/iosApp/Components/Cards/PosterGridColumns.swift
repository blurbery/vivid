import SwiftUI

/// Column counts and poster widths for catalogue grids.
enum AdaptiveColumns {
    static func tabletPosterCount(containerWidth: CGFloat, spacing: CGFloat = 8) -> Int {
        max(1, Int((max(1, containerWidth) + spacing) / (160 + spacing)))
    }

    static func tabletPosterWidth(containerWidth: CGFloat, spacing: CGFloat = 8) -> CGFloat {
        cellWidth(containerWidth, count: tabletPosterCount(containerWidth: containerWidth, spacing: spacing), spacing: spacing)
    }

    static func duoPosterCount(containerWidth: CGFloat, spacing: CGFloat = 8) -> Int {
        max(3, Int((max(1, containerWidth) + spacing) / (125 + spacing)))
    }

    static func duoPosterWidth(containerWidth: CGFloat, spacing: CGFloat = 8) -> CGFloat {
        cellWidth(containerWidth, count: duoPosterCount(containerWidth: containerWidth, spacing: spacing), spacing: spacing)
    }

    static func posters(
        for sizeClass: UserInterfaceSizeClass?,
        posterSize: CardPosterSize = .standard,
        spacing: CGFloat = 12
    ) -> [GridItem] {
        let isRegular = sizeClass == .regular
        let base = isRegular ? 5 : 3
        let count: Int
        switch posterSize {
        case .compact: count = isRegular ? base + 1 : base
        case .standard: count = base
        case .large: count = max(2, base - 1)
        }
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
    }

    static func tvPosterCount(standardCount: Int, posterSize: CardPosterSize, minimumCount: Int = 3) -> Int {
        switch posterSize {
        case .compact: min(6, standardCount + 1)
        case .standard: standardCount
        case .large: max(minimumCount, standardCount - 1)
        }
    }

    static func fittedPosterWidth(
        containerWidth: CGFloat,
        columnCount: Int,
        spacing: CGFloat,
        maximumWidth: CGFloat? = VividTheme.posterCardWidth
    ) -> CGFloat {
        guard containerWidth > 0, columnCount > 0 else { return maximumWidth ?? VividTheme.posterCardWidth }
        let available = max(1, containerWidth - CGFloat(columnCount - 1) * spacing)
        let cell = available / CGFloat(columnCount)
        return min(maximumWidth ?? cell, cell)
    }

    private static func cellWidth(_ containerWidth: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        max(1, (containerWidth - CGFloat(count - 1) * spacing) / CGFloat(count))
    }
}

/// The artwork shape a Home row uses.
enum MediaRowLayout {
    case poster
    case thumbnail
}
