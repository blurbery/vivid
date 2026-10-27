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
    /// Reads a network's series from its streaming list as well as its films.
    /// BritBox mostly streams BBC and ITV series, and TMDb credits it with
    /// only a handful of its own, so matching by network would leave it empty.
    var listsSeriesByWatchProvider = false
    /// Keeps anime in the Popular rows, which leave it out for every other
    /// brand. Studio Ghibli makes little else.
    var keepsAnime = false
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
    /// The network or studio names servers tag titles with, which put a
    /// library title in All in Your Library however popular it is. They
    /// follow TMDb's names for the networks and companies above, with
    /// older names a server may still use.
    var libraryNames: [String] = []
    /// Name beginnings that count too, for a brand whose every arm counts,
    /// such as Warner Bros. Animation, Television and its regional studios.
    var libraryNamePrefixes: [String] = []
}

/// Matched library titles for one brand. The TMDb lists keep TMDb's
/// popularity order, and the trending lists TMDb's trending order.
struct StudioNetworkResult: Codable, Equatable {
    var logoURL: URL?
    var movies: [BrowseItem] = []
    var series: [BrowseItem] = []
    /// Series with episodes aired in the past 12 months.
    var recentSeries: [BrowseItem] = []
    /// Movies released in the past 12 months.
    var recentMovies: [BrowseItem] = []
    /// The brand's series and movies in this week's TMDb trending list, which
    /// lead its Popular rows. Nil in results saved before trending was read.
    var trendingSeries: [BrowseItem]?
    var trendingMovies: [BrowseItem]?
    /// Titles the Popular rows leave out: talk shows, and anime unless the
    /// brand keeps it. All in Your Library still lists them.
    var leftOutOfRows: Set<String>?
    /// Every library title the server tags with the brand, plus every TMDb
    /// match, for the All in Your Library grid. It has no cap.
    var all: [BrowseItem] = []
    /// Titles in `all`. Ranks the automatic picks.
    var matchCount = 0
    var count: Int { matchCount }

    /// Every title the page can show, for reading poster expiry.
    var items: [BrowseItem] { movies + series + recentSeries + recentMovies + (trendingSeries ?? []) + (trendingMovies ?? []) + all }
}

/// How a brand page's All in Your Library grid is narrowed and ordered, from
/// the filter menu beside its heading. It lasts while the page is open.
struct StudioNetworkLibraryFilter: Equatable {
    enum Show: CaseIterable {
        case all, movies, series

        var label: String {
            switch self {
            case .all: String(localized: "All")
            case .movies: String(localized: "Movies")
            case .series: String(localized: "TV Shows")
            }
        }

        func includes(_ item: BrowseItem) -> Bool {
            switch self {
            case .all: true
            case .movies: item.type == "movie"
            case .series: item.type == "series"
            }
        }
    }

    var show = Show.all
    /// The libraries' sort keys, newest added first to begin with.
    var sort = CatalogSortKey.addedAt
    var order = CatalogSortKey.addedAt.defaultOrder
    var genre: String?

    /// Sorts by `key` in its natural order, or flips the order when it's
    /// already the sort, as the libraries' Sort menu does.
    mutating func choose(_ key: CatalogSortKey) {
        if key == sort {
            order = order.flipped
        } else {
            sort = key
            order = key.defaultOrder
        }
    }

    /// Narrower than every title, so the menu's button shows it's in use.
    var isNarrowed: Bool { show != .all || genre != nil }

    /// The menu button's text.
    var label: String {
        guard let genre else { return show.label }
        // The app's shared "A · B" key, which every language keeps as is.
        return String(localized: "\(show.label) · \(genre)")
    }

    /// Whether there are both movies and series to choose between.
    static func offersShow(in items: [BrowseItem]) -> Bool {
        items.contains { $0.type == "movie" } && items.contains { $0.type == "series" }
    }

