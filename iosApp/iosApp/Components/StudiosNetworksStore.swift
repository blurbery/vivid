import SwiftUI
import Observation
import ImageIO

/// One studio or network that can be pinned to Home.
struct StudioNetworkBrand: Identifiable, Equatable {
    enum Kind { case network, studio }
    let id: String
    let name: String
    let kind: Kind
    /// TMDb network ID for networks, company ID for studios.
    let tmdbId: Int
    /// A studio's sister labels, whose films count too. Sony's big releases
    /// are credited to Columbia, not Sony Pictures. The logo stays `tmdbId`'s.
    var labelIds: [Int] = []
    /// TMDb watch providers for a network's films, any of which counts (a
    /// service with several plans lists each one). Read from the US lists,
    /// which are the most complete, unless the service only runs elsewhere.
    /// Titles still only show when they're in the library, so the region
    /// never limits what can be watched.
    var watchProviderIds: [Int] = []
    var watchRegion = "US"
    /// Logos printed on a solid block (Marvel's box, the Warner Bros. shield)
    /// would render as a plain white shape, so their lettering is knocked out
    /// of the block instead.
    var knocksOutLogoText = false
    /// Lets a near-square logo (the Warner Bros. shield) use more of the
    /// tile's height, as the shared height limit left it smaller than the
    /// wide wordmarks beside it.
    var logoHeightScale: CGFloat = 1
    /// Redraws a one-line logo with its two words stacked beside the emblem,
    /// as Sony Pictures' long line was tiny on a tile.
    var stacksLogoWords = false
    /// Shows the name as a wordmark instead of the TMDb logo. Apple TV's
    /// logo carries the Apple mark, which apps can't display, so it's set in
    /// the system typeface instead.
    var usesWordmark = false
}

/// Matched library titles for one brand, in TMDb popularity order.
struct StudioNetworkResult: Codable, Equatable {
    var logoURL: URL?
    var movies: [BrowseItem] = []
    var series: [BrowseItem] = []
    /// Series with episodes aired in the past 12 months.
    var recentSeries: [BrowseItem] = []
    /// Movies released in the past 12 months.
    var recentMovies: [BrowseItem] = []
    /// Movies and series merged by popularity, capped for the grid.
    var all: [BrowseItem] = []
    /// Every matched title, before the grid cap. Ranks the automatic picks.
    var matchCount = 0
    var count: Int { matchCount }

    /// Every title the page can show, for reading poster expiry.
    var items: [BrowseItem] { movies + series + recentSeries + recentMovies + all }
}

/// Decodes a catalogue item together with the TMDb ID providers attach.
private struct StudioNetworkIndexedItem: Decodable {
    let item: BrowseItem
    let tmdbId: String?
    private enum Keys: String, CodingKey { case tmdbId }

    init(from decoder: Decoder) throws {
        item = try BrowseItem(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        if let text = try? c.decode(String.self, forKey: .tmdbId) { tmdbId = text }
        else if let number = try? c.decode(Int.self, forKey: .tmdbId) { tmdbId = String(number) }
        else { tmdbId = nil }
    }
}

private struct StudioNetworkIndexPage: Decodable {
    let items: [StudioNetworkIndexedItem]
    let hasMore: Bool?
}

private struct StudioNetworkResultsFile: Codable, Sendable {
    let savedAt: Date
    let results: [String: StudioNetworkResult]
}

/// The library scan is the slow part, so it's cached on its own and the quick
/// TMDb step can rerun without it.
private struct StudioNetworkIndexFile: Codable, Sendable {
    let savedAt: Date
    let movies: [String: BrowseItem]
    let series: [String: BrowseItem]
}

/// Only the movie cards from a saved library index. Decoding this skips the
/// series and every field a poster card doesn't use.
private struct StudioNetworkIndexMovieCards: Decodable, Sendable {
    let savedAt: Date
    let movies: [String: SimilarPosterItem]
}

/// Library movies with just what a poster card needs, keyed like the library
/// index. Saved beside it so a movie page can find the rest of its TMDb
/// collection without searching the server.
struct LibraryMovieLookup: Codable, Sendable {
    struct Movie: Codable, Sendable {
        let card: SimilarPosterItem
        var tmdbId: String?
    }

    let savedAt: Date
    let movies: [Movie]
    /// TMDb ID or title + year key, to a position in `movies`.
    let keys: [String: Int]

    init(index: [String: BrowseItem], savedAt: Date) {
        self.init(cards: index.mapValues(SimilarPosterItem.init(item:)), savedAt: savedAt)
    }

    init(cards: [String: SimilarPosterItem], savedAt: Date) {
        var movies: [Movie] = []
        var positions: [String: Int] = [:]
        var keys: [String: Int] = [:]
        for (key, card) in cards {
            let position: Int
            if let existing = positions[card.contentId] {
                position = existing
            } else {
                position = movies.count
                positions[card.contentId] = position
                movies.append(Movie(card: card))
            }
            keys[key] = position
            // Title + year keys are never plain numbers.
            if Int(key) != nil { movies[position].tmdbId = key }
        }
        self.savedAt = savedAt
        self.movies = movies
        self.keys = keys
    }

