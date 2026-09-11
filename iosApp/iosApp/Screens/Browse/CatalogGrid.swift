import SwiftUI

/// A poster grid — 3 columns on iPhone / iPad compact width, 5 on iPad
/// regular width, 6 columns on tvOS. Cards handle their own focus lift on
/// tvOS.
struct CatalogGrid: View {
    let items: [BrowseItem]
    let isLoading: Bool
    let hasMore: Bool
    /// Search and library grids stay three-up on iPhone and compact iPad
    /// windows, independently of the shared card preference.
    var forcesThreeColumnsOnPhone = false
    var cardTitleFont: Font = .vividSubheadline
    let onItemTap: (BrowseItem) -> Void
    let onLoadMore: () -> Void
    @Environment(AppRouter.self) private var router
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    #if !os(tvOS)
    @State private var detailBrowseOriginID = UUID().uuidString
    @State private var detailBrowseSource: ItemDetailBrowseSource?
    #endif

    #if os(tvOS)
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 40, alignment: .top),
            count: AdaptiveColumns.tvPosterCount(
                standardCount: 6,
                posterSize: uiCustomization.cardPresentation.posterSize
            )
        )
    }
    private let rowSpacing: CGFloat = 60
    #else
    @Environment(\.horizontalSizeClass) private var hSize
    private var columns: [GridItem] {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                         count: AdaptiveColumns.tabletPosterCount(containerWidth: gridWidth))
        }
        #endif
        if usesThreeColumnPhoneLayout {
            return Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                count: 3
            )
        }
        return AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize,
            spacing: 8
        )
    }
    private let rowSpacing: CGFloat = 12
    #endif

    var body: some View {
        LazyVGrid(columns: columns, spacing: rowSpacing) {
            ForEach(items) { item in
                MediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    thumbhash: item.posterThumbhash,
                    year: item.year,
                    userState: item.userState,
                    overlayData: OverlayData.from(item),
                    titleFont: cardTitleFont,
                    action: { onItemTap(item) },
                    playAction: playAction(for: item),
                    contentId: item.contentId,
                    cardWidthOverride: gridCardWidthOverride
                )
                .frame(maxWidth: .infinity)
                .onAppear {
                    if item.id == items.suffix(6).first?.id, hasMore {
                        onLoadMore()
                    }
                }
            }
        }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - gridWidth) >= 0.5 else { return }
            gridWidth = width
        }
        #endif
        #if !os(tvOS)
        .scrollTargetLayout()
        .environment(\.itemDetailBrowseSource, detailBrowseSource)
        .onChange(of: items.map(\.contentId), initial: true) { _, contentIDs in
            detailBrowseSource = ItemDetailBrowseSource(
                originID: detailBrowseOriginID,
                contentIDs: contentIDs
            )
        }
        #endif

        if isLoading {
            HStack {
                Spacer()
                ProgressView()
                    .tint(.vividOnSurface)
                    .padding()
                Spacer()
            }
        }
    }

    private func playAction(for item: BrowseItem) -> (() -> Void)? {
        #if os(tvOS)
        guard VividMediaType.isDirectlyPlayable(item.type) else { return nil }
        return {
            router.presentPlayer(
                contentId: item.contentId,
                posterURL: item.posterUrl,
                backdropURL: item.backdropUrl
            )
        }
        #else
        return nil
        #endif
    }

    private var usesThreeColumnPhoneLayout: Bool {
        #if os(iOS)
        forcesThreeColumnsOnPhone && (UIDevice.current.userInterfaceIdiom == .phone || hSize != .regular)
        #else
        false
        #endif
    }

    /// MediaCard applies the global poster-size scale after its override. Undo
    /// that scale here, then cap the standard width to the measured grid cell.
    private var gridCardWidthOverride: CGFloat? {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return AdaptiveColumns.tabletPosterWidth(containerWidth: gridWidth)
                / uiCustomization.cardPresentation.posterSize.scale
        }
        let fittedWidth = AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: columns.count,
            spacing: 8
        )
        return fittedWidth / uiCustomization.cardPresentation.posterSize.scale
        #else
        return nil
        #endif
    }
}
