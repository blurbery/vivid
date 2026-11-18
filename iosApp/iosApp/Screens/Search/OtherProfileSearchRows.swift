import SwiftUI

/// The other saved profiles' titles under Search's results: one row per
/// profile, headed by its picture and name. A title opens on its own
/// profile, and the heading runs the same search there.
struct OtherProfileSearchRows: View {
    let rows: [OtherProfileResults]
    let query: String

    @Environment(AppRouter.self) private var router

    #if os(tvOS)
    private let rowSpacing: CGFloat = 24
    #else
    private let rowSpacing: CGFloat = 16
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(rows) { row in
                OtherProfileSearchRow(
                    row: row,
                    onSearch: { search(in: row.account) },
                    onOpen: { open($0, in: row.account) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func search(in account: TVSavedAccount) {
        let query = query
        Task { await TVSavedAccountStore.shared.search(query, in: account, router: router) }
    }

    private func open(_ item: BrowseItem, in account: TVSavedAccount) {
        Task { await TVSavedAccountStore.shared.openSearchResult(item, in: account, router: router) }
    }
}

/// One other profile's heading and the row of titles it found.
private struct OtherProfileSearchRow: View {
    let row: OtherProfileResults
    let onSearch: () -> Void
    let onOpen: (BrowseItem) -> Void

    /// A card's identity: two profiles on one Silo server find the same
    /// content IDs, so each card is named by its profile too.
    private struct Card: Identifiable {
        let id: String
        let item: BrowseItem
    }

    #if os(tvOS)
    @State private var homeCards = TVHomeCardPreferences.shared
    private let headerGap: CGFloat = 14
    #else
    private let headerGap: CGFloat = 10
    #endif

    private var account: TVSavedAccount { row.account }

    private var cards: [Card] {
        row.items.map { Card(id: account.id + "|" + $0.contentId, item: $0) }
    }

    /// The account's own server, for poster paths given relative to it. The
    /// cards would otherwise resolve them against the signed-in server.
    private var serverURL: URL? {
        ServerRegistry.shared.entry(with: account.serverID).flatMap { URL(string: $0.url) }
    }

    private func posterURL(_ item: BrowseItem) -> String {
        guard let raw = item.posterUrl, !raw.isEmpty else { return "" }
        return SiloAPICompatibility.artworkURL(raw, relativeTo: serverURL)?.absoluteString ?? ""
    }

    private var searchLabel: String {
        String(
            localized: "Search in \(account.displayName) on \(account.serverLabel)",
            comment: "Accessibility label for a saved profile's heading under Search's results, which switches to that profile and runs the same search there. The second value is the profile's server name, for example Emby"
        )
    }

    var body: some View {
        #if os(tvOS)
        stack
            .focusSection()
        #else
        stack
        #endif
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: headerGap) {
            header
            rail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(tvOS)
    // MARK: Apple TV

    /// Its own full-width focus section, so Down from any column of the grid
    /// above lands here.
    private var header: some View {
        Button(action: onSearch) {
            HStack(spacing: 14) {
                SavedAccountAvatar(account: account, size: 36)
                    .accessibilityHidden(true)
                Text(verbatim: account.displayName)
                // The server's nickname, as Who's watching shows it, so two
                // profiles with the same name can be told apart.
                Text(verbatim: account.serverLabel)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(TVBrowseControlPillStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: searchLabel))
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// Laid out like More Like This. The cards get no content ID, focus
    /// binding or play action: those would act on the signed-in profile.
    private var rail: some View {
        let posterSize = homeCards.presentation.posterSize
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 44) {
                ForEach(cards) { card in
                    TVMediaCard(
                        title: card.item.title,
                        posterUrl: posterURL(card.item),
                        posterThumbhash: card.item.posterThumbhash,
                        year: card.item.year,
                        yearCaption: card.item.posterYearCaption,
                        userState: card.item.userState,
                        action: { onOpen(card.item) },
                        cardWidth: VividTheme.Skyline.densePosterCardWidth,
                        posterSize: posterSize,
                        reportsAdaptiveFocus: true
                    )
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .focusSection()
    }
    #else
    // MARK: iPhone and iPad

    private var header: some View {
        Button(action: onSearch) {
            HStack(spacing: 8) {
                SavedAccountAvatar(account: account, size: 28)
                Text(verbatim: account.displayName)
                    .font(.vividHeadline)
                    .lineLimit(1)
                    .layoutPriority(1)
                // The server's nickname, as Who's watching shows it, so two
                // profiles with the same name can be told apart.
                Text(verbatim: account.serverLabel)
                    .font(.vividHeadline)
                    .foregroundStyle(Color.vividSecondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.vividCaption)
            }
            .foregroundStyle(Color.vividOnSurface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: searchLabel))
        .accessibilityAddTraits(.isButton)
    }

    /// Laid out like the request titles below it. Without a content ID the
    /// card calls its action instead of opening the title on the signed-in
    /// profile.
    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(cards) { card in
                    MediaCard(
                        title: card.item.title,
                        posterUrl: posterURL(card.item),
                        thumbhash: card.item.posterThumbhash,
                        year: card.item.year,
                        yearCaption: card.item.posterYearCaption,
                        userState: card.item.userState,
                        action: { onOpen(card.item) }
                    )
                }
            }
            .phoneMediaRailBounds()
        }
    }
    #endif
}