    /// TMDb ID first, then exact title and year from a movie that doesn't
    /// carry a different TMDb ID.
    func movie(tmdbId: Int, titles: [String], year: Int?) -> SimilarPosterItem? {
        if let movie = movie(forKey: String(tmdbId)) { return movie.card }
        guard let year else { return nil }
        for title in titles {
            if let movie = movie(forKey: StudiosNetworksStore.titleKey(title, year: year)), movie.tmdbId == nil {
                return movie.card
            }
        }
        return nil
    }

    private func movie(forKey key: String) -> Movie? {
        guard let position = keys[key], movies.indices.contains(position) else { return nil }
        return movies[position]
    }
}

/// Loads, matches, caches and remembers the pinned Studios & Networks row.
///
/// Uses the profile's own TMDb key. TMDb supplies each brand's logo and its
/// popularity-ordered titles; only titles in the library are kept, matched by
/// TMDb ID when the server lists one and otherwise by exact title and year.
/// Results and the library index are cached per server and profile, so Home
/// shows the row instantly and refreshes once a day in the background.
@MainActor
@Observable
final class StudiosNetworksStore {
    static let shared = StudiosNetworksStore()

    static let maxPicks = 6
    /// Below this a tile or page row would look empty, so it's hidden.
    static let minimumCount = 6
    static let rowLimit = 20
    nonisolated static let gridLimit = 100
    /// TMDb discover pages read per list (20 titles each).
    nonisolated static let pagesPerList = 5
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// Silo signs artwork URLs for a few hours, far less than the daily
    /// refresh, so posters are re-read this long before the first one expires.
    nonisolated static let artworkRefreshLead: TimeInterval = 15 * 60
    /// Least time between poster refreshes, in case the server's URLs come
    /// back already near expiry or the device clock runs ahead.
    static let artworkRefreshCooldown: TimeInterval = 15 * 60
    /// Brands matched at once. Each runs up to four lists in parallel.
    static let concurrentBrands = 3

    static let catalogue: [StudioNetworkBrand] = [
        .init(id: "netflix", name: "Netflix", kind: .network, tmdbId: 213, watchProviderIds: [8]),
        .init(id: "hbo", name: "HBO", kind: .network, tmdbId: 49, watchProviderIds: [1899]),
        .init(id: "appletv", name: "Apple TV", kind: .network, tmdbId: 2552, watchProviderIds: [350], usesWordmark: true),
        .init(id: "disneyplus", name: "Disney+", kind: .network, tmdbId: 2739, watchProviderIds: [337]),
        .init(id: "prime", name: "Prime Video", kind: .network, tmdbId: 1024, watchProviderIds: [9]),
        .init(id: "hulu", name: "Hulu", kind: .network, tmdbId: 453, watchProviderIds: [15]),
        .init(id: "peacock", name: "Peacock", kind: .network, tmdbId: 3353, watchProviderIds: [386, 387]),
        .init(id: "paramountplus", name: "Paramount+", kind: .network, tmdbId: 4330, watchProviderIds: [2303, 2616]),
        .init(id: "stan", name: "Stan", kind: .network, tmdbId: 1255, watchProviderIds: [21], watchRegion: "AU"),
        .init(id: "pixar", name: "Pixar", kind: .studio, tmdbId: 3),
        .init(id: "marvel", name: "Marvel Studios", kind: .studio, tmdbId: 420, knocksOutLogoText: true),
        .init(id: "a24", name: "A24", kind: .studio, tmdbId: 41077),
        .init(id: "lucasfilm", name: "Lucasfilm", kind: .studio, tmdbId: 1),
        .init(id: "dreamworks", name: "DreamWorks", kind: .studio, tmdbId: 521),
        .init(id: "ghibli", name: "Studio Ghibli", kind: .studio, tmdbId: 10342),
        .init(id: "sony", name: "Sony Pictures", kind: .studio, tmdbId: 34, labelIds: [5, 2251, 559], stacksLogoWords: true),
        .init(id: "warnerbros", name: "Warner Bros.", kind: .studio, tmdbId: 174, knocksOutLogoText: true, logoHeightScale: 1.35),
        .init(id: "universal", name: "Universal", kind: .studio, tmdbId: 33),
    ]

    static let firstLoadNotice = "Setting up Studios & Networks for the first time. Vivid is reading your library and matching it with TMDb, which can take a few minutes on a large library. Keep Vivid open until it finishes. After this it loads instantly."

    enum Status: Equatable { case idle, needsTMDB, loading, ready, failed }

    private(set) var status: Status = .idle
    private(set) var results: [String: StudioNetworkResult] = [:]
    /// Live progress for the first-load notice.
    private(set) var progressText: String?
    private(set) var isEnabled = true
    /// nil means automatic: the top brands by library matches.
    private(set) var customPicks: [String]?
    /// While a settings editor is open, picks can drop below the required
    /// six so a brand can be swapped. Elsewhere they're always filled.
    private(set) var isEditing = false

