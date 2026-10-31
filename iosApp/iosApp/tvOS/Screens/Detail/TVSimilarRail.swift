#if os(tvOS)
import SwiftUI

/// A poster in the More Like This and collection rails. Studios & Networks
/// also saves these to disk, so the stored fields and their coding keys must
/// not change.
struct SimilarPosterItem: Identifiable, Hashable, Codable {
    let contentId: String
    let title: String
    let posterUrl: String?
    let posterThumbhash: String?
    let year: Int?

    var id: String { contentId }

    init(item: BrowseItem) {
        contentId = item.contentId
        title = item.title
        posterUrl = item.posterUrl
        posterThumbhash = item.posterThumbhash
        year = item.year
    }

    init(detail: ItemDetail) {
        contentId = detail.contentId
        title = detail.title
        posterUrl = detail.posterUrl
        posterThumbhash = detail.posterThumbhash
        year = detail.year
    }
}

/// Library titles like this one. Always present, so it can host its own
/// load; the heading and rail show only once suggestions exist.
struct TVMoreLikeThisSection: View {
    let sourceId: String
    let sourceDetail: ItemDetail?
    let onSelect: (String) -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @State private var items: [SimilarPosterItem] = []
    @State private var itemsContext: String?
    @State private var isLoading = false

    var body: some View {
        let store = TVLibrarySimilarityStore.shared
        let contextKey = store.contextKey
        VStack(alignment: .leading, spacing: 14) {
            if isLoading {
                TVDetailSectionHeader("More Like This")
                TVPosterRailPlaceholder()
            } else if !items.isEmpty, itemsContext == contextKey {
                TVDetailSectionHeader("More Like This")
                TVPosterRail(items: items, onSelect: { onSelect($0.contentId) }, onFocusChange: onFocusChange)
            }
        }
        .task(id: "\(sourceId)|\(contextKey)", priority: .userInitiated) {
            items = []
            isLoading = true
            let context = store.contextKey
            do {
                let result = try await store.suggestions(contentId: sourceId, sourceDetail: sourceDetail)
                guard !Task.isCancelled, store.contextKey == context else { return }
                items = result
                itemsContext = context
            } catch {
                guard !Task.isCancelled, store.contextKey == context else { return }
                items = []
            }
            isLoading = false
        }
    }
}

/// A TMDb collection the movie belongs to, with its library titles.
struct TVCollectionRailSection: View {
    let row: MovieCollectionRowStore.Row
    let currentContentId: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TVDetailSectionHeader(verbatim: row.name)
            TVPosterRail(items: row.items) { item in
                guard item.contentId != currentContentId else { return }
                onSelect(item.contentId)
            }
        }
    }
}

/// A row of library posters with Home's card size and captions.
struct TVPosterRail: View {
    let items: [SimilarPosterItem]
    let onSelect: (SimilarPosterItem) -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @State private var homeCards = TVHomeCardPreferences.shared
    @FocusState private var focusedId: String?

    var body: some View {
        let posterSize = homeCards.presentation.posterSize
        ScrollView(.horizontal) {
            LazyHStack(spacing: 44) {
                ForEach(items) { item in
                    TVMediaCard(
                        title: item.title,
                        posterUrl: item.posterUrl ?? "",
                        posterThumbhash: item.posterThumbhash,
                        year: item.year,
                        action: { onSelect(item) },
                        cardWidth: VividTheme.Skyline.densePosterCardWidth,
                        posterSize: posterSize,
                        leadingCaption: true,
                        focusBinding: $focusedId,
                        focusContentId: item.contentId
                    )
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .focusSection()
        .defaultFocus($focusedId, items.first?.contentId, priority: .userInitiated)
        .onChange(of: focusedId) { _, newValue in
            onFocusChange?(newValue != nil)
        }
    }
}

/// Four empty posters while More Like This loads.
private struct TVPosterRailPlaceholder: View {
    @State private var homeCards = TVHomeCardPreferences.shared

    var body: some View {
        let width = VividTheme.Skyline.densePosterCardWidth * homeCards.presentation.posterSize.scale
        ScrollView(.horizontal) {
            HStack(spacing: 44) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.vividSurfaceElevated)
                        .frame(width: width, height: width * 1.5)
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
    }
}
#endif
