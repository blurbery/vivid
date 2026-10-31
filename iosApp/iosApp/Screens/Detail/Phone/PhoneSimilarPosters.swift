import SwiftUI

#if !os(tvOS)
/// A poster card for More Like This and collection rows. Studios & Networks
/// saves these as JSON, so the stored properties and their names stay fixed.
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

    /// The title, then the year when there is one.
    var spokenLabel: String {
        guard let year else { return title }
        return [title, String(year)].joined(separator: ", ")
    }
}

/// More Like This: library titles similar to this one. It shows a loading
/// strip, then the rail, and nothing at all when there are no suggestions.
struct MobileSimilarSection: View {
    let contentId: String
    let detail: ItemDetail
    let onSelect: (SimilarPosterItem) -> Void

    @State private var isLoading = true
    @State private var items: [SimilarPosterItem] = []
    @State private var loadedKey: String?

    var body: some View {
        let key = TVLibrarySimilarityStore.shared.contextKey + "|" + contentId
        if isLoading {
            VStack(alignment: .leading, spacing: 14) {
                header
                MobilePosterPlaceholder()
            }
            .task(id: key) { await load(key) }
        } else if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                header
                MobilePosterRail(items: items, onSelect: onSelect)
            }
            .task(id: key) { await load(key) }
        }
    }

    private var header: some View {
        MobileSectionHeader(title: Text("More Like This"))
            .padding(.horizontal, 16)
    }

    private func load(_ key: String) async {
        guard key != loadedKey else { return }
        loadedKey = key
        isLoading = true
        items = []
        let suggestions = try? await TVLibrarySimilarityStore.shared.suggestions(contentId: contentId, sourceDetail: detail)
        items = suggestions ?? []
        isLoading = false
    }
}

/// The TMDb collection a movie belongs to, under the collection's name.
struct MobileCollectionSection: View {
    let row: MovieCollectionRowStore.Row
    let currentContentId: String
    let onSelect: (SimilarPosterItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MobileSectionHeader(title: Text(verbatim: row.name))
                .padding(.horizontal, 16)
            MobilePosterRail(items: row.items) { item in
                // The movie being viewed is already open.
                guard item.contentId != currentContentId else { return }
                onSelect(item)
            }
        }
    }
}

/// A rail of poster cards sized by the card style setting.
struct MobilePosterRail: View {
    let items: [SimilarPosterItem]
    let onSelect: (SimilarPosterItem) -> Void

    @State private var preferences = UICustomizationPreferences.shared

    var body: some View {
        let presentation = preferences.cardPresentation
        let width = VividTheme.posterCardWidth * presentation.posterSize.scale
        let height = width * VividTheme.posterCardHeight / VividTheme.posterCardWidth
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: 12) {
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        card(item, width: width, height: height, caption: presentation.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: item.spokenLabel))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .phoneMediaRailBounds()
        }
    }

    private func card(_ item: SimilarPosterItem, width: CGFloat, height: CGFloat, caption: CardCaptionStyle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            poster(item, width: width, height: height)
            if caption.showsTitle {
                Text(verbatim: item.title)
                    .font(.vividSubheadline)
                    .foregroundStyle(Color.vividOnSurface)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if caption.showsMetadata, let year = item.year {
                Text(verbatim: String(year))
                    .font(.vividCaption)
                    .foregroundStyle(Color.vividSecondaryText)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func poster(_ item: SimilarPosterItem, width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
        if let url = item.posterUrl, !url.isEmpty {
            AsyncImageView(url: url, thumbhash: item.posterThumbhash, contentMode: .fill)
                .frame(width: width, height: height)
                .clipShape(shape)
        } else {
            shape
                .fill(Color.vividSurfaceElevated)
                .overlay {
                    Image(systemName: "film")
                        .foregroundStyle(Color.vividOnSurface.opacity(0.3))
                }
                .frame(width: width, height: height)
        }
    }
}

/// Four blank posters while suggestions load.
struct MobilePosterPlaceholder: View {
    @State private var preferences = UICustomizationPreferences.shared

    var body: some View {
        let scale = preferences.cardPresentation.posterSize.scale
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                        .fill(Color.vividSurfaceElevated)
                        .frame(
                            width: VividTheme.posterCardWidth * scale,
                            height: VividTheme.posterCardHeight * scale
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .allowsHitTesting(false)
    }
}
#endif