    private var loadedScope: Scope?
    /// When the shown results were matched, kept when only their posters are
    /// refreshed so the daily TMDb refresh stays on schedule.
    private var resultsSavedAt: Date?
    /// When the first signed poster URL in the results stops working. Nil
    /// when none carries an expiry, as with Emby and Jellyfin.
    private var artworkExpiresAt: Date?
    private var artworkRefreshedAt: Date?
    private var titlesRead: [String: Int] = [:]
    private var loadTask: Task<Void, Never>?
    private let defaults = SharedDefaults.shared
    @ObservationIgnored private var movieLookupCache: (scope: Scope, modified: Date, lookup: LibraryMovieLookup)?
    /// Changes whenever a movie lookup is saved, so open movie pages load
    /// their collection row again once the lookup exists.
    private(set) var movieLookupRevision = 0

    // MARK: Picks

    func brand(_ id: String) -> StudioNetworkBrand? { Self.catalogue.first { $0.id == id } }
    func count(_ id: String) -> Int { results[id]?.count ?? 0 }
    func isEligible(_ id: String) -> Bool { count(id) >= Self.minimumCount }

    var automaticPicks: [String] {
        Self.automaticPicks(counts: results.mapValues(\.count))
    }

    /// The brands with the most matches, ties kept in catalogue order.
    static func automaticPicks(counts: [String: Int]) -> [String] {
        let eligible = catalogue.enumerated().filter { (counts[$0.element.id] ?? 0) >= minimumCount }
        return Array(eligible
            .sorted { lhs, rhs in
                let (l, r) = (counts[lhs.element.id] ?? 0, counts[rhs.element.id] ?? 0)
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .prefix(maxPicks)
            .map(\.element.id))
    }

    /// Fills `chosen` up to six with the most-matched brands not already
    /// chosen, so Home always shows a full row.
    static func filled(_ chosen: [String], counts: [String: Int]) -> [String] {
        let eligible = chosen.filter { (counts[$0] ?? 0) >= minimumCount }
        let extra = automaticPicks(counts: counts).filter { !eligible.contains($0) }
        return Array((eligible + extra).prefix(maxPicks))
    }

    var picks: [String] {
        let chosen = (customPicks ?? automaticPicks).filter(isEligible)
        return isEditing ? chosen : Self.filled(chosen, counts: results.mapValues(\.count))
    }

    /// Six, or every eligible brand when a small library has fewer.
    var requiredPicks: Int {
        min(Self.maxPicks, Self.catalogue.filter { isEligible($0.id) }.count)
    }

    /// The editor can't be closed until this is false, unless the row is
    /// turned off.
    var needsMorePicks: Bool { isEnabled && picks.count < requiredPicks }

    var missingPicks: Int { max(0, requiredPicks - picks.count) }

    /// Starts editing with a full set, saving any top-up of older choices
    /// made before six were required.
    func beginEditing() {
        isEditing = true
        topUpForEditing()
    }

    /// Waits for match counts, so a partial set is never saved.
    private func topUpForEditing() {
        guard isEditing, status == .ready, let custom = customPicks else { return }
        let full = Self.filled(custom, counts: results.mapValues(\.count))
        if full != custom { setPicks(full) }
    }

    func endEditing() {
        isEditing = false
    }

    var showsRow: Bool { isEnabled && status == .ready && !picks.isEmpty }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        savePreferences()
    }

    func toggle(_ id: String) {
        var current = picks
        if let index = current.firstIndex(of: id) { current.remove(at: index) }
        else if current.count < Self.maxPicks, isEligible(id) { current.append(id) }
        setPicks(current)
    }

    func move(_ id: String, by offset: Int) {
        guard let index = picks.firstIndex(of: id) else { return }
        place(id, at: index + offset)
    }

    /// Puts `id` at `index` in the current picks, for drag and drop.
    func place(_ id: String, at index: Int) {
        var current = picks
        guard let from = current.firstIndex(of: id) else { return }
        current.remove(at: from)
        current.insert(id, at: min(max(index, 0), current.count))
        setPicks(current)
    }

    func resetToAutomatic() {
        customPicks = nil
        savePreferences()
    }

    private func setPicks(_ ids: [String]) {
        customPicks = ids
        savePreferences()
    }

    /// Rows for a brand page. Networks show the past 12 months, falling back
    /// to all-time popular when the year is too thin to fill a row (Apple
    /// releases few films); studios always use their all-time popular.
    func pageRows(for id: String) -> [(title: String, items: [BrowseItem])] {
        Self.pageRows(for: brand(id), result: results[id] ?? StudioNetworkResult())
    }

    static func pageRows(for brand: StudioNetworkBrand?, result: StudioNetworkResult) -> [(title: String, items: [BrowseItem])] {
        let isStudio = brand?.kind == .studio
        func pick(recent: [BrowseItem], allTime: [BrowseItem]) -> [BrowseItem] {
            isStudio || recent.count < minimumCount ? allTime : recent
        }
        let series = (title: "Popular Series", items: pick(recent: result.recentSeries, allTime: result.series))
        let movies = (title: "Popular Movies", items: pick(recent: result.recentMovies, allTime: result.movies))
        return (isStudio ? [movies, series] : [series, movies])
            .filter { $0.items.count >= minimumCount }
            .map { (title: $0.title, items: Array($0.items.prefix(rowLimit))) }
    }

