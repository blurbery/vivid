#if os(tvOS)
import SwiftUI
import Observation

// PROTOTYPE ONLY, not for the PR: the pinned Studios & Networks row under the
// hero, its settings editor and the brand page. Needs the profile's TMDB key.
// TMDB supplies each brand's logo and popularity-ordered titles; only titles
// matched in the library by TMDB ID are shown. Picks live in memory only.

struct BrandTileInfo: Identifiable, Equatable {
    enum Kind { case network, studio }
    let id: String
    let name: String
    let kind: Kind
    let tmdbId: Int
    var knocksOutLogoText = false
    /// TMDB watch provider, used to find movies streaming on a network.
    var watchProviderId: Int? = nil
}

struct BrandResult: Codable {
    var logoURL: URL?
    var movies: [BrowseItem] = []
    var series: [BrowseItem] = []
    /// Series with episodes aired in the past 12 months, by popularity.
    var recentSeries: [BrowseItem] = []
    /// Movies released in the past 12 months, by popularity.
    var recentMovies: [BrowseItem] = []
    /// Movies and series merged by TMDB popularity.
    var all: [BrowseItem] = []
    var count: Int { all.count }
}

/// Decodes a catalogue item together with the TMDB ID the providers attach.
private struct IndexedBrowseItem: Decodable {
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

private struct IndexPage: Decodable {
    let items: [IndexedBrowseItem]
    let hasMore: Bool?
}

@MainActor
@Observable
final class TVBrandPrototypeStore {
    static let shared = TVBrandPrototypeStore()
    static let maxPicks = 5
    /// Below this a tile or page row would look empty, so it's hidden.
    static let minimumCount = 6
    static let rowLimit = 20
    static let pagesPerMedia = 5