    /// Genres of the titles `show` keeps, A to Z.
    func genres(in items: [BrowseItem]) -> [String] {
        Set(items.filter(show.includes).flatMap { $0.genres ?? [] })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Shows `option`, dropping a chosen genre none of its titles have so the
    /// grid never empties.
    mutating func setShow(_ option: Show, in items: [BrowseItem]) {
        show = option
        if let genre, !genres(in: items).contains(genre) { self.genre = nil }
    }

    func apply(to items: [BrowseItem]) -> [BrowseItem] {
        let kept = items.filter { item in
            show.includes(item) && (genre.map { item.genres?.contains($0) == true } ?? true)
        }
        func byTitle(_ lhs: BrowseItem, _ rhs: BrowseItem) -> Bool {
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        // Titles without a value go last in either order, and ties fall
        // back to the title.
        func ordered<Value: Comparable>(_ value: (BrowseItem) -> Value?) -> [BrowseItem] {
            kept.sorted { lhs, rhs in
                switch (value(lhs), value(rhs)) {
                case let (l?, r?) where l != r: order == .asc ? l < r : l > r
                case (.some, nil): true
                case (nil, .some): false
                default: byTitle(lhs, rhs)
                }
            }
        }
        return switch sort {
        case .title: order == .asc ? kept.sorted(by: byTitle) : kept.sorted { byTitle($1, $0) }
        case .addedAt: ordered(\.addedAt)
        // Emby and Jellyfin send a time after the date, Silo the date alone.
        case .releaseDate: ordered { $0.releaseDate.map { String($0.prefix(10)) } ?? $0.year.map { String($0) } }
        case .year: ordered(\.year)
        // The TMDb rating stands in where there's no IMDb one. On Emby and
        // Jellyfin it's the community rating.
        case .ratingImdb: ordered { $0.ratingImdb ?? $0.ratingTmdb }
        case .runtime: ordered(\.runtime)
        case .resolution: ordered { Self.resolutionHeight($0.overlaySummary?.resolution) }
        }
    }

    /// A resolution badge such as "2160p", "4K" or "SD" as a height in lines.
    static func resolutionHeight(_ badge: String?) -> Int? {
        guard let badge = badge?.lowercased().trimmingCharacters(in: .whitespaces), !badge.isEmpty else { return nil }
        if badge == "sd" { return 480 }
        if badge.hasSuffix("k"), let thousands = Int(badge.dropLast()) { return thousands * 540 }
        return Int(badge.prefix { $0.isNumber })
    }
}

/// The filter menu's choices, shared by iPhone, iPad and Apple TV.
struct StudioNetworkFilterMenuContent: View {
    @Binding var filter: StudioNetworkLibraryFilter
    let items: [BrowseItem]

    var body: some View {
        if StudioNetworkLibraryFilter.offersShow(in: items) {
            Section("Show") {
                ForEach(StudioNetworkLibraryFilter.Show.allCases, id: \.self) { option in
                    Button { filter.setShow(option, in: items) } label: { choice(option.label, isOn: option == filter.show) }
                }
            }
        }
        Menu("Sort") {
            ForEach(CatalogSortKey.available(for: .mixed), id: \.self) { key in
                Button { filter.choose(key) } label: { sortChoice(key) }
            }
        }
        let genres = filter.genres(in: items)
        if !genres.isEmpty {
            Menu("Genre") {
                Button { filter.genre = nil } label: { choice(String(localized: "All Genres"), isOn: filter.genre == nil) }
                ForEach(genres, id: \.self) { genre in
                    Button { filter.genre = genre } label: { choice(genre, isOn: filter.genre == genre) }
                }
            }
        }
    }

    @ViewBuilder
    private func choice(_ title: String, isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Marks the current sort the way each platform's library Sort menu does.
    @ViewBuilder
    private func sortChoice(_ key: CatalogSortKey) -> some View {
        if key != filter.sort {
            Text(key.label)
        } else {
            #if os(tvOS)
            Label("\(key.label) · \(key.directionLabel(for: filter.order))", systemImage: "checkmark")
            #else
            Label(key.label, systemImage: filter.order == .asc ? "arrow.up" : "arrow.down")
            #endif
        }
    }
}

/// Decodes a catalogue item together with the TMDb ID providers attach.
private struct StudioNetworkIndexedItem: Decodable, Sendable {
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

private struct StudioNetworkIndexPage: Decodable, Sendable {
    let items: [StudioNetworkIndexedItem]
    let hasMore: Bool?
    /// Asked for on the first page only, so the rest can load together.
    let total: Int?
}

private struct StudioNetworkResultsFile: Codable, Sendable {
    let savedAt: Date
    let results: [String: StudioNetworkResult]
    /// How the results were matched. Results saved by an older version are
    /// matched again on the next load instead of waiting for the daily refresh.
    var revision: Int?
}

/// The library scan is the slow part, so it's cached on its own and the quick
/// TMDb step can rerun without it.
private struct StudioNetworkIndexFile: Codable, Sendable {
    let savedAt: Date
    let movies: [String: BrowseItem]
    let series: [String: BrowseItem]
    /// Library titles by the brand the server tags them with, in title order.
    var tagged: [String: [BrowseItem]]?
    /// The matching revision the tags were read with. An index saved before
    /// tags were read, or before a brand's names changed, is read again.
    var revision: Int?
}

/// Finds the brands a title's server tags put it under. A network counts a
/// title's networks and studios, as Emby and Jellyfin keep a series' network
/// with its studios; a studio counts studios only. Names match whole, ignoring
/// case, accents and spaces around them, so Disney Channel is never Disney+,
/// unless the brand counts every name with a given beginning.
struct StudioNetworkTagMatcher: Sendable {
    private var networks: [String: [String]] = [:]
    private var studios: [String: [String]] = [:]
    private var networkPrefixes: [(prefix: String, id: String)] = []
    private var studioPrefixes: [(prefix: String, id: String)] = []

    init(_ brands: [StudioNetworkBrand]) {
        for brand in brands {
            let prefixes = brand.libraryNamePrefixes.map { (prefix: Self.key($0), id: brand.id) }
            for name in Set(brand.libraryNames.map(Self.key)) {
                switch brand.kind {
                case .network: networks[name, default: []].append(brand.id)
                case .studio: studios[name, default: []].append(brand.id)
                }
            }
            switch brand.kind {
            case .network: networkPrefixes += prefixes
            case .studio: studioPrefixes += prefixes
            }
        }
    }

    func brandIDs(for item: BrowseItem) -> [String] {
        let studioNames = Set((item.studios ?? []).map(Self.key))
        let networkNames = studioNames.union((item.networks ?? []).map(Self.key))
        func ids(_ names: Set<String>, _ exact: [String: [String]], _ prefixes: [(prefix: String, id: String)]) -> [String] {
            names.flatMap { name in (exact[name] ?? []) + prefixes.filter { name.hasPrefix($0.prefix) }.map(\.id) }
        }
        let found = ids(networkNames, networks, networkPrefixes) + ids(studioNames, studios, studioPrefixes)
        return Array(NSOrderedSet(array: found).array.compactMap { $0 as? String })
    }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Only the movie cards from a saved library index. Decoding this skips the
/// series and every field a poster card doesn't use.
private struct StudioNetworkIndexMovieCards: Decodable, Sendable {
    let savedAt: Date
    let movies: [String: SimilarPosterItem]
}

/// The movie and series cards from a saved library index, for Search.
/// Decoding this skips the brand tags' copies of them.
private struct StudioNetworkIndexTitles: Decodable, Sendable {
    let movies: [String: BrowseItem]
    let series: [String: BrowseItem]
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

/// Caps how many requests run at once. Each `run` waits for a free slot.
actor RequestGate {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if available > 0 { available -= 1 } else { await withCheckedContinuation { waiting.append($0) } }
        defer { if waiting.isEmpty { available += 1 } else { waiting.removeFirst().resume() } }
        try Task.checkCancellation()
        return try await operation()
    }
}

/// Loads, matches, caches and remembers the pinned Studios & Networks row.
///
/// Uses Vivid's TMDb relay. TMDb supplies each brand's logo and its
/// popularity-ordered titles; only titles in the library are kept, matched by
/// TMDb ID when the server lists one and otherwise by exact title and year.
/// Results and the library index are cached per server and profile, so Home
/// shows the row instantly and refreshes once a day in the background.
@MainActor
@Observable
final class StudiosNetworksStore {
    static let shared = StudiosNetworksStore()

    /// The most brands the row can hold, and how many automatic shows.
    static let maxPicks = 20
    /// The fewest a chosen set can have while the row shows on Home.
    static let minimumPicks = 6
    /// Tiles across the screen or settings preview at once. The row
    /// scrolls past these; it's layout only, not a pick limit.
    static let visibleTiles = 6
    /// Below this a tile or page row would look empty, so it's hidden.
    static let minimumCount = 6
    static let rowLimit = 20
    /// TMDb discover pages read per list (20 titles each).
    nonisolated static let pagesPerList = 5
    /// Pages read of a network's films. Servers don't tag films with a
    /// streaming service, so its TMDb list is the only way they reach All in
    /// Your Library, and it's read twice as deep. The relay allows 10.
    nonisolated static let networkMoviePages = 10
    /// Bumped when matching changes, so saved results are matched again.
    nonisolated static let resultsRevision = 4
    /// Bumped when a brand's names change, so the saved library index is
    /// tagged again. Reading the library is the slow part, so it's separate.
    nonisolated static let indexRevision = 3
    /// Pages read of each of TMDb's weekly trending lists (20 titles each).
    /// They're shared by every brand, so they're read deeper than a brand's
    /// own list. The relay allows 25.
    nonisolated static let trendingPages = 25
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// Silo signs artwork URLs for a few hours, far less than the daily
    /// refresh, so posters are re-read this long before the first one expires.
    nonisolated static let artworkRefreshLead: TimeInterval = 15 * 60
    /// Least time between poster refreshes, in case the server's URLs come
    /// back already near expiry or the device clock runs ahead.
    static let artworkRefreshCooldown: TimeInterval = 15 * 60
    /// TMDb requests in flight at once across every brand, below the 15 the
    /// load used before, so a refresh stays well inside the relay's limits.
    nonisolated static let concurrentRequests = 12

    nonisolated static let catalogue: [StudioNetworkBrand] = [
        .init(id: "netflix", name: "Netflix", kind: .network, tmdbId: 213, watchProviderIds: [8], libraryNames: ["Netflix"]),
        .init(id: "hbo", name: "HBO", kind: .network, tmdbId: 49, watchProviderIds: [1899], libraryNames: ["HBO", "HBO Max", "Max"]),
        .init(id: "appletv", name: "Apple TV", kind: .network, tmdbId: 2552, watchProviderIds: [350], usesWordmark: true,
              libraryNames: ["Apple TV", "Apple TV+"]),
        .init(id: "disneyplus", name: "Disney+", kind: .network, tmdbId: 2739, watchProviderIds: [337], libraryNames: ["Disney+"]),
        .init(id: "prime", name: "Prime Video", kind: .network, tmdbId: 1024, watchProviderIds: [9],
              libraryNames: ["Prime Video", "Amazon Prime Video", "Amazon"]),
        .init(id: "hulu", name: "Hulu", kind: .network, tmdbId: 453, watchProviderIds: [15], libraryNames: ["Hulu"]),
        .init(id: "peacock", name: "Peacock", kind: .network, tmdbId: 3353, watchProviderIds: [386, 387], libraryNames: ["Peacock"]),
        .init(id: "paramountplus", name: "Paramount+", kind: .network, tmdbId: 4330, watchProviderIds: [2303, 2616],
              libraryNames: ["Paramount+", "Paramount+ with Showtime"]),
        .init(id: "stan", name: "Stan", kind: .network, tmdbId: 1255, watchProviderIds: [21], watchRegion: "AU", libraryNames: ["Stan"]),
        // BritBox mostly streams BBC and ITV series, which servers tag with
        // the channel that first showed them.
        .init(id: "britbox", name: "BritBox", kind: .network, tmdbId: 4025, watchProviderIds: [151, 197, 1852],
              listsSeriesByWatchProvider: true,
              libraryNames: ["BritBox", "BBC", "BBC One", "BBC Two", "BBC Three", "BBC Four", "BBC Choice", "BBC Scotland",
                             "BBC Alba", "BBC iPlayer", "CBBC", "CBeebies", "ITV", "ITV1", "ITV2", "ITV3", "ITV4", "ITVBe",
                             "ITVX", "ITV Encore"]),
        .init(id: "amc", name: "AMC", kind: .network, tmdbId: 174, watchProviderIds: [80, 526, 528, 635, 1854], libraryNames: ["AMC", "AMC+"]),
        .init(id: "fx", name: "FX", kind: .network, tmdbId: 88, watchProviderIds: [123], libraryNames: ["FX", "FXX"]),
        .init(id: "pixar", name: "Pixar", kind: .studio, tmdbId: 3, libraryNames: ["Pixar", "Pixar Animation Studios"]),
        .init(id: "marvel", name: "Marvel Studios", kind: .studio, tmdbId: 420, knocksOutLogoText: true, libraryNames: ["Marvel Studios"]),
        .init(id: "a24", name: "A24", kind: .studio, tmdbId: 41077, libraryNames: ["A24"]),
        .init(id: "lucasfilm", name: "Lucasfilm", kind: .studio, tmdbId: 1, libraryNames: ["Lucasfilm", "Lucasfilm Ltd.", "Lucasfilm Animation"]),
        .init(id: "dreamworks", name: "DreamWorks", kind: .studio, tmdbId: 521, labelIds: [7],
              libraryNames: ["DreamWorks", "DreamWorks Animation", "DreamWorks Animation Television", "DreamWorks Pictures",
                             "DreamWorks Television"]),
        .init(id: "ghibli", name: "Studio Ghibli", kind: .studio, tmdbId: 10342, keepsAnime: true, libraryNames: ["Studio Ghibli"]),
        .init(id: "sony", name: "Sony Pictures", kind: .studio, tmdbId: 34, labelIds: [5, 2251, 559], stacksLogoWords: true,
              libraryNames: ["Sony Pictures", "Columbia Pictures", "Sony Pictures Animation", "TriStar Pictures"]),
        .init(id: "warnerbros", name: "Warner Bros.", kind: .studio, tmdbId: 174, labelIds: [2785, 1957], knocksOutLogoText: true,
              logoHeightScale: 1.35, libraryNamePrefixes: ["Warner Bros", "Warner Brothers"]),
        .init(id: "universal", name: "Universal", kind: .studio, tmdbId: 33, libraryNames: ["Universal Pictures"]),
        .init(id: "disney", name: "Walt Disney Pictures", kind: .studio, tmdbId: 2, labelIds: [6125],
              libraryNames: ["Walt Disney Pictures", "Walt Disney Animation Studios"]),
        .init(id: "dc", name: "DC", kind: .studio, tmdbId: 429, labelIds: [128064, 9993], knocksOutLogoText: true, logoHeightScale: 1.35,
              libraryNames: ["DC", "DC Comics", "DC Entertainment", "DC Films", "DC Studios"]),
        .init(id: "20thcentury", name: "20th Century Studios", kind: .studio, tmdbId: 127928, labelIds: [25], logoHeightScale: 1.35,
              libraryNames: ["20th Century Studios", "20th Century Fox"]),
    ]

    nonisolated static let tagMatcher = StudioNetworkTagMatcher(catalogue)

    static let firstLoadNotice = String(localized: "Setting up Studios & Networks for the first time. Vivid is reading your library and matching it with TMDb, which can take a few minutes on a large library. Keep Vivid open until it finishes. After this it loads instantly.")

    enum Status: Equatable { case idle, needsAccount, loading, ready, failed }

    private(set) var status: Status = .idle
    private(set) var results: [String: StudioNetworkResult] = [:]
    /// Live progress for the first-load notice.
    private(set) var progressText: String?
    private(set) var isEnabled = true
    /// nil means automatic: the top brands by library matches.
    private(set) var customPicks: [String]?
    /// While a settings editor is open, picks can drop below the required
    /// six so a brand can be swapped. Elsewhere they're topped up to six.
    private(set) var isEditing = false

    private var loadedScope: Scope?
    /// When the shown results were matched, kept when only their posters are
    /// refreshed so the daily TMDb refresh stays on schedule.
    private var resultsSavedAt: Date?
    /// The matching revision of the shown results, kept by a poster refresh
    /// so older results are still matched again.
    private var resultsSavedRevision: Int?
    /// When the first signed poster URL in the results stops working. Nil
    /// when none carries an expiry, as with Emby and Jellyfin.
    private var artworkExpiresAt: Date?
    private var artworkRefreshedAt: Date?
    private var titlesRead: [String: Int] = [:]
    /// Brands whose TMDb lists have arrived in the current load.
    private var listsLoaded = 0
    private var libraryIsRead = false
    private var loadTask: Task<Void, Never>?
    /// A load or refresh is running for the current server and profile.
    var isLoading: Bool { loadTask != nil }
    private let defaults = SharedDefaults.shared
    @ObservationIgnored private var movieLookupCache: (scope: Scope, modified: Date, lookup: LibraryMovieLookup)?
    @ObservationIgnored private var searchIndexCache: (scope: Scope, modified: Date, index: LibrarySearchIndex)?
    @ObservationIgnored private var searchIndexTask: Task<Void, Never>?
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

    /// Keeps up to 20 chosen brands, topping a set below six up with the
    /// most-matched brands not already chosen, so Home never shows a
    /// sparse row. Six or more are kept exactly as chosen.
    static func filled(_ chosen: [String], counts: [String: Int]) -> [String] {
        let eligible = Array(chosen.filter { (counts[$0] ?? 0) >= minimumCount }.prefix(maxPicks))
        guard eligible.count < minimumPicks else { return eligible }
        let extra = automaticPicks(counts: counts).filter { !eligible.contains($0) }
        return Array((eligible + extra).prefix(minimumPicks))
    }

    var picks: [String] {
        let chosen = (customPicks ?? automaticPicks).filter(isEligible)
        return isEditing ? chosen : Self.filled(chosen, counts: results.mapValues(\.count))
    }

    /// Six, or every eligible brand when a small library has fewer.
    var requiredPicks: Int {
        min(Self.minimumPicks, Self.catalogue.filter { isEligible($0.id) }.count)
    }

    /// The editor can't be closed until this is false, unless the row is
    /// turned off.
    var needsMorePicks: Bool { isEnabled && picks.count < requiredPicks }

    var missingPicks: Int { max(0, requiredPicks - picks.count) }

    /// Starts editing with at least six, saving any top-up of older choices
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

    /// Rows for a brand page. This week's trending titles lead, and the
    /// brand's popular titles fill the rest of the row. Networks fill from the
    /// past 12 months, falling back to all-time popular when the year is too
    /// thin to fill a row (Apple releases few films); studios fill from their
    /// all-time popular. Talk shows, and anime unless the brand keeps it, are
    /// left out.
    func pageRows(for id: String) -> [(title: String, items: [BrowseItem])] {
        Self.pageRows(for: brand(id), result: results[id] ?? StudioNetworkResult())
    }

    static func pageRows(for brand: StudioNetworkBrand?, result: StudioNetworkResult) -> [(title: String, items: [BrowseItem])] {
        let isStudio = brand?.kind == .studio
        let leftOut = result.leftOutOfRows ?? []
        func shown(_ items: [BrowseItem]) -> [BrowseItem] { items.filter { !leftOut.contains($0.contentId) } }
        func pick(recent: [BrowseItem], allTime: [BrowseItem]) -> [BrowseItem] {
            isStudio || shown(recent).count < minimumCount ? allTime : recent
        }
        func row(trending: [BrowseItem]?, popular: [BrowseItem]) -> [BrowseItem] {
            var seen = Set<String>()
            return shown((trending ?? []) + popular).filter { seen.insert($0.contentId).inserted }
        }
        let series = (title: String(localized: "Popular TV Shows"),
                      items: row(trending: result.trendingSeries, popular: pick(recent: result.recentSeries, allTime: result.series)))
        let movies = (title: String(localized: "Popular Movies"),
                      items: row(trending: result.trendingMovies, popular: pick(recent: result.recentMovies, allTime: result.movies)))
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
            searchIndexCache = nil
            results = [:]
            resultsSavedAt = nil
            resultsSavedRevision = nil
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
            status = .needsAccount
            return
        }
        if let loadTask {
            await loadTask.value
            // A load that failed keeps the saved results, whose posters may
            // still need fresh links. A failed library read has already
            // started the cooldown, so it's tried again on a later visit.
            guard self.loadTask == nil, status == .ready, artworkNeedsRefresh else { return }
        }
        guard let scope = loadedScope else { return }
        // Ready results only need fresh posters, for an app left open past
        // their expiry.
        let isReady = status == .ready
        if isReady, !artworkNeedsRefresh { return }
        // A retry shows as loading straight away, so nothing waiting on it
        // mistakes the last attempt's failure for this one's.
        if status == .failed || status == .needsAccount { status = .loading }
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
            resultsSavedRevision = cached.revision
            status = .ready
            topUpForEditing()
            let expiry = await Self.artworkExpiry(in: cached.results)
            guard loadedScope == scope else { return }
            artworkExpiresAt = expiry
            // Brands added since the results were saved have nothing to show
            // until they're matched, so a new brand refreshes them early, as
            // do results matched the way an older version did.
            let missesBrands = Self.catalogue.contains { cached.results[$0.id] == nil }
            let isOutdated = cached.revision != Self.resultsRevision
            guard missesBrands || isOutdated || Date().timeIntervalSince(cached.savedAt) > Self.refreshInterval else {
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
        listsLoaded = 0
        libraryIsRead = false
        do {
            // TMDb's lists don't depend on the library, so they download while
            // the library is read and are matched once both are in. Any TMDb
            // failure throws to the catch below, so a partial result never
            // replaces good saved results or resets the refresh timer.
            let brands = Self.catalogue
            let gate = RequestGate(limit: Self.concurrentRequests)
            async let lists = Self.brandLists(brands, gate: gate) { [weak self] in self?.noteListsLoaded(scope) }
            async let trending = Self.trendingLists(gate: gate)
            let index: StudioNetworkIndexFile
            if let cached = await Self.read(StudioNetworkIndexFile.self, scope.cacheURL("library")),
               cached.revision == Self.indexRevision,
               Date().timeIntervalSince(cached.savedAt) < Self.refreshInterval,
               await Self.hasCurrentArtwork(cached) {
                index = cached
            } else {
                // Counts as a poster refresh, so a page that waited on a read
                // that failed doesn't read the library again straight away.
                // Not once the account or profile has switched.
                if loadedScope == scope { artworkRefreshedAt = Date() }
                index = try await readLibrary(scope, reportsProgress: true)
            }
            await Self.saveMovieLookup(index, to: scope.cacheURL("movies"))
            libraryIsRead = true
            if loadedScope == scope { showMatchingProgress() }
            // The saved results stay on screen while TMDb is matched, and stay
            // if it fails, so expired posters take the library's fresh links now.
            if loadedScope == scope, !results.isEmpty, artworkHasLapsed {
                await applyArtwork(from: index, scope)
            }
            let loaded = await Self.matched(try await lists, trending: await trending, index: index)
            try Task.checkCancellation()
            guard loadedScope == scope else { return }
            let savedAt = Date()
            results = loaded
            resultsSavedAt = savedAt
            resultsSavedRevision = Self.resultsRevision
            status = .ready
            topUpForEditing()
            progressText = nil
            await Self.write(StudioNetworkResultsFile(savedAt: savedAt, results: loaded, revision: Self.resultsRevision),
                             scope.cacheURL("results"))
            let expiry = await Self.artworkExpiry(in: loaded)
            if loadedScope == scope { artworkExpiresAt = expiry }
        } catch {
            guard loadedScope == scope else { return }
            progressText = nil
            // Keep showing saved results if only the background refresh failed.
            if results.isEmpty { status = .failed }
        }
    }

    private func noteListsLoaded(_ scope: Scope) {
        guard loadedScope == scope else { return }
        listsLoaded += 1
        showMatchingProgress()
    }

    /// Library progress shows until the library is read, then TMDb's.
    private func showMatchingProgress() {
        guard libraryIsRead, status != .ready else { return }
        progressText = String(localized: "Matching with TMDb… \(listsLoaded) of \(Self.catalogue.count)", comment: "Studios & Networks first-load progress: brands matched of the total")
    }

    // MARK: Poster refresh

    private var artworkNeedsRefresh: Bool {
        guard artworkHasLapsed else { return false }
        guard let artworkRefreshedAt else { return true }
        return Date().timeIntervalSince(artworkRefreshedAt) > Self.artworkRefreshCooldown
    }

    /// Whether the shown posters' links have expired or are about to.
    private var artworkHasLapsed: Bool { Self.artworkHasLapsed(expiresAt: artworkExpiresAt) }

    /// Links without an expiry (Emby, Jellyfin, unsigned) never lapse.
    nonisolated static func artworkHasLapsed(expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < artworkRefreshLead
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
            await applyArtwork(from: index, scope)
        } catch {
            // Keep the current results. The next visit after the cooldown
            // tries again, and the daily refresh reads the library anyway.
        }
    }

    /// Swaps a library read's poster links into the shown results and saves
    /// them, keeping when they were matched.
    private func applyArtwork(from index: StudioNetworkIndexFile, _ scope: Scope) async {
        let current = results
        let refreshed = await Task.detached(priority: .utility) {
            Self.replacingArtwork(in: current, with: [index.movies.values, index.series.values].joined(),
                                  tagged: index.tagged ?? [:])
        }.value
        let expiry = await Self.artworkExpiry(in: refreshed)
        guard loadedScope == scope else { return }
        results = refreshed
        artworkExpiresAt = expiry
        await Self.write(StudioNetworkResultsFile(savedAt: resultsSavedAt ?? Date(), results: refreshed,
                                                  revision: resultsSavedRevision),
                         scope.cacheURL("results"))
    }

    /// The results with every title replaced by its entry from a fresh
    /// library read, which carries current artwork. Titles no longer in the
    /// library are dropped, so an expired URL can't linger, and the match
    /// count follows so a brand that falls below six leaves Home. All in Your
    /// Library takes the fresh server tags, so titles added since the daily
    /// refresh show without asking TMDb again.
    nonisolated static func replacingArtwork(
        in results: [String: StudioNetworkResult],
        with titles: some Sequence<BrowseItem>,
        tagged: [String: [BrowseItem]]
    ) -> [String: StudioNetworkResult] {
        var current: [String: BrowseItem] = [:]
        for title in titles { current[title.contentId] = title }
        func refreshed(_ items: [BrowseItem]) -> [BrowseItem] { items.compactMap { current[$0.contentId] } }
        return Dictionary(uniqueKeysWithValues: results.map { id, result in
            var result = result
            result.movies = refreshed(result.movies)
            result.series = refreshed(result.series)
            result.recentSeries = refreshed(result.recentSeries)
            result.recentMovies = refreshed(result.recentMovies)
            result.trendingSeries = result.trendingSeries.map(refreshed)
            result.trendingMovies = result.trendingMovies.map(refreshed)
            result.all = libraryTitles(tagged: tagged[id] ?? [], matched: result.movies + result.series)
            result.matchCount = result.all.count
            return (id, result)
        })
    }

    /// All in Your Library: every title the server tags with the brand, then
    /// the TMDb matches it doesn't, each title once. TMDb is the only source
    /// of a network's films, and finds a studio's films a server lists
    /// without that studio.
    nonisolated static func libraryTitles(tagged: [BrowseItem], matched: [BrowseItem]) -> [BrowseItem] {
        var seen = Set<String>()
        return (tagged + matched).filter { seen.insert($0.contentId).inserted }
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
            let titles = self.titlesRead.values.reduce(0, +).formatted()
            self.progressText = String(localized: "Reading your library… \(titles) titles", comment: "Studios & Networks first-load progress. The count is already formatted, e.g. 1,234")
        }
        async let movies = Self.libraryIndex(type: "movie", report: report)
        async let series = Self.libraryIndex(type: "series", report: report)
        let (movieIndex, seriesIndex) = try await (movies, series)
        let index = StudioNetworkIndexFile(
            savedAt: Date(), movies: movieIndex.index, series: seriesIndex.index,
            tagged: movieIndex.tagged.merging(seriesIndex.tagged) { $0 + $1 }, revision: Self.indexRevision
        )
        await Self.write(index, scope.cacheURL("library"))
        return index
    }

    /// Library pages read at once once the first page has given the total.
    private nonisolated static let concurrentLibraryPages = 4
    /// 200 per page, the same shape as the app's browse queries.
    private nonisolated static let libraryPageSize = 200

    /// Every library title of one type, keyed by TMDb ID and by title + year,
    /// and by the brands the server tags it with. Runs off the main actor:
    /// building the index folds every library title, which would stall
    /// scrolling during the daily refresh.
    private nonisolated static func libraryIndex(
        type: String,
        report: @MainActor (String, Int) -> Void
    ) async throws -> (index: [String: BrowseItem], tagged: [String: [BrowseItem]]) {
        @Sendable func page(_ offset: Int, total: Bool) async throws -> StudioNetworkIndexPage {
            try await VividAPI.shared.catalog(query: [
                "source": "query", "type": type, "offset": String(offset), "limit": String(libraryPageSize),
                "sort": "title", "order": "asc", "match": "all", "include_total": total ? "true" : "false",
            ], as: StudioNetworkIndexPage.self)
        }
        var index: [String: BrowseItem] = [:]
        var tagged: [String: [BrowseItem]] = [:]
        // A title added while reading shifts later pages, so one can arrive twice.
        var taggedIDs = Set<String>()
        func add(_ page: StudioNetworkIndexPage) {
            for entry in page.items {
                var kept = false
                if let id = entry.tmdbId, !id.isEmpty, index[id] == nil {
                    index[id] = entry.item
                    kept = true
                }
                // Servers that leave provider IDs out of lists still match here.
                if let year = entry.item.year {
                    let key = titleKey(entry.item.title, year: year)
                    if index[key] == nil {
                        index[key] = entry.item
                        kept = true
                    }
                }
                // A title without either key, or whose keys an earlier title
                // took, such as a second copy of a film, is kept for Search,
                // which reads every title. Nothing looks a title up by this key.
                if !kept { index["c:" + entry.item.contentId] = entry.item }
                // Every title is checked, including those without a year or
                // TMDb ID, which the keys above can't hold.
                let brands = tagMatcher.brandIDs(for: entry.item)
                if !brands.isEmpty, taggedIDs.insert(entry.item.contentId).inserted {
                    for brand in brands { tagged[brand, default: []].append(entry.item) }
                }
            }
        }
        try Task.checkCancellation()
        let first = try await page(0, total: true)
        add(first)
        var offset = first.items.count
        var more = first.hasMore == true && !first.items.isEmpty
        await report(type, offset)
        // With a total and full pages, the rest load a few at a time and are
        // added in title order. A server that sends smaller pages than asked,
        // or no total, is read one page at a time below.
        if more, first.items.count == libraryPageSize, let total = first.total, total > offset {
            let offsets = Array(stride(from: offset, to: min(total, libraryPageSize * 500), by: libraryPageSize))
            for start in stride(from: 0, to: offsets.count, by: concurrentLibraryPages) {
                try Task.checkCancellation()
                let batch = Array(offsets[start..<min(start + concurrentLibraryPages, offsets.count)])
                let pages = try await withThrowingTaskGroup(of: (Int, StudioNetworkIndexPage).self) { group in
                    for pageOffset in batch { group.addTask { (pageOffset, try await page(pageOffset, total: false)) } }
                    var found: [Int: StudioNetworkIndexPage] = [:]
                    for try await (pageOffset, result) in group { found[pageOffset] = result }
                    return batch.compactMap { found[$0] }
                }
                for result in pages { add(result) }
                guard let lastOffset = batch.last, let last = pages.last else { break }
                offset = lastOffset + last.items.count
                more = last.hasMore == true && !last.items.isEmpty
                await report(type, offset)
                if !more { break }
            }
        }
        // Titles added while reading, or a server without a total.
        for _ in 0..<500 where more {
            try Task.checkCancellation()
            let result = try await page(offset, total: false)
            add(result)
            offset += result.items.count
            more = result.hasMore == true && !result.items.isEmpty
            await report(type, offset)
        }
        return (index, tagged)
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
    /// TMDb discover filters for a brand's series and films. Series come from
    /// the network or company, studio films from the company, and network
    /// films from the streaming list, as do a few networks' series.
    nonisolated static func discoverQueries(for brand: StudioNetworkBrand) -> (series: [String: String], movies: [String: String]?) {
        let companies = ([brand.tmdbId] + brand.labelIds).map(String.init).joined(separator: "|")
        let network = ["with_networks": String(brand.tmdbId)]
        let streaming: [String: String]? = brand.watchProviderIds.isEmpty ? nil : [
            "with_watch_providers": brand.watchProviderIds.map(String.init).joined(separator: "|"),
            "watch_region": brand.watchRegion,
            "with_watch_monetization_types": "flatrate",
        ]
        return switch brand.kind {
        case .studio: (["with_companies": companies], ["with_companies": companies])
        case .network: (brand.listsSeriesByWatchProvider ? streaming ?? network : network, streaming)
        }
    }

    /// One brand's TMDb lists, before they're matched with the library.
    struct BrandLists: Sendable {
        var logoURL: URL?
        var series: [TVTMDbStore.DiscoverPage.Result] = []
        var recentSeries: [TVTMDbStore.DiscoverPage.Result] = []
        var movies: [TVTMDbStore.DiscoverPage.Result] = []
        var recentMovies: [TVTMDbStore.DiscoverPage.Result] = []
    }

    /// Every brand's lists at once. The request gate, shared with the trending
    /// lists, not the brand count, limits how much reaches TMDb.
    private nonisolated static func brandLists(
        _ brands: [StudioNetworkBrand],
        gate: RequestGate,
        loaded: @escaping @MainActor () -> Void
    ) async throws -> [String: BrandLists] {
        let today = Date()
        let from = dayFormatter.string(from: Calendar.current.date(byAdding: .month, value: -12, to: today) ?? today)
        let to = dayFormatter.string(from: today)
        return try await withThrowingTaskGroup(of: (String, BrandLists).self) { group in
            for brand in brands {
                group.addTask { (brand.id, try await Self.lists(for: brand, from: from, to: to, gate: gate)) }
            }
            var all: [String: BrandLists] = [:]
            for try await (id, found) in group {
                all[id] = found
                await loaded()
            }
            return all
        }
    }

    private nonisolated static func lists(
        for brand: StudioNetworkBrand, from: String, to: String, gate: RequestGate
    ) async throws -> BrandLists {
        let (seriesQuery, movieQuery) = discoverQueries(for: brand)
        let recentSeriesQuery = seriesQuery.merging(["air_date.gte": from, "air_date.lte": to]) { $1 }
        let recentMovieQuery = movieQuery?.merging(["primary_release_date.gte": from, "primary_release_date.lte": to]) { $1 }

        async let logo = logoURL(for: brand, gate: gate)
        async let series = discoverResults("tv", seriesQuery, pages: pagesPerList, gate: gate)
        async let recentSeries = discoverResults("tv", recentSeriesQuery, pages: pagesPerList, gate: gate)
        async let movies = discoverResults("movie", movieQuery, pages: moviePages(for: brand), gate: gate)
        async let recentMovies = discoverResults("movie", recentMovieQuery, pages: pagesPerList, gate: gate)
        return try await BrandLists(logoURL: logo, series: series, recentSeries: recentSeries,
                                    movies: movies, recentMovies: recentMovies)
    }

    nonisolated static func moviePages(for brand: StudioNetworkBrand) -> Int {
        brand.kind == .network ? networkMoviePages : pagesPerList
    }

    /// This week's worldwide trending series and movies, read once for every
    /// brand.
    struct TrendingLists: Sendable {
        var series: [TVTMDbStore.DiscoverPage.Result] = []
        var movies: [TVTMDbStore.DiscoverPage.Result] = []
    }

    private nonisolated static func trendingLists(gate: RequestGate) async -> TrendingLists {
        async let series = trendingResults("tv", gate: gate)
        async let movies = trendingResults("movie", gate: gate)
        return await TrendingLists(series: series, movies: movies)
    }

    /// The first `trendingPages` pages of one trending list, in trending order.
    /// A page that fails is skipped, and without the first the Popular rows
    /// keep the brand's popular order, so trending never fails a refresh.
    private nonisolated static func trendingResults(
        _ media: String, gate: RequestGate
    ) async -> [TVTMDbStore.DiscoverPage.Result] {
        @Sendable func page(_ number: Int) async -> TVTMDbStore.DiscoverPage? {
            try? await Self.retryingOnce {
                try await gate.run { try await TVTMDbStore.shared.trending(media: media, page: number) }
            }
        }
        guard let first = await page(1) else { return [] }
        let last = min(trendingPages, first.totalPages ?? 1)
        guard last > 1 else { return first.results }
        let rest = await withTaskGroup(of: (Int, [TVTMDbStore.DiscoverPage.Result]).self) { group in
            for number in 2...last { group.addTask { (number, await page(number)?.results ?? []) } }
            var pages: [Int: [TVTMDbStore.DiscoverPage.Result]] = [:]
            for await (number, results) in group { pages[number] = results }
            return (2...last).flatMap { pages[$0] ?? [] }
        }
        return first.results + rest
    }

    /// TMDb's Animation and Talk genres.
    nonisolated static let animationGenre = 16
    nonisolated static let talkGenre = 10767

    /// Whether a title belongs in a Popular row. Talk shows never do, and
    /// anime (Japanese animation, by language or country of origin) only on a
    /// brand that keeps it.
    nonisolated static func showsInPopularRows(_ result: TVTMDbStore.DiscoverPage.Result, keepsAnime: Bool) -> Bool {
        let genres = result.genreIds ?? []
        if genres.contains(talkGenre) { return false }
        guard !keepsAnime, genres.contains(animationGenre) else { return true }
        return result.originalLanguage != "ja" && !(result.originCountry ?? []).contains("JP")
    }

    /// Matches every brand's lists with the library, off the main actor.
    private nonisolated static func matched(
        _ lists: [String: BrandLists], trending: TrendingLists, index: StudioNetworkIndexFile
    ) async -> [String: StudioNetworkResult] {
        await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: lists.map { id, brandLists in
                let keepsAnime = catalogue.first { $0.id == id }?.keepsAnime ?? false
                return (id, Self.result(for: brandLists, trending: trending, keepsAnime: keepsAnime,
                                        index: index, tagged: index.tagged?[id] ?? []))
            })
        }.value
    }

    private nonisolated static func result(
        for lists: BrandLists, trending: TrendingLists, keepsAnime: Bool, index: StudioNetworkIndexFile, tagged: [BrowseItem]
    ) -> StudioNetworkResult {
        let allSeries = matches(lists.series, index.series).map(\.item)
        let allMovies = matches(lists.movies, index.movies).map(\.item)
        let all = libraryTitles(tagged: tagged, matched: allMovies + allSeries)
        let brandSeries = lists.series + lists.recentSeries
        let brandMovies = lists.movies + lists.recentMovies
        // The trending list has no brand filter, so a trending title is the
        // brand's when one of its own lists has it.
        let seriesIDs = Set(brandSeries.map(\.id))
        let movieIDs = Set(brandMovies.map(\.id))
        let leftOut = matches(brandSeries.filter { !showsInPopularRows($0, keepsAnime: keepsAnime) }, index.series)
            + matches(brandMovies.filter { !showsInPopularRows($0, keepsAnime: keepsAnime) }, index.movies)
        return StudioNetworkResult(
            logoURL: lists.logoURL,
            movies: allMovies,
            series: allSeries,
            recentSeries: matches(lists.recentSeries, index.series).map(\.item),
            recentMovies: matches(lists.recentMovies, index.movies).map(\.item),
            trendingSeries: matches(trending.series.filter { seriesIDs.contains($0.id) }, index.series).map(\.item),
            trendingMovies: matches(trending.movies.filter { movieIDs.contains($0.id) }, index.movies).map(\.item),
            leftOutOfRows: Set(leftOut.map(\.item.contentId)),
            all: all,
            matchCount: all.count
        )
    }

    private nonisolated static func logoURL(for brand: StudioNetworkBrand, gate: RequestGate) async throws -> URL? {
        guard !brand.usesWordmark else { return nil }
        return try await retryingOnce {
            try await gate.run {
                try await TVTMDbStore.shared.logoURL(kind: brand.kind == .network ? "network" : "company", id: brand.tmdbId)
            }
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

    /// The first `pages` pages of one TMDb discover list, in popularity order.
    /// The first page says how many there are, and the rest load together.
    private nonisolated static func discoverResults(
        _ media: String, _ query: [String: String]?, pages: Int, gate: RequestGate
    ) async throws -> [TVTMDbStore.DiscoverPage.Result] {
        guard let query else { return [] }
        @Sendable func page(_ number: Int) async throws -> TVTMDbStore.DiscoverPage {
            try await Self.retryingOnce {
                try await gate.run { try await TVTMDbStore.shared.discover(media: media, query: query, page: number) }
            }
        }
        let first = try await page(1)
        let last = min(pages, first.totalPages ?? 1)
        guard last > 1 else { return first.results }
        let rest = try await withThrowingTaskGroup(of: (Int, [TVTMDbStore.DiscoverPage.Result]).self) { group in
            for number in 2...last { group.addTask { (number, try await page(number).results) } }
            var pages: [Int: [TVTMDbStore.DiscoverPage.Result]] = [:]
            for try await (number, results) in group { pages[number] = results }
            return (2...last).flatMap { pages[$0] ?? [] }
        }
        return first.results + rest
    }

    /// Library matches for one TMDb list, in its popularity order.
    nonisolated static func matches(
        _ results: [TVTMDbStore.DiscoverPage.Result],
        _ index: [String: BrowseItem]
    ) -> [(item: BrowseItem, popularity: Double)] {
        var found: [(item: BrowseItem, popularity: Double)] = []
        var seen = Set<String>()
        for result in results {
            if let item = lookup(result, in: index), seen.insert(item.contentId).inserted {
                found.append((item, result.popularity ?? 0))
            }
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

    // MARK: Search index

    /// Every movie and series in the saved library index, for Search to match
    /// titles on the device. Nil while it first loads and until the library
    /// has been read, so a search never waits for it: the first call starts
    /// the load in the background. It follows the saved index, which every
    /// library read rewrites, and the previous one serves while a newer loads.
    func searchIndex() -> LibrarySearchIndex? {
        guard let scope = Scope.current, let url = scope.cacheURL("library"),
              let modified = Self.modificationDate(url) else { return nil }
        let cached = searchIndexCache.flatMap { $0.scope == scope ? $0 : nil }
        if let cached, cached.modified == modified { return cached.index }
        if searchIndexTask == nil {
            searchIndexTask = Task { [weak self] in
                let index = await Task.detached(priority: .userInitiated) { () -> LibrarySearchIndex? in
                    guard let data = try? Data(contentsOf: url),
                          let file = try? JSONDecoder().decode(StudioNetworkIndexTitles.self, from: data)
                    else { return nil }
                    return LibrarySearchIndex(items: Array([file.movies.values, file.series.values].joined()))
                }.value
                guard let self else { return }
                self.searchIndexTask = nil
                if let index, Scope.current == scope { self.searchIndexCache = (scope, modified, index) }
            }
        }
        return cached?.index
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
