import Foundation

/// Warms the artwork the first screens show, within a small budget.
extension StartupContentPrefetcher {
    #if os(tvOS)
    private static let homeArtworkBudget = 28
    #else
    private static let homeArtworkBudget = 12
    #endif

    /// The rows the round-robin pass takes turns between.
    private static let leadingRowCount = 4

    static func warmHomeArtwork(_ sections: [ResolvedSection]) {
        let rows = sections.filter { !$0.items.isEmpty }
        guard !rows.isEmpty else { return }
        let base = artworkBaseURL()
        var budget = homeArtworkBudget
        var logos: [URL] = []
        var cards: [URL] = []
        var seenLogos = Set<String>()
        var seenCards = Set<String>()

        #if os(iOS)
        if let logo = normalisedArtworkURL(rows[0].items[0].logoUrl, base: base),
           seenLogos.insert(logo.absoluteString).inserted {
            logos.append(logo)
            budget -= 1
        }
        #endif

        func addCard(for item: SectionItem, in row: ResolvedSection) {
            guard budget > 0,
                  let url = normalisedArtworkURL(cardArtwork(for: item, in: row), base: base),
                  seenCards.insert(url.absoluteString).inserted else { return }
            cards.append(url)
            budget -= 1
        }

        let leadingRows = rows.prefix(leadingRowCount)
        var position = 0
        while budget > 0 {
            let rowsWithItem = leadingRows.filter { $0.items.count > position }
            guard !rowsWithItem.isEmpty else { break }
            for row in rowsWithItem where budget > 0 {
                addCard(for: row.items[position], in: row)
            }
            position += 1
        }
        for row in rows.dropFirst(leadingRowCount) where budget > 0 {
            for item in row.items where budget > 0 {
                addCard(for: item, in: row)
            }
        }

        if !logos.isEmpty {
            PosterImageCache.prefetchOriginalArtwork(logos)
        }
        let unwarmed = cards.filter { PosterImageCache.warmedCardImage(for: $0) == nil }
        if !unwarmed.isEmpty {
            PosterImageCache.prefetchCardArtwork(unwarmed)
        }
    }

    static func warmBrowseArtwork(_ response: CatalogResponse) {
        let urls = distinctArtworkURLs(response.items.map(\.posterUrl), limit: 12)
        if !urls.isEmpty {
            PosterImageCache.prefetchCardArtwork(urls)
        }
    }

    static func warmAvatarArtwork(_ profiles: [UserProfile]) {
        let candidates = profiles.map { profile -> String? in
            if let resolved = ProfileAvatarResolver.serverResolvedImageURL(profile.avatarImageUrl) {
                return resolved
            }
            let emoji = profile.avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !emoji.isEmpty, ProfileAvatarResolver.isImage(emoji) else { return nil }
            return ProfileAvatarResolver.imageURL(for: emoji)
        }
        let urls = distinctArtworkURLs(candidates, limit: 8)
        if !urls.isEmpty {
            PosterImageCache.prefetchCardArtwork(urls)
        }
    }

    // MARK: Helpers

    /// A Continue Watching or Next Up card shows the series background where
    /// Home does; other rows show posters.
    private static func cardArtwork(for item: SectionItem, in row: ResolvedSection) -> String? {
        if HomeSeriesBackdrops.applies(toSectionType: row.sectionType) {
            return HomeSeriesBackdrops.shared.art(for: item).url
        }
        switch row.sectionType.lowercased() {
        case "continue_watching", "in_progress", "next_up":
            return item.backdropUrl ?? item.posterUrl
        default:
            return item.posterUrl
        }
    }

    private static func distinctArtworkURLs(_ candidates: [String?], limit: Int) -> [URL] {
        let base = artworkBaseURL()
        var seen = Set<String>()
        var urls: [URL] = []
        for candidate in candidates where urls.count < limit {
            guard let url = normalisedArtworkURL(candidate, base: base),
                  seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Silo artwork can be root-relative; it resolves against the server.
    private static func artworkBaseURL() -> URL? {
        guard MediaServerProvider.active == .silo else { return nil }
        return URL(string: ServerRegistry.shared.activeServerUrl)
    }

    private static func normalisedArtworkURL(_ raw: String?, base: URL?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = SiloAPICompatibility.artworkURL(trimmed, relativeTo: base),
              url.scheme != nil else { return nil }
        return url
    }
}
