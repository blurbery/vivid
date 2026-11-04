import Foundation

/// The app's in-memory stale-while-revalidate cache of decoded responses.
///
/// A caller builds the key for the request it's about to make, shows the
/// last value straight away while a fresh fetch runs, then writes the result
/// back. There are no expiry times or size limits; any limit belongs to the
/// screen that needs it.
///
/// Sign-out and profile or server switches clear it (or per-profile
/// prefixes) so one account's data never shows for another. Those hooks live
/// in `AuthService`.
@MainActor
final class ResponseCache {
    static let shared = ResponseCache()

    private var entries: [String: Any] = [:]

    private init() {}

    /// The cached value as `T`, or nil when there's none or it has another
    /// type, which callers treat like any other miss.
    func get<T>(_ key: String, as: T.Type = T.self) -> T? {
        entries[key] as? T
    }

    func set<T>(_ value: T, for key: String) {
        entries[key] = value
    }

    func remove(_ key: String) {
        entries.removeValue(forKey: key)
    }

    /// Changes a cached value in place, so an optimistic change (favourite,
    /// watched) shows on a returning screen without a round trip. Does
    /// nothing when the value is missing or has another type.
    func update<T>(_ key: String, as: T.Type = T.self, transform: (inout T) -> Void) {
        guard var value = entries[key] as? T else { return }
        transform(&value)
        entries[key] = value
    }

    /// Drops every entry whose key starts with `prefix`, such as `item:`.
    func removeAll(withPrefix prefix: String) {
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Drops every response that carries a translatable overview or tagline,
    /// so the next fetch picks up the server's translation after the
    /// preferred metadata language changes.
    ///
    /// The language is per profile and rarely changes, so instead of adding
    /// it to every key this clears the `item:` family (detail, seasons,
    /// episodes, watch detail) and the home and recommendation rows that
    /// embed item summaries. Call it only when the language really changed.
    /// tvOS also keeps an `ItemDetailCache`, which the same call site clears.
    func invalidateAllItemMetadata() {
        removeAll(withPrefix: "item:")
        remove(CacheKey.homeSections)
        remove(CacheKey.recommendations)
    }

    func clearAll() {
        entries.removeAll()
    }
}

/// Every cache key, in one place so reads and writes can't drift apart and
/// prefix invalidation stays safe. Changing a string makes existing entries
/// unreachable.
enum CacheKey {
    static let homeSections = "home:sections"
    static let recommendations = "recommendations:discover"
    static let collections = "collections:list"
    /// Emby and Jellyfin collections shown in For You.
    static let nativeCollections = "collections:native"
    static let profiles = "profiles:list"
    static let favorites = "personal:favorites"
    static let history = "personal:history"
    static let watchlist = "personal:watchlist"
    /// Libraries the active profile can see, which set the tvOS library tabs.
    static let userLibraries = "user:libraries"

    static func person(_ id: Int) -> String { "item:person:\(id)" }

    static func itemDetail(_ contentId: String) -> String { "item:\(contentId)" }
    static func itemSeasons(_ seriesId: String) -> String { "item:\(seriesId):seasons" }
    static func itemEpisodes(seriesId: String, seasonNumber: Int) -> String {
        "item:\(seriesId):season:\(seasonNumber):episodes"
    }
    static func itemUserState(_ contentId: String) -> String { "item:\(contentId):userState" }
    static func itemWatchDetail(_ contentId: String) -> String { "item:\(contentId):watchDetail" }

    /// First page of a browse grid, keyed by the whole filter and sort state
    /// (`CatalogFilterState.cacheKeyFragment`) so filter combinations never
    /// share an entry.
    static func browse(libraryId: Int?, filterKey: String) -> String {
        "browse:\(libraryKey(libraryId)):\(filterKey)"
    }

    /// A library's filter options from `/catalog/filters`.
    static func catalogFilters(libraryId: Int?, includeTechnical: Bool = true) -> String {
        "catalogFilters:\(libraryKey(libraryId)):\(includeTechnical ? "technical" : "basic")"
    }

    static func tvLibrary(libraryId: Int, filterKey: String) -> String {
        "tvlibrary:\(libraryId):\(filterKey)"
    }

    static func collectionItems(_ collectionId: String) -> String { "collection:\(collectionId):items" }

    /// Per-profile families, dropped on a profile switch.
    static let perProfilePrefixes: [String] = [
        "home:",
        "recommendations:",
        "browse:",
        "library:",
        "personal:",
        "item:",
        "collection:",
        "collections:",
        "user:",
        // Browse pages and filter options depend on the profile's access,
        // and watch-status filters make a page profile-specific.
        "tvlibrary:",
        "catalogFilters:",
    ]

    private static func libraryKey(_ libraryId: Int?) -> String {
        libraryId.map(String.init) ?? "all"
    }
}
