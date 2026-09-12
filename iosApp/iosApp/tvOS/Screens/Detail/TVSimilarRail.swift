#if os(tvOS)
import SwiftUI

/// Horizontal poster rail of "More Like This" items used at the bottom
/// of the tvOS Movie / Series detail pages. Uses app-ranked suggestions
/// matched to the current server library, and renders `TVMediaCard` posters
/// so cards focus-lift consistently with the rest of the detail body.
///
/// The rail self-loads on appear and silently hides if the request
/// fails or returns nothing — recommendations are non-essential, so a
/// missing rail is preferable to an error placeholder. The section
/// header lives in here (not the parent) for the same reason: when
/// recommendations are disabled or empty, an orphaned "More Like This"
/// title must vanish along with the cards.
struct TVSimilarRail: View {
    let contentId: String
    let title: String
    var sourceDetail: ItemDetail? = nil
    let onSelect: (String) -> Void
    var focusRequest = 0

    @State private var items: [SimilarPosterItem] = []
    @State private var isLoading = false
    @State private var homeCards = TVHomeCardPreferences.shared
    private let library = TVLibrarySimilarityStore.shared
    @State private var resultContext = ""
    @State private var lastAppliedFocusRequest = 0
    @FocusState private var focusedItemId: String?

    private let cardWidth: CGFloat = VividTheme.Skyline.densePosterCardWidth
    private let cardSpacing: CGFloat = 44
    private let railVerticalPadding: CGFloat = 12
    /// Header-to-content gap, matching the other detail sections'
    /// `VStack(spacing: 28)` so the page rhythm stays uniform.
    private let headerSpacing: CGFloat = TVDetailLayout.sectionHeaderSpacing

    var body: some View {
        // Keep a mounted container even before results exist so the task runs.
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                section { loadingPlaceholder }
            } else if !items.isEmpty, resultContext == library.contextKey {
                section { rail }
            }
        }
        .task(id: contentId + library.contextKey, priority: .userInitiated) { await load() }
        .onChange(of: focusRequest, initial: true) { _, _ in
            applyFocusRequestIfPossible()
        }
        .onChange(of: items) { _, _ in
            applyFocusRequestIfPossible()
        }
    }

    private func section(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: headerSpacing) {
            TVSectionHeader(title: title)
            content()
        }
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(items) { item in
                    TVMediaCard(
                        title: item.title,
                        posterUrl: item.posterUrl ?? "",
                        posterThumbhash: item.posterThumbhash,
                        year: item.year,
                        action: { onSelect(item.contentId) },
                        cardWidth: cardWidth,
                        posterSize: homeCards.presentation.posterSize,
                        leadingCaption: true,
                        focusBinding: $focusedItemId,
                        focusContentId: item.contentId
                    )
                }
            }
            .padding(.vertical, railVerticalPadding)
        }
        .focusSection()
        // Land d-pad entry on the first card (like the cast/episode rails)
        // instead of letting tvOS pick the geometrically-nearest middle card.
        .applySimilarRailDefaultFocus(items.first?.contentId, binding: $focusedItemId)
        .scrollClipDisabled()
    }

    // MARK: - Loading placeholder

    private var loadingPlaceholder: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: cardSpacing) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                        .fill(Color.vividSurfaceElevated)
                        .frame(
                            width: cardWidth * homeCards.presentation.posterSize.scale,
                            height: cardWidth * homeCards.presentation.posterSize.scale * 1.5
                        )
                }
            }
            .padding(.vertical, railVerticalPadding)
        }
        .allowsHitTesting(false)
    }

    private func applyFocusRequestIfPossible() {
        guard focusRequest > 0,
              focusRequest != lastAppliedFocusRequest,
              let firstContentId = items.first?.contentId else { return }
        lastAppliedFocusRequest = focusRequest
        focusedItemId = firstContentId
    }

    // MARK: - Data loading

    private func load() async {
        items = []
        isLoading = false
        lastAppliedFocusRequest = 0
        let context = library.contextKey
        isLoading = true
        do {
            let result = try await library.suggestions(contentId: contentId, sourceDetail: sourceDetail)
            guard !Task.isCancelled, library.contextKey == context else { return }
            items = result
            resultContext = context
        } catch {
            guard !Task.isCancelled, library.contextKey == context else { return }
            items = []
        }
        isLoading = false
    }

}

private extension View {
    /// When focus enters the Recommended rail, land on the first card rather
    /// than the geometrically-nearest one. `.userInitiated` priority is what
    /// makes `defaultFocus` win over geometric proximity on d-pad entry — the
    /// same helper shape as `TVDetailCastRail.applyCastRailDefaultFocus`.
    /// No-op while loading / empty (first id is nil).
    @ViewBuilder
    func applySimilarRailDefaultFocus(
        _ firstContentId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let firstContentId {
            self.defaultFocus(binding, firstContentId, priority: .userInitiated)
        } else {
            self
        }
    }
}

// MARK: - Card model

/// View-side projection of an `ItemDetail` containing only what the
/// poster card needs. Decoupled so the card never re-renders when
/// unrelated detail fields change.
struct SimilarPosterItem: Identifiable, Hashable {
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
        self.contentId = detail.contentId
        self.title = detail.title
        self.posterUrl = detail.posterUrl
        self.posterThumbhash = detail.posterThumbhash
        self.year = detail.year
    }
}
#endif