    // MARK: Profile scope and preferences

    struct Scope: Equatable {
        let server: String
        let profile: String

        static var current: Scope? {
            guard let server = ServerRegistry.shared.activeServerId,
                  let profile = AuthService.shared.profileId, !profile.isEmpty else { return nil }
            return Scope(server: server, profile: profile)
        }

        var preferencesKey: String { "tvos.homeStudiosNetworks.v1.\(server).\(profile)" }

        func cacheURL(_ name: String) -> URL? {
            let token = Data("\(server)|\(profile)".utf8).base64EncodedString()
                .filter { $0.isLetter || $0.isNumber }
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return nil }
            let folder = caches.appendingPathComponent("StudiosNetworks", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("\(name)-v1-\(token).json")
        }
    }

    private struct StoredPreferences: Codable, Equatable {
        var isEnabled = true
        var picks: [String]?
    }

    /// Picks up a profile or server switch, or preferences synced from
    /// another device. Results from another profile are never shown.
    func refresh(force: Bool = false) {
        let scope = Scope.current
        let changed = scope != loadedScope
        guard force || changed else { return }
        if changed {
            loadTask?.cancel()
            loadTask = nil
            loadedScope = scope
            results = [:]
            resultsSavedAt = nil
            artworkExpiresAt = nil
            artworkRefreshedAt = nil
            progressText = nil
            status = .idle
        }
        let stored = scope.flatMap { scope in
            defaults.data(forKey: scope.preferencesKey).flatMap { try? JSONDecoder().decode(StoredPreferences.self, from: $0) }
        } ?? StoredPreferences()
        isEnabled = stored.isEnabled
        customPicks = stored.picks.map { Array(NSOrderedSet(array: $0).array.compactMap { $0 as? String }.prefix(Self.maxPicks)) }
    }

    private func savePreferences() {
        guard let scope = loadedScope,
              let data = try? JSONEncoder().encode(StoredPreferences(isEnabled: isEnabled, picks: customPicks)),
              defaults.data(forKey: scope.preferencesKey) != data else { return }
        defaults.set(data, forKey: scope.preferencesKey)
    }

    // MARK: Loading

    func loadIfNeeded() async {
        refresh()
        let tmdb = TVTMDbStore.shared
        tmdb.reloadForCurrentProfile()
        guard tmdb.isConfigured else {
            status = .needsTMDB
            return
        }
        if let loadTask { await loadTask.value; return }
        guard let scope = loadedScope else { return }
        // Ready results only need fresh posters, for an app left open past
        // their expiry.
        let isReady = status == .ready
        if isReady, !artworkNeedsRefresh { return }
        // One task covers the cache read and any load, so Home and Settings
        // asking at the same time share a single load.
        let task = Task { [weak self] in
            if isReady { await self?.refreshArtwork(scope) } else { await self?.prepare(scope) }
            if self?.loadedScope == scope { self?.loadTask = nil }
        }
        loadTask = task
        await task.value
    }

    /// Shows saved results straight away when there are any, refreshing them
    /// in the background once a day; otherwise runs the first load.
    private func prepare(_ scope: Scope) async {
        if let cached = await Self.read(StudioNetworkResultsFile.self, scope.cacheURL("results")) {
            guard loadedScope == scope else { return }
            results = cached.results
            resultsSavedAt = cached.savedAt
            status = .ready
            topUpForEditing()
            let expiry = await Self.artworkExpiry(in: cached.results)
            guard loadedScope == scope else { return }
            artworkExpiresAt = expiry
            // Brands added since the results were saved have nothing to show
            // until they're matched, so a new brand refreshes them early.
            let missesBrands = Self.catalogue.contains { cached.results[$0.id] == nil }
            guard missesBrands || Date().timeIntervalSince(cached.savedAt) > Self.refreshInterval else {
                Self.saveMissingMovieLookup(library: scope.cacheURL("library"), lookup: scope.cacheURL("movies"))
                if artworkNeedsRefresh { await refreshArtwork(scope) }
                return
            }
        } else {
            guard loadedScope == scope else { return }
            status = .loading
        }
        await load(scope)
    }