    static let catalogue: [BrandTileInfo] = [
        .init(id: "netflix", name: "Netflix", kind: .network, tmdbId: 213, watchProviderId: 8),
        .init(id: "hbo", name: "HBO", kind: .network, tmdbId: 49, watchProviderId: 1899),
        .init(id: "appletv", name: "Apple TV+", kind: .network, tmdbId: 2552, watchProviderId: 350),
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

    enum Status: Equatable { case idle, needsTMDB, loading, ready, failed }

    var status: Status = .idle
    var lastError: String?
    var isEnabled = true
    /// nil means automatic: the top brands by library matches.
    var customPicks: [String]?
    var results: [String: BrandResult] = [:]
    private var loadTask: Task<Void, Never>?

    func info(_ id: String) -> BrandTileInfo? { Self.catalogue.first { $0.id == id } }
    func count(_ id: String) -> Int { results[id]?.count ?? 0 }
    func isEligible(_ id: String) -> Bool { count(id) >= Self.minimumCount }

    var automaticPicks: [String] {
        Array(Self.catalogue.map(\.id).filter(isEligible)
            .sorted { count($0) > count($1) }
            .prefix(Self.maxPicks))
    }

    var picks: [String] { (customPicks ?? automaticPicks).filter(isEligible) }

    var showsRow: Bool { isEnabled && status == .ready && !picks.isEmpty }

    func toggle(_ id: String) {
        var current = picks
        if let index = current.firstIndex(of: id) { current.remove(at: index) }
        else if current.count < Self.maxPicks, isEligible(id) { current.append(id) }
        customPicks = current
    }

    func move(_ id: String, by offset: Int) {
        var current = picks
        guard let index = current.firstIndex(of: id) else { return }
        let target = min(max(index + offset, 0), current.count - 1)
        guard target != index else { return }
        current.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        customPicks = current
    }

    func resetToAutomatic() { customPicks = nil }

    // MARK: Loading

    func loadIfNeeded() async {
        let tmdb = TVTMDbStore.shared
        tmdb.reloadForCurrentProfile()
        guard tmdb.isConfigured else { status = .needsTMDB; return }
        if loadTask != nil { await loadTask?.value; return }
        if status == .ready { return }

        // Show the last saved results straight away, then refresh quietly
        // once a day so Home never waits on the library scan.
        if let cached = Self.readCache() {
            print("[BrandPrototype] cache hit, saved \(cached.savedAt)")
            results = cached.results
            status = .ready
            guard Date().timeIntervalSince(cached.savedAt) > Self.cacheLifetime else { return }
            loadTask = Task { await load(); loadTask = nil }
            return
        }
        // After a format change, keep showing the older saved results while
        // the new ones build, so the row never goes blank.
        if let stale = Self.readLegacyCache() {
            print("[BrandPrototype] showing older cache while rebuilding")
            results = stale
            status = .ready
            loadTask = Task { await load(); loadTask = nil }
            return
        }
        status = .loading
        let task = Task { await load(); loadTask = nil }
        loadTask = task
        await task.value
    }

    private static func readLegacyCache() -> [String: BrandResult]? {
        guard let url = cacheURL?.deletingLastPathComponent().appendingPathComponent(
            cacheURL!.lastPathComponent.replacingOccurrences(of: "brand-prototype-v4-", with: "brand-prototype-v3-")),
              let data = try? Data(contentsOf: url) else { return nil }
        // Older files lack newer fields; decode what's there.
        struct Legacy: Decodable {
            struct Result: Decodable { let logoURL: URL?; let movies: [BrowseItem]; let series: [BrowseItem]; let recentSeries: [BrowseItem]?; let all: [BrowseItem] }
            let results: [String: Result]
        }
        guard let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        return legacy.results.mapValues {
            BrandResult(logoURL: $0.logoURL, movies: $0.movies, series: $0.series,
                        recentSeries: $0.recentSeries ?? $0.series, recentMovies: $0.movies, all: $0.all)
        }
    }

    // MARK: Cache

    private struct CacheFile: Codable {
        let savedAt: Date
        let results: [String: BrandResult]
    }

    static let cacheLifetime: TimeInterval = 24 * 60 * 60

    private static var cacheURL: URL? {
        let scope = [ServerRegistry.shared.activeServerId ?? "server",
                     AuthService.shared.profileId ?? "profile"]
            .joined(separator: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("brand-prototype-v4-\(scope).json")
    }

    /// The library scan is the slow part, so it's cached on its own: a
    /// matching change then only re-runs the quick TMDb step.
    private struct IndexCacheFile: Codable {
        let savedAt: Date
        let movies: [String: BrowseItem]
        let series: [String: BrowseItem]
    }

    private static func indexCacheURL() -> URL? {
        cacheURL.map { $0.deletingLastPathComponent().appendingPathComponent(
            $0.lastPathComponent.replacingOccurrences(of: "brand-prototype-v4-", with: "brand-prototype-index-v1-")) }
    }

    private static func readIndexCache() -> IndexCacheFile? {
        guard let url = indexCacheURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IndexCacheFile.self, from: data)
    }

    private static func writeIndexCache(movies: [String: BrowseItem], series: [String: BrowseItem]) {
        guard let url = indexCacheURL(),
              let data = try? JSONEncoder().encode(IndexCacheFile(savedAt: Date(), movies: movies, series: series)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func readCache() -> CacheFile? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    private static func writeCache(_ results: [String: BrandResult]) {
        guard let url = cacheURL,
              let data = try? JSONEncoder().encode(CacheFile(savedAt: Date(), results: results)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() async {
        do {
            let movieIndex: [String: BrowseItem]
            let seriesIndex: [String: BrowseItem]
            if let cached = Self.readIndexCache(), Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime {
                print("[BrandPrototype] library index from cache")
                (movieIndex, seriesIndex) = (cached.movies, cached.series)
            } else {
                async let movies = libraryIndex(type: "movie")
                async let series = libraryIndex(type: "series")
                (movieIndex, seriesIndex) = try await (movies, series)
                Self.writeIndexCache(movies: movieIndex, series: seriesIndex)
            }
            print("[BrandPrototype] library index keys: \(movieIndex.count) movie, \(seriesIndex.count) series")
            var loaded: [String: BrandResult] = [:]
            await withTaskGroup(of: (String, BrandResult).self) { group in
                for brand in Self.catalogue {
                    group.addTask {
                        (brand.id, await Self.result(for: brand, movieIndex: movieIndex, seriesIndex: seriesIndex))
                    }
                }
                for await (id, result) in group { loaded[id] = result }
            }
            print("[BrandPrototype] matches: " + loaded.map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " "))
            results = loaded
            status = .ready
            Self.writeCache(loaded)
        } catch {
            lastError = String(describing: error)
            print("[BrandPrototype] load failed: \(error)")
            if results.isEmpty { status = .failed }
        }
    }

    private func libraryIndex(type: String) async throws -> [String: BrowseItem] {
        var index: [String: BrowseItem] = [:]
        var offset = 0
        let limit = 200
        for _ in 0..<100 {
            // Same shape as the app's own browse queries.
            let page: IndexPage = try await VividAPI.shared.http.get("/api/v1/catalog", query: [
                "source": "query", "type": type, "offset": String(offset), "limit": String(limit),
                "sort": "title", "order": "asc", "match": "all", "include_total": "false",
            ])
            for entry in page.items {
                if let id = entry.tmdbId, !id.isEmpty, index[id] == nil { index[id] = entry.item }
                // Servers that omit provider IDs from lists still match on title and year.
                if let year = entry.item.year {
                    let key = Self.titleKey(entry.item.title, year: year)
                    if index[key] == nil { index[key] = entry.item }
                }
            }
            offset += page.items.count
            if page.hasMore != true || page.items.isEmpty { break }
        }
        return index
    }

    static func titleKey(_ title: String, year: Int) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let simple = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return "t:\(simple)|\(year)"
    }

    private static func lookup(
        _ result: TVTMDbStore.BrandDiscoverPage.Result,
        in index: [String: BrowseItem]
    ) -> BrowseItem? {
        if let item = index[String(result.id)] { return item }
        guard let title = result.title ?? result.name,
              let date = result.release_date ?? result.first_air_date,
              let year = Int(date.prefix(4)) else { return nil }
        // Exact title and year only: allowing a year either side matched
        // unrelated titles that share a name in a large library.
        return index[titleKey(title, year: year)]
    }

    private static func result(
        for brand: BrandTileInfo,
        movieIndex: [String: BrowseItem],
        seriesIndex: [String: BrowseItem]
    ) async -> BrandResult {
        let tmdb = TVTMDbStore.shared
        let id = String(brand.tmdbId)
        let region = Locale.current.region?.identifier ?? "US"

        var movieQuery: [String: String]?
        var tvQuery: [String: String]
        switch brand.kind {
        case .network:
            tvQuery = ["with_networks": id]
            if let provider = brand.watchProviderId {
                movieQuery = ["with_watch_providers": String(provider), "watch_region": region,
                              "with_watch_monetization_types": "flatrate"]
            }
        case .studio:
            tvQuery = ["with_companies": id]
            movieQuery = ["with_companies": id]
        }

        async let logo = try? tmdb.brandLogoURL(kind: brand.kind == .network ? "network" : "company", id: brand.tmdbId)
        let movieMatches = movieQuery == nil ? [] : await matches(media: "movie", query: movieQuery!, index: movieIndex)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let yearAgo = Calendar.current.date(byAdding: .month, value: -12, to: today) ?? today
        var recentMovieMatches: [(item: BrowseItem, popularity: Double)] = []
        if var recentMovieQuery = movieQuery {
            recentMovieQuery["primary_release_date.gte"] = dayFormatter.string(from: yearAgo)
            recentMovieQuery["primary_release_date.lte"] = dayFormatter.string(from: today)
            recentMovieMatches = await matches(media: "movie", query: recentMovieQuery, index: movieIndex)
        }
        let seriesMatches = await matches(media: "tv", query: tvQuery, index: seriesIndex)
        var recentQuery = tvQuery
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        recentQuery["air_date.gte"] = formatter.string(from: Calendar.current.date(byAdding: .month, value: -12, to: now) ?? now)
        recentQuery["air_date.lte"] = formatter.string(from: now)
        let recentMatches = await matches(media: "tv", query: recentQuery, index: seriesIndex)
        var result = BrandResult(logoURL: await logo)
        result.movies = movieMatches.map(\.item)
        result.recentMovies = recentMovieMatches.map(\.item)
        result.series = seriesMatches.map(\.item)
        result.recentSeries = recentMatches.map(\.item)
        result.all = (movieMatches + seriesMatches).sorted { $0.popularity > $1.popularity }.map(\.item)
        return result
    }

    private static func matches(
        media: String,
        query: [String: String],
        index: [String: BrowseItem]
    ) async -> [(item: BrowseItem, popularity: Double)] {
        var found: [(item: BrowseItem, popularity: Double)] = []
        var seen = Set<String>()
        for page in 1...pagesPerMedia {
            guard let response = try? await TVTMDbStore.shared.brandDiscover(media: media, query: query, page: page)
            else { break }
            for result in response.results {
                if let item = lookup(result, in: index), seen.insert(item.contentId).inserted {
                    found.append((item, result.popularity ?? 0))
                }
            }
            if page >= (response.total_pages ?? 1) { break }
        }
        return found
    }
}

/// TMDB logo drawn as a white silhouette so every brand reads the same on the
/// dark tiles; falls back to the brand name.
struct BrandLogo: View {
    let url: URL?
    let name: String
    /// Logos printed on a solid block (Marvel) would turn into a plain white
    /// box, so their light lettering is cut out of the white block instead.
    var knocksOutText = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                if knocksOutText {
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
            } else {
                Text(name)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }
}

private struct BrandTileFace: View {
    let id: String
    let width: CGFloat
    @State private var store = TVBrandPrototypeStore.shared

    var body: some View {
        BrandLogo(url: store.results[id]?.logoURL, name: store.info(id)?.name ?? id,
                  knocksOutText: store.info(id)?.knocksOutLogoText ?? false)
            .frame(maxWidth: width * 0.62, maxHeight: width * 9 / 16 * 0.42)
            .frame(width: width, height: width * 9 / 16)
            .background(Color.white.opacity(0.06))
    }
}

// MARK: - Home row

struct TVHomeBrandRowPrototype: View {
    let enterRequest: Int
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    var onFocused: () -> Void = {}

    @State private var store = TVBrandPrototypeStore.shared
    @State private var tmdb = TVTMDbStore.shared
    @FocusState private var focusedTile: String?
    @State private var lastTile: String?
    @Environment(AppRouter.self) private var router

    private static let spacing: CGFloat = 30

    static func tileWidth(rowWidth: CGFloat) -> CGFloat {
        (rowWidth - spacing * CGFloat(TVBrandPrototypeStore.maxPicks - 1)) / CGFloat(TVBrandPrototypeStore.maxPicks)
    }

    var body: some View {
        Group {
            if store.showsRow {
                GeometryReader { proxy in
                    // Matches the hero card: 60pt inset each side.
                    let tileWidth = Self.tileWidth(rowWidth: proxy.size.width - 120)
                    HStack(spacing: Self.spacing) {
                        ForEach(store.picks, id: \.self) { id in
                            Button { router.navigate(to: .tvBrandPrototype(brandId: id)) } label: {
                                BrandTileFace(id: id, width: tileWidth)
                            }
                            .buttonStyle(.card)
                            .focused($focusedTile, equals: id)
                            .accessibilityLabel(store.info(id)?.name ?? id)
                        }
                    }
                    .padding(.horizontal, 60)
                    .focusSection()
                    .onMoveCommand { direction in
                        guard focusedTile != nil else { return }
                        if direction == .down { onMoveDown() }
                        if direction == .up { onMoveUp() }
                    }
                    .onChange(of: focusedTile) { _, tile in
                        if let tile { lastTile = tile; onFocused() }
                    }
                    .onChange(of: enterRequest) { _, _ in
                        focusedTile = lastTile.flatMap { store.picks.contains($0) ? $0 : nil } ?? store.picks.first
                    }
                }
                .frame(height: Self.tileWidth(rowWidth: 1920 - 120) * 9 / 16)
            }
        }
    }
}

// MARK: - Brand page

struct TVBrandPagePrototype: View {
    let brandId: String
    @State private var store = TVBrandPrototypeStore.shared
    @Environment(AppRouter.self) private var router

    private var info: BrandTileInfo? { store.info(brandId) }
    private var result: BrandResult { store.results[brandId] ?? BrandResult() }

    private var rows: [(title: String, items: [BrowseItem])] {
        // Shows with a new season or episodes in the past year, keeping the
        // series' main poster. The grid below still lists every show.
        // Networks show what's new; studios release only a few films a year,
        // so their pages keep the all-time most popular.
        let isStudio = info?.kind == .studio
        let series = ("Popular Series", isStudio ? result.series : result.recentSeries)
        let movies = ("Popular Movies", isStudio ? result.movies : result.recentMovies)
        let ordered = isStudio ? [movies, series] : [series, movies]
        return ordered
            .filter { $0.1.count >= TVBrandPrototypeStore.minimumCount }
            .map { ($0.0, Array($0.1.prefix(TVBrandPrototypeStore.rowLimit))) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 48) {
                header
                if store.status == .loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(rows, id: \.title) { row in
                    rail(title: row.title, items: row.items)
                }
                if !result.all.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("All in Your Library")
                            .font(.system(size: 36, weight: .semibold))
                            .padding(.leading, 80)
                        libraryGrid(Array(result.all.prefix(100)))
                        .padding(.horizontal, 80)
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .frame(width: 1920, alignment: .leading)
        .vividBackground()
        // Like the Home feed: own the 80pt inset instead of stacking it on
        // the system safe area.
        .ignoresSafeArea()
        .task { await store.loadIfNeeded() }
    }

    private var header: some View {
        BrandLogo(url: result.logoURL, name: info?.name ?? brandId, knocksOutText: info?.knocksOutLogoText ?? false)
            .frame(maxWidth: 480, maxHeight: 150)
            .frame(maxWidth: .infinity)
            .padding(.top, 110)
            .padding(.bottom, 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(info?.name ?? brandId)
    }

    /// Built eagerly (at most 100 posters) so a Down press from the last rail
    /// always finds the first grid row, even before it has scrolled on screen.
    private func libraryGrid(_ items: [BrowseItem]) -> some View {
        let columns = 7
        let spacing: CGFloat = 40
        // TVMediaCard scales by the Poster Size setting, so divide it back out
        // (as TVCatalogGrid does) to keep seven columns inside the screen.
        let cardWidth = (1920 - 160 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            / UICustomizationPreferences.shared.cardPresentation.posterSize.scale
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        return VStack(alignment: .leading, spacing: 60) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[index]) { item in
                        TVMediaCard(
                            title: item.title,
                            posterUrl: item.posterUrl ?? "",
                            posterThumbhash: item.posterThumbhash,
                            year: item.year,
                            userState: item.userState,
                            action: { router.navigate(to: .itemDetail(browseItem: item)) },
                            cardWidth: cardWidth,
                            contentId: item.contentId
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            }
        }
    }

    private func rail(title: String, items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 36, weight: .semibold))
                .padding(.leading, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(items) { item in
                        TVMediaCard(
                            title: item.title,
                            posterUrl: item.posterUrl ?? "",
                            posterThumbhash: item.posterThumbhash,
                            year: item.year,
                            userState: item.userState,
                            action: { router.navigate(to: .itemDetail(browseItem: item)) },
                            contentId: item.contentId
                        )
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }
}

// MARK: - Settings editor

struct TVStudiosNetworksSettingsView: View {
    @State private var store = TVBrandPrototypeStore.shared
    @State private var movingID: String?
    @FocusState private var focus: Target?
    @Environment(\.dismiss) private var dismiss

    private enum Target: Hashable { case done, slot(String), pick(String), reset }

    private let previewSpacing: CGFloat = 24
    private var previewTileWidth: CGFloat {
        (TVSettingsLayout.contentWidth - previewSpacing * CGFloat(TVBrandPrototypeStore.maxPicks - 1))
            / CGFloat(TVBrandPrototypeStore.maxPicks)
    }

    private var subtitle: String {
        switch store.status {
        case .needsTMDB: "Connect TMDb in Settings → Plugins → TMDb to use Studios & Networks."
        case .loading, .idle: "Matching your library with TMDb…"
        case .failed: "Couldn’t load from TMDb or your server. \(store.lastError ?? "")"
        case .ready: "Pinned under the hero on Home. \(store.picks.count) of \(TVBrandPrototypeStore.maxPicks) chosen."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TVSettingsPageHeader(title: "Studios & Networks", subtitle: subtitle) {
                    Button("Done") { dismiss() }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($focus, equals: .done)
                }

                if store.status == .ready {
                    TVSettingsGroup {
                        TVSettingsToggleRow(title: "Show on Home", isOn: store.isEnabled) {
                            store.isEnabled.toggle()
                        }
                    }

                    TVSettingsSectionHeader("PREVIEW")
                    preview
                    TVSettingsFooter(movingID == nil
                        ? "Press and hold a tile to rearrange. Changes save automatically."
                        : "Move left or right, then press centre to drop. Press Play/Pause to remove.")

                    pickSection(title: "NETWORKS", kind: .network)
                    pickSection(title: "STUDIOS", kind: .studio)
                    TVSettingsFooter("Counts are titles in your library matched with TMDb’s most popular for each. Brands need at least \(TVBrandPrototypeStore.minimumCount).")

                    Button("Reset to Automatic") { store.resetToAutomatic() }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($focus, equals: .reset)
                        .frame(maxWidth: .infinity)
                } else if store.status == .loading || store.status == .idle {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 72)
            .padding(.vertical, 36)
        }
        .tvSettingsPageSurface()
        .defaultFocus($focus, .done)
        .task { await store.loadIfNeeded() }
        .onExitCommand {
            if movingID != nil { movingID = nil } else { dismiss() }
        }
    }

    // MARK: Preview with arrange mode

    private var preview: some View {
        HStack(spacing: previewSpacing) {
            ForEach(0..<TVBrandPrototypeStore.maxPicks, id: \.self) { index in
                if index < store.picks.count {
                    slot(store.picks[index])
                } else {
                    emptySlot
                }
            }
        }
        .focusSection()
        .animation(.easeInOut(duration: 0.2), value: store.picks)
    }

    private func tileFace(_ id: String) -> some View {
        BrandTileFace(id: id, width: previewTileWidth)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func slot(_ id: String) -> some View {
        if let moving = movingID {
            if moving == id {
                Button { movingID = nil } label: {
                    tileFace(id)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white, lineWidth: 3))
                        .scaleEffect(1.08)
                        .modifier(ProfileArrangeWobble(active: true))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focused($focus, equals: .slot(id))
                .onAppear { focus = .slot(id) }
                .onMoveCommand { direction in
                    switch direction {
                    case .left: store.move(id, by: -1)
                    case .right: store.move(id, by: 1)
                    default: break
                    }
                }
                .onPlayPauseCommand {
                    store.toggle(id)
                    movingID = nil
                }
                .accessibilityLabel("Move \(store.info(id)?.name ?? id). Move left or right, then press centre to drop.")
            } else {
                tileFace(id)
                    .opacity(0.8)
                    .modifier(ProfileArrangeWobble(active: true))
            }
        } else {
            Button {} label: { tileFace(id) }
                .buttonStyle(.card)
                .focused($focus, equals: .slot(id))
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in movingID = id })
                .accessibilityLabel(store.info(id)?.name ?? id)
                .accessibilityAction(named: "Rearrange") { movingID = id }
        }
    }

    private var emptySlot: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .frame(width: previewTileWidth, height: previewTileWidth * 9 / 16)
            .overlay(Image(systemName: "plus").font(.system(size: 28, weight: .semibold)).opacity(0.45))
            .accessibilityLabel("Empty slot")
    }

    // MARK: Pick grid

    private func pickSection(title: String, kind: BrandTileInfo.Kind) -> some View {
        let items = TVBrandPrototypeStore.catalogue.filter { $0.kind == kind }
        let width = (TVSettingsLayout.contentWidth - 24 * 3) / 4
        return VStack(alignment: .leading, spacing: 16) {
            TVSettingsSectionHeader(title)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 24), count: 4),
                      alignment: .leading, spacing: 36) {
                ForEach(items) { info in
                    pickTile(info, width: width)
                }
            }
            .focusSection()
            .disabled(movingID != nil)
        }
    }

    private func pickTile(_ info: BrandTileInfo, width: CGFloat) -> some View {
        let picked = store.picks.contains(info.id)
        let count = store.count(info.id)
        let eligible = store.isEligible(info.id)
        let full = store.picks.count >= TVBrandPrototypeStore.maxPicks
        let unavailable = !eligible || (full && !picked)
        return VStack(alignment: .leading, spacing: 10) {
            Button { store.toggle(info.id) } label: {
                BrandTileFace(id: info.id, width: width)
                    .overlay(alignment: .topTrailing) {
                        if picked { WatchedCheckPill().padding(10) }
                    }
            }
            .buttonStyle(.card)
            .focused($focus, equals: .pick(info.id))
            .disabled(unavailable)
            .opacity(unavailable ? 0.4 : 1)
            .accessibilityLabel("\(info.name), \(count) titles\(picked ? ", chosen" : "")")

            Text(info.name).font(.system(size: 22, weight: .semibold))
            Text(eligible ? "\(count) titles" : count == 0 ? "None in your library" : "Only \(count) titles")
                .font(.system(size: 19))
                .opacity(0.6)
        }
    }
}
#endif
