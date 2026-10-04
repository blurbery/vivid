import SwiftUI
import Observation

/// One studio or network that can be pinned to Home.
struct StudioNetworkBrand: Identifiable, Equatable {
    enum Kind { case network, studio }
    let id: String
    let name: String
    let kind: Kind
    /// TMDb network ID for networks, company ID for studios.
    let tmdbId: Int
    /// TMDb watch provider for a network's films, read from the US lists,
    /// which are the most complete. Titles still only show when they're in
    /// the library, so the region never limits what can be watched.
    var watchProviderId: Int? = nil
    /// Logos printed on a solid block (Marvel) would render as a plain white
    /// box, so their lettering is knocked out of the block instead.
    var knocksOutLogoText = false
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
    /// Brands matched at once. Each runs up to four lists in parallel.
    static let concurrentBrands = 3

    static let catalogue: [StudioNetworkBrand] = [
        .init(id: "netflix", name: "Netflix", kind: .network, tmdbId: 213, watchProviderId: 8),
        .init(id: "hbo", name: "HBO", kind: .network, tmdbId: 49, watchProviderId: 1899),
        .init(id: "appletv", name: "Apple TV", kind: .network, tmdbId: 2552, watchProviderId: 350, usesWordmark: true),
        .init(id: "disneyplus", name: "Disney+", kind: .network, tmdbId: 2739, watchProviderId: 337),
        .init(id: "prime", name: "Prime Video", kind: .network, tmdbId: 1024, watchProviderId: 9),
        .init(id: "hulu", name: "Hulu", kind: .network, tmdbId: 453, watchProviderId: 15),
        .init(id: "pixar", name: "Pixar", kind: .studio, tmdbId: 3),
        .init(id: "marvel", name: "Marvel Studios", kind: .studio, tmdbId: 420, knocksOutLogoText: true),
        .init(id: "a24", name: "A24", kind: .studio, tmdbId: 41077),
        .init(id: "lucasfilm", name: "Lucasfilm", kind: .studio, tmdbId: 1),
        .init(id: "dreamworks", name: "DreamWorks Animation", kind: .studio, tmdbId: 521),
        .init(id: "ghibli", name: "Studio Ghibli", kind: .studio, tmdbId: 10342),
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
    private var titlesRead: [String: Int] = [:]
    private var loadTask: Task<Void, Never>?
    private let defaults = SharedDefaults.shared

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
        guard status != .ready, let scope = loadedScope else { return }
        // One task covers the cache read and any load, so Home and Settings
        // asking at the same time share a single load.
        let task = Task { [weak self] in
            await self?.prepare(scope)
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
            status = .ready
            topUpForEditing()
            guard Date().timeIntervalSince(cached.savedAt) > Self.refreshInterval else { return }
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
               Date().timeIntervalSince(cached.savedAt) < Self.refreshInterval {
                index = cached
            } else {
                titlesRead = [:]
                let report: @MainActor (String, Int) -> Void = { [weak self] type, count in
                    guard let self, self.loadedScope == scope else { return }
                    self.titlesRead[type] = count
                    self.progressText = "Reading your library… \(self.titlesRead.values.reduce(0, +).formatted()) titles"
                }
                async let movies = Self.libraryIndex(type: "movie", report: report)
                async let series = Self.libraryIndex(type: "series", report: report)
                index = StudioNetworkIndexFile(savedAt: Date(), movies: try await movies, series: try await series)
                await Self.write(index, scope.cacheURL("library"))
            }

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
            results = loaded
            status = .ready
            topUpForEditing()
            progressText = nil
            await Self.write(StudioNetworkResultsFile(savedAt: Date(), results: loaded), scope.cacheURL("results"))
        } catch {
            guard loadedScope == scope else { return }
            progressText = nil
            // Keep showing saved results if only the background refresh failed.
            if results.isEmpty { status = .failed }
        }
    }

    // MARK: Library index

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

        let seriesQuery = brand.kind == .network ? ["with_networks": id] : ["with_companies": id]
        let movieQuery: [String: String]? = switch brand.kind {
        case .studio: ["with_companies": id]
        case .network: brand.watchProviderId.map {
            ["with_watch_providers": String($0), "watch_region": "US", "with_watch_monetization_types": "flatrate"]
        }
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

    /// Removes this device's cached results and library index for a profile,
    /// used when its account is removed.
    nonisolated static func removeCache(server: String, profile: String) {
        let scope = Scope(server: server, profile: profile)
        for name in ["results", "library"] {
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

    /// Drawn large and scaled to fit, so it matches the other logos' weight
    /// at any tile size, with the slightly tight tracking of a display wordmark.
    private var wordmark: some View {
        // Negative tracking also trims after the last letter, which clips it;
        // a trailing hair space takes that trim instead.
        Text((brand?.name ?? fallbackName) + "\u{200A}")
            .font(.system(size: 200, weight: .semibold))
            .tracking(-3)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.05)
    }
}