    private func load(_ scope: Scope) async {
        do {
            let index: StudioNetworkIndexFile
            if let cached = await Self.read(StudioNetworkIndexFile.self, scope.cacheURL("library")),
               Date().timeIntervalSince(cached.savedAt) < Self.refreshInterval,
               await Self.hasCurrentArtwork(cached) {
                index = cached
            } else {
                index = try await readLibrary(scope, reportsProgress: true)
            }
            await Self.saveMovieLookup(index, to: scope.cacheURL("movies"))

            // Any TMDb failure throws to the catch below, so a partial result
            // never replaces good saved results or resets the refresh timer.
            // Brands load a few at a time to stay well inside TMDb's rate limit.
            var loaded: [String: StudioNetworkResult] = [:]
            var pending = Self.catalogue[...]
            try await withThrowingTaskGroup(of: (String, StudioNetworkResult).self) { group in
                for _ in 0..<Self.concurrentBrands {
                    guard let brand = pending.popFirst() else { break }
                    group.addTask { (brand.id, try await Self.result(for: brand, index: index)) }
                }
                while let (id, result) = try await group.next() {
                    loaded[id] = result
                    if loadedScope == scope {
                        progressText = "Matching with TMDb… \(loaded.count) of \(Self.catalogue.count)"
                    }
                    if let brand = pending.popFirst() {
                        group.addTask { (brand.id, try await Self.result(for: brand, index: index)) }
                    }
                }
            }
            try Task.checkCancellation()
            guard loadedScope == scope else { return }
            let savedAt = Date()
            results = loaded
            resultsSavedAt = savedAt
            status = .ready
            topUpForEditing()
            progressText = nil
            await Self.write(StudioNetworkResultsFile(savedAt: savedAt, results: loaded), scope.cacheURL("results"))
            let expiry = await Self.artworkExpiry(in: loaded)
            if loadedScope == scope { artworkExpiresAt = expiry }
        } catch {
            guard loadedScope == scope else { return }
            progressText = nil
            // Keep showing saved results if only the background refresh failed.
            if results.isEmpty { status = .failed }
        }
    }

    // MARK: Poster refresh

    private var artworkNeedsRefresh: Bool {
        guard let artworkExpiresAt,
              artworkExpiresAt.timeIntervalSinceNow < Self.artworkRefreshLead else { return false }
        guard let artworkRefreshedAt else { return true }
        return Date().timeIntervalSince(artworkRefreshedAt) > Self.artworkRefreshCooldown
    }

    /// Swaps fresh poster URLs into the shown results by re-reading the
    /// library, without matching with TMDb again. Results are kept for a day,
    /// but Silo's signed artwork URLs stop working after a few hours and every
    /// poster would be left on its blurred placeholder. Status and progress
    /// stay as they are, so this runs unseen behind the current results.
    private func refreshArtwork(_ scope: Scope) async {
        artworkRefreshedAt = Date()
        do {
            let index = try await readLibrary(scope, reportsProgress: false)
            await Self.saveMovieLookup(index, to: scope.cacheURL("movies"))
            try Task.checkCancellation()
            guard loadedScope == scope else { return }
            let current = results
            let refreshed = await Task.detached(priority: .utility) {
                Self.replacingArtwork(in: current, with: [index.movies.values, index.series.values].joined())
            }.value
            let expiry = await Self.artworkExpiry(in: refreshed)
            guard loadedScope == scope else { return }
            results = refreshed
            artworkExpiresAt = expiry
            await Self.write(StudioNetworkResultsFile(savedAt: resultsSavedAt ?? Date(), results: refreshed), scope.cacheURL("results"))
        } catch {
            // Keep the current results. The next visit after the cooldown
            // tries again, and the daily refresh reads the library anyway.
        }
    }

    /// The results with every title replaced by its entry from a fresh
    /// library read, which carries current artwork. Titles no longer in the
    /// library are dropped, so an expired URL can't linger, and the match
    /// count follows so a brand that falls below six leaves Home.
    nonisolated static func replacingArtwork(
        in results: [String: StudioNetworkResult],
        with titles: some Sequence<BrowseItem>
    ) -> [String: StudioNetworkResult] {
        var current: [String: BrowseItem] = [:]
        for title in titles { current[title.contentId] = title }
        func refreshed(_ items: [BrowseItem]) -> [BrowseItem] { items.compactMap { current[$0.contentId] } }
        return results.mapValues { result in
            var result = result
            result.movies = refreshed(result.movies)
            result.series = refreshed(result.series)
            result.recentSeries = refreshed(result.recentSeries)
            result.recentMovies = refreshed(result.recentMovies)
            result.all = refreshed(result.all)
            // Matching counts each title once across movies and series.
            result.matchCount = Set((result.movies + result.series).map(\.contentId)).count
            return result
        }
    }

    /// The earliest expiry among signed poster URLs, or nil when none has one.
    nonisolated static func artworkExpiry(of items: some Sequence<BrowseItem>) -> Date? {
        var earliest: Date?
        var seen = Set<String>()
        for item in items {
            guard let url = item.posterUrl, seen.insert(url).inserted,
                  let expiry = SiloAPICompatibility.artworkExpiry(url) else { continue }
            earliest = min(earliest ?? expiry, expiry)
        }
        return earliest
    }

    private nonisolated static func artworkExpiry(in results: [String: StudioNetworkResult]) async -> Date? {
        await Task.detached(priority: .utility) {
            artworkExpiry(of: results.values.lazy.flatMap(\.items))
        }.value
    }

