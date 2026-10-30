import SwiftUI

/// Favourite and watchlist buttons for a card's context menu. They only
/// forward taps; the caller updates its state and the server.
struct PersonalListMenuItems: View {
    let isFavorite: Bool
    let inWatchlist: Bool
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void

    var body: some View {
        Group {
            Button(action: onToggleFavorite) {
                if isFavorite {
                    Label("Remove from Favorites", systemImage: "heart.slash")
                } else {
                    Label("Add to Favorites", systemImage: "heart")
                }
            }
            Button(action: onToggleWatchlist) {
                if inWatchlist {
                    Label("Remove from Watchlist", systemImage: "bookmark.slash")
                } else {
                    Label("Add to Watchlist", systemImage: "bookmark")
                }
            }
        }
    }
}

extension View {
    /// A context menu with the items, or the view unchanged for nil.
    @ViewBuilder
    func personalListContextMenu(_ items: PersonalListMenuItems?) -> some View {
        if let items {
            contextMenu { items }
        } else {
            self
        }
    }
}

/// Saves a favourite or watchlist change, then refreshes the cached copies
/// other screens paint from. The flag that didn't change prefers the cached
/// value, so when two changes to one item overlap the later keeps the earlier.
@MainActor
enum PersonalListSync {
    static func setFavorite(contentId: String, isFavorite: Bool, inWatchlist: Bool) async -> Bool {
        do {
            try await VividAPI.shared.toggleFavorite(contentId: contentId, isFavorite: isFavorite)
        } catch {
            return false
        }
        let cached = cachedState(contentId)
        store(UserItemState(isFavorite: isFavorite, inWatchlist: cached?.inWatchlist ?? inWatchlist), for: contentId)
        return true
    }

    static func setWatchlist(contentId: String, isFavorite: Bool, inWatchlist: Bool) async -> Bool {
        do {
            try await VividAPI.shared.toggleWatchlist(contentId: contentId, isInWatchlist: inWatchlist)
        } catch {
            return false
        }
        let cached = cachedState(contentId)
        store(UserItemState(isFavorite: cached?.isFavorite ?? isFavorite, inWatchlist: inWatchlist), for: contentId)
        return true
    }

    private static func cachedState(_ contentId: String) -> UserItemState? {
        ResponseCache.shared.get(CacheKey.itemUserState(contentId), as: UserItemState.self)
    }

    private static func store(_ state: UserItemState, for contentId: String) {
        let cache = ResponseCache.shared
        cache.set(state, for: CacheKey.itemUserState(contentId))
        cache.remove(CacheKey.favorites)
        cache.remove(CacheKey.watchlist)
        cache.remove(CacheKey.homeSections)
    }
}