    /// Whether a saved index's posters will still load for a while. Runs off
    /// the main actor, as the index holds every library title.
    private nonisolated static func hasCurrentArtwork(_ index: StudioNetworkIndexFile) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let expiry = artworkExpiry(of: [index.movies.values, index.series.values].joined()) else { return true }
            return expiry.timeIntervalSinceNow >= artworkRefreshLead
        }.value
    }

    // MARK: Library index

    /// Reads every library title from the server and saves the index.
    private func readLibrary(_ scope: Scope, reportsProgress: Bool) async throws -> StudioNetworkIndexFile {
        if reportsProgress { titlesRead = [:] }
        let report: @MainActor (String, Int) -> Void = { [weak self] type, count in
            guard reportsProgress, let self, self.loadedScope == scope else { return }
            self.titlesRead[type] = count
            self.progressText = "Reading your library… \(self.titlesRead.values.reduce(0, +).formatted()) titles"
        }
        async let movies = Self.libraryIndex(type: "movie", report: report)
        async let series = Self.libraryIndex(type: "series", report: report)
        let index = StudioNetworkIndexFile(savedAt: Date(), movies: try await movies, series: try await series)
        await Self.write(index, scope.cacheURL("library"))
        return index
    }

    /// Every library title of one type, keyed by TMDb ID and by title + year.
    /// Runs off the main actor: building the index folds every library
    /// title, which would stall scrolling during the daily refresh.
    private nonisolated static func libraryIndex(
        type: String,
        report: @MainActor (String, Int) -> Void
    ) async throws -> [String: BrowseItem] {
        var index: [String: BrowseItem] = [:]
        var offset = 0
        // 200 per page, the same shape as the app's browse queries.
        for _ in 0..<500 {
            try Task.checkCancellation()
            let page = try await VividAPI.shared.catalog(query: [
                "source": "query", "type": type, "offset": String(offset), "limit": "200",
                "sort": "title", "order": "asc", "match": "all", "include_total": "false",
            ], as: StudioNetworkIndexPage.self)
            for entry in page.items {
                if let id = entry.tmdbId, !id.isEmpty, index[id] == nil { index[id] = entry.item }
                // Servers that leave provider IDs out of lists still match here.
                if let year = entry.item.year {
                    let key = titleKey(entry.item.title, year: year)
                    if index[key] == nil { index[key] = entry.item }
                }
            }
            offset += page.items.count
            await report(type, offset)
            if page.hasMore != true || page.items.isEmpty { break }
        }
        return index
    }

    /// Case, accent and punctuation insensitive key for title + year matching.
    nonisolated static func titleKey(_ title: String, year: Int) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let simple = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return "t:\(simple)|\(year)"
    }

    /// TMDb ID first, then exact title and year. A year either side matched
    /// unrelated titles that share a name in large libraries.
    nonisolated static func lookup(_ result: TVTMDbStore.DiscoverPage.Result, in index: [String: BrowseItem]) -> BrowseItem? {
        if let item = index[String(result.id)] { return item }
        guard let title = result.title ?? result.name,
              let date = result.releaseDate ?? result.firstAirDate,
              let year = Int(date.prefix(4)) else { return nil }
        return index[titleKey(title, year: year)]
    }

    // MARK: TMDb matching

    private nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Off the main actor, like the library index, so matching never
    /// competes with drawing.
    private nonisolated static func result(for brand: StudioNetworkBrand, index: StudioNetworkIndexFile) async throws -> StudioNetworkResult {
        let id = String(brand.tmdbId)
        let today = Date()
        let from = dayFormatter.string(from: Calendar.current.date(byAdding: .month, value: -12, to: today) ?? today)
        let to = dayFormatter.string(from: today)

        let companies = ([brand.tmdbId] + brand.labelIds).map(String.init).joined(separator: "|")
        let seriesQuery = brand.kind == .network ? ["with_networks": id] : ["with_companies": companies]
        let movieQuery: [String: String]? = switch brand.kind {
        case .studio: ["with_companies": companies]
        case .network: brand.watchProviderIds.isEmpty ? nil : [
            "with_watch_providers": brand.watchProviderIds.map(String.init).joined(separator: "|"),
            "watch_region": brand.watchRegion,
            "with_watch_monetization_types": "flatrate",
        ]
        }

        let recentSeriesQuery = seriesQuery.merging(["air_date.gte": from, "air_date.lte": to]) { $1 }
        let recentMovieQuery = movieQuery?.merging(["primary_release_date.gte": from, "primary_release_date.lte": to]) { $1 }

        async let logo = logoURL(for: brand)
        async let series = matches("tv", seriesQuery, index.series)
        async let recentSeries = matches("tv", recentSeriesQuery, index.series)
        async let movies = matches("movie", movieQuery, index.movies)
        async let recentMovies = matches("movie", recentMovieQuery, index.movies)

        let allSeries = try await series
        let allMovies = try await movies
        var all: [(item: BrowseItem, popularity: Double)] = []
        var seen = Set<String>()
        for entry in (allMovies + allSeries).sorted(by: { $0.popularity > $1.popularity })
        where seen.insert(entry.item.contentId).inserted {
            all.append(entry)
        }
        return StudioNetworkResult(
            logoURL: try await logo,
            movies: allMovies.map(\.item),
            series: allSeries.map(\.item),
            recentSeries: try await recentSeries.map(\.item),
            recentMovies: try await recentMovies.map(\.item),
            all: Array(all.prefix(gridLimit)).map(\.item),
            matchCount: all.count
        )
    }

    private nonisolated static func logoURL(for brand: StudioNetworkBrand) async throws -> URL? {
        guard !brand.usesWordmark else { return nil }
        return try await retryingOnce {
            try await TVTMDbStore.shared.logoURL(kind: brand.kind == .network ? "network" : "company", id: brand.tmdbId)
        }
    }

    /// Retries a TMDb request once after a short pause, for a dropped
    /// connection or a brief rate limit, then lets the error through.
    private nonisolated static func retryingOnce<T>(_ request: () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await Task.sleep(for: .seconds(1))
            return try await request()
        }
    }

    /// Library matches for one TMDb discover list, in popularity order.
    private nonisolated static func matches(
        _ media: String,
        _ query: [String: String]?,
        _ index: [String: BrowseItem]
    ) async throws -> [(item: BrowseItem, popularity: Double)] {
        guard let query else { return [] }
        var found: [(item: BrowseItem, popularity: Double)] = []
        var seen = Set<String>()
        for page in 1...pagesPerList {
            try Task.checkCancellation()
            let response = try await retryingOnce {
                try await TVTMDbStore.shared.discover(media: media, query: query, page: page)
            }
            for result in response.results {
                if let item = lookup(result, in: index), seen.insert(item.contentId).inserted {
                    found.append((item, result.popularity ?? 0))
                }
            }
            if page >= (response.totalPages ?? 1) { break }
        }
        return found
    }

    // MARK: Disk cache

    /// The library index runs to tens of megabytes, so reading and writing
    /// happen off the main actor to keep Home and focus smooth.
    private nonisolated static func read<T: Decodable & Sendable>(_ type: T.Type, _ url: URL?) async -> T? {
        await Task.detached(priority: .utility) {
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }.value
    }

    private nonisolated static func write<T: Encodable & Sendable>(_ value: T, _ url: URL?) async {
        await Task.detached(priority: .utility) {
            guard let url, let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }

    // MARK: Movie lookup

    /// The saved movie lookup for this server and profile, read once in the
    /// background and kept until a newer one is saved. Nil until the library
    /// has been indexed with a TMDb connection.
    func movieLookup() async -> LibraryMovieLookup? {
        guard let scope = Scope.current, let url = scope.cacheURL("movies"),
              let modified = Self.modificationDate(url) else { return nil }
        if let cache = movieLookupCache, cache.scope == scope, cache.modified == modified { return cache.lookup }
        guard let lookup = await Self.read(LibraryMovieLookup.self, url), Scope.current == scope else { return nil }
        movieLookupCache = (scope, modified, lookup)
        return lookup
    }

    /// Saves the movie lookup unless one from this index is already saved.
    private nonisolated static func saveMovieLookup(_ index: StudioNetworkIndexFile, to url: URL?) async {
        guard let url else { return }
        if let modified = modificationDate(url), modified >= index.savedAt { return }
        let saved = await Task.detached(priority: .utility) { () -> Bool in
            let lookup = LibraryMovieLookup(index: index.movies, savedAt: index.savedAt)
            guard let data = try? JSONEncoder().encode(lookup) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }.value
        if saved { await movieLookupSaved() }
    }

    private static func movieLookupSaved() {
        shared.movieLookupRevision &+= 1
    }

    /// A library indexed before movie pages used the lookup gets one from its
    /// saved index, once. It waits for Home to settle, runs at the lowest
    /// priority and reads only the movie cards.
    private nonisolated static func saveMissingMovieLookup(library: URL?, lookup: URL?) {
        guard let library, let lookup, modificationDate(lookup) == nil else { return }
        Task.detached(priority: .background) {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard StudiosNetworksStore.modificationDate(lookup) == nil,
                  let data = try? Data(contentsOf: library),
                  let index = try? JSONDecoder().decode(StudioNetworkIndexMovieCards.self, from: data),
                  let encoded = try? JSONEncoder().encode(LibraryMovieLookup(cards: index.movies, savedAt: index.savedAt))
            else { return }
            guard (try? encoded.write(to: lookup, options: .atomic)) != nil else { return }
            await StudiosNetworksStore.movieLookupSaved()
        }
    }

    private nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Removes this device's cached results, library index and movie lookup
    /// for a profile, used when its account is removed.
    nonisolated static func removeCache(server: String, profile: String) {
        let scope = Scope(server: server, profile: profile)
        for name in ["results", "library", "movies"] {
            if let url = scope.cacheURL(name) { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// A brand's TMDb logo as a white silhouette, so every tile reads the same on
/// the dark cards. Falls back to the brand name as a wordmark.
struct StudioNetworkLogo: View {
    let brand: StudioNetworkBrand?
    let url: URL?
    var fallbackName = ""

    var body: some View {
        if brand?.stacksLogoWords == true, let url {
            StackedWordsLogo(url: url) { standardLogo }.accessibilityHidden(true)
        } else {
            standardLogo
        }
    }

    private var standardLogo: some View {
        AsyncImage(url: brand?.usesWordmark == true ? nil : url) { phase in
            if let image = phase.image {
                if brand?.knocksOutLogoText == true {
                    ZStack {
                        image.resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
                        image.resizable().scaledToFit()
                            .saturation(0).contrast(3)
                            .luminanceToAlpha()
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                } else {
                    image.resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
                }
            } else if brand?.usesWordmark == true {
                wordmark
            } else {
                Text(brand?.name ?? fallbackName)
                    .font(.system(size: 200, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.05)
            }
        }
        .accessibilityHidden(true)
    }

    /// Drawn once at display size and scaled like the TMDb logos, so it
    /// matches their weight and keeps the same letter spacing on every tile.
    /// Scaling the text itself kept its tracking in points, which crowded the
    /// letters on the smaller iPhone tiles.
    @ViewBuilder
    private var wordmark: some View {
        if let image = Self.wordmarkImage(brand?.name ?? fallbackName) {
            image.resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
        }
    }

    @MainActor private static var wordmarks: [String: Image] = [:]

    @MainActor private static func wordmarkImage(_ name: String) -> Image? {
        if let image = wordmarks[name] { return image }
        // The slightly tight tracking of a display wordmark. It also trims
        // after the last letter, so trailing padding keeps that letter whole.
        let renderer = ImageRenderer(content: Text(name)
            .font(.system(size: 200, weight: .semibold))
            .tracking(-13)
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.trailing, 13))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let image = Image(decorative: cgImage, scale: 2)
        wordmarks[name] = image
        return image
    }
}

/// A one-line logo with its emblem on the left, the first word on top and the
/// second word below, scaled to the first word's width. Shows the logo as
/// it is if it doesn't split into an emblem and two words, and the standard
/// logo while the stacked one loads or if it can't be built.
private struct StackedWordsLogo<Fallback: View>: View {
    let url: URL
    @ViewBuilder let fallback: () -> Fallback
    @State private var image: Image?

    var body: some View {
        ZStack {
            if let image {
                image.resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
            } else {
                fallback()
            }
        }
        .task(id: url) { image = await StackedWordsLogoRenderer.image(for: url) }
    }
}

@MainActor
private enum StackedWordsLogoRenderer {
    private static var images: [URL: Image] = [:]

    static func image(for url: URL) async -> Image? {
        if let image = images[url] { return image }
        // The 500-point logo's letters are only a few pixels apart, so the
        // stacked version is built from the full-size original.
        let original = URL(string: url.absoluteString.replacingOccurrences(of: "/t/p/w500/", with: "/t/p/original/")) ?? url
        guard let (data, _) = try? await URLSession.shared.data(from: original),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let stacked = await Task.detached(priority: .utility) { stack(logo) }.value
        let image = Image(decorative: stacked ?? logo, scale: 1)
        images[url] = image
        return image
    }

    nonisolated static func stack(_ logo: CGImage) -> CGImage? {
        let width = logo.width, height = logo.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(logo, in: CGRect(x: 0, y: 0, width: width, height: height))
        func ink(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] > 40 }

        // Runs of columns with ink: the emblem, then each letter.
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var last = 0
        for x in 0..<width {
            if (0..<height).contains(where: { ink(x, $0) }) {
                if start == nil { start = x }
                last = x
            } else if let first = start, x - last > 1 {
                runs.append(first...last)
                start = nil
            }
        }
        if let first = start { runs.append(first...last) }
        func rows(_ columns: ClosedRange<Int>) -> ClosedRange<Int>? {
            var top = height, bottom = -1
            for y in 0..<height where columns.contains(where: { ink($0, y) }) {
                top = min(top, y)
                bottom = max(bottom, y)
            }
            return bottom >= top ? top...bottom : nil
        }

        // Letters sit close together; the gaps after the emblem and between
        // the words are wider than about a third of the letter height.
        guard runs.count >= 3, let letter = rows(runs[1]) else { return nil }
        var groups = [runs[0]]
        for run in runs.dropFirst() {
            let previous = groups[groups.count - 1]
            if Double(run.lowerBound - previous.upperBound) > Double(letter.count) * 0.29 {
                groups.append(run)
            } else {
                groups[groups.count - 1] = previous.lowerBound...run.upperBound
            }
        }
        guard groups.count == 3 else { return nil }
        func crop(_ columns: ClosedRange<Int>) -> (image: CGImage, size: CGSize)? {
            guard let rows = rows(columns) else { return nil }
            let rect = CGRect(x: columns.lowerBound, y: rows.lowerBound, width: columns.count, height: rows.count)
            return logo.cropping(to: rect).map { ($0, rect.size) }
        }
        guard let emblem = crop(groups[0]), let top = crop(groups[1]), let bottom = crop(groups[2]) else { return nil }

        let bottomHeight = bottom.size.height * top.size.width / bottom.size.width
        let gap = top.size.height * 0.28
        let stackHeight = top.size.height + gap + bottomHeight
        let emblemWidth = emblem.size.width * stackHeight / emblem.size.height
        let textX = emblemWidth + top.size.height * 0.32
        guard let output = CGContext(data: nil, width: Int((textX + top.size.width).rounded(.up)),
                                     height: Int(stackHeight.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        output.interpolationQuality = .high
        output.draw(emblem.image, in: CGRect(x: 0, y: 0, width: emblemWidth, height: stackHeight))
        output.draw(top.image, in: CGRect(x: textX, y: bottomHeight + gap, width: top.size.width, height: top.size.height))
        output.draw(bottom.image, in: CGRect(x: textX, y: 0, width: top.size.width, height: bottomHeight))
        return output.makeImage()
    }
}
