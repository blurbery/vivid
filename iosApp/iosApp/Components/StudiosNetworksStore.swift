import SwiftUI

/// Loads, matches, caches and remembers the pinned Studios & Networks row.
///
/// Uses Vivid's TMDb relay. TMDb supplies each brand's logo and its
/// popularity-ordered titles; only titles in the library are kept, matched by
/// TMDb ID when the server lists one and otherwise by exact title and year.
/// Results and the library index are cached per server and profile, so Home
/// shows the row straight away and refreshes once a day in the background.
///
/// The brand catalogue is in `StudiosNetworksCatalogue.swift`, matching in
/// `StudiosNetworksMatching.swift` and the library, TMDb and disk reads in
/// `StudiosNetworksSources.swift`.
@MainActor
@Observable
final class StudiosNetworksStore {
    static let shared = StudiosNetworksStore()

    /// The most brands the row can hold, and how many automatic shows.
    static let maxPicks = 20
    /// The fewest a chosen set can have while the row shows on Home.
    static let minimumPicks = 6
    /// Tiles across the screen or settings preview at once. The row scrolls
    /// past these; it's layout only, not a pick limit.
    static let visibleTiles = 6
    /// Below this a tile or page row would look empty, so it's hidden.
    static let minimumCount = 6
    nonisolated static let rowLimit = 20
    /// TMDb discover pages read per list (20 titles each).
    nonisolated static let pagesPerList = 5
    /// Pages read of a network's films. Servers don't tag films with a
    /// streaming service, so its TMDb list is the only way they reach All in
    /// Your Library, and it's read twice as deep. The relay allows 10.
    nonisolated static let networkMoviePages = 10
    /// Bumped when matching changes, so saved results are matched again.
    nonisolated static let resultsRevision = 5
    /// Bumped when a brand's names change, so the saved library index is
    /// tagged again. Reading the library is the slow part, so it's separate.
    nonisolated static let indexRevision = 4
    /// Blocks in each of TMDb's weekly trending lists, 500 titles each: the
    /// whole list, as TMDb's only covers the world, not a brand, and a
    /// smaller brand's titles sit far down it. The relay answers a block in
    /// one request, so the list takes 20.
    nonisolated static let trendingBlocks = 20
    /// Trending blocks read at once. A block the relay hasn't cached reads 25
    /// pages from TMDb, so only a few go at a time.
    nonisolated static let concurrentTrendingBlocks = 4
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// How long results saved without a trending list wait before the
    /// trending lists are read again, and between later tries.
    static let trendingRetryDelay: TimeInterval = 60 * 60
    /// Silo signs artwork URLs for a few hours, far less than the daily
    /// refresh, so posters are read again this long before the first expires.
    nonisolated static let artworkRefreshLead: TimeInterval = 15 * 60
    /// Least time between poster refreshes, in case the server's URLs come
    /// back already near expiry or the device clock runs ahead.
    static let artworkRefreshCooldown: TimeInterval = 15 * 60
    /// TMDb requests in flight at once across every brand, so a refresh stays
    /// well inside the relay's limits.
    nonisolated static let concurrentRequests = 12
    static let firstLoadNotice = String(localized: "Setting up Studios & Networks for the first time. Vivid is reading your library and matching it with TMDb, which can take a few minutes on a large library. Keep Vivid open until it finishes. After this it loads instantly.")

    enum Status: Equatable { case idle, needsAccount, loading, ready, failed }

    private(set) var status: Status = .idle
    private(set) var results: [String: StudioNetworkResult] = [:]
    /// Live progress for the first-load notice.
    private(set) var progressText: String?
    private(set) var isEnabled = true
    /// nil means automatic: the top brands by library matches.
    private(set) var customPicks: [String]?
    /// While a settings editor is open, picks can drop below the required six
    /// so a brand can be swapped. Elsewhere they're topped up to six.
    private(set) var isEditing = false
    /// Changes whenever a movie lookup is saved, so open movie pages load
    /// their collection row again once the lookup exists.
    private(set) var movieLookupRevision = 0

    private var loadedScope: Scope?
    /// When the shown results were matched, kept when only their posters are
    /// refreshed so the daily TMDb refresh stays on schedule.
    private var resultsSavedAt: Date?
    /// The matching revision of the shown results, kept by a poster refresh
    /// so older results are still matched again.
    private var resultsSavedRevision: Int?
    /// Whether the shown results were matched without a trending list, kept
    /// by a poster refresh so the trending retry still happens.
    private var resultsMissTrending = false
    /// When the first signed poster URL in the results stops working. nil
    /// when none carries an expiry, as with Emby and Jellyfin.
    private var artworkExpiresAt: Date?
    private var artworkRefreshedAt: Date?
    /// The last time the trending lists alone were read again.
    private var trendingRetriedAt: Date?
    /// Titles read so far of each type, for the first-load progress.
    private var titlesRead: [String: Int] = [:]
    /// Brands whose TMDb lists have arrived in the current load.
    private var listsLoaded = 0
    private var libraryIsRead = false
    private var loadTask: Task<Void, Never>?
    private let defaults = SharedDefaults.shared
    @ObservationIgnored private var movieLookupCache: (scope: Scope, modified: Date, lookup: LibraryMovieLookup)?
    @ObservationIgnored private var searchIndexCache: (scope: Scope, modified: Date, index: LibrarySearchIndex)?
    @ObservationIgnored private var searchIndexTask: Task<Void, Never>?
    /// Set by Try Again, so the next load starts even after interrupted ones.
    @ObservationIgnored private var retryRequested = false

    /// A load or refresh is running for the current server and profile.
    var isLoading: Bool { loadTask != nil }

    // MARK: Picks

    func brand(_ id: String) -> StudioNetworkBrand? { Self.catalogue.first { $0.id == id } }
    func count(_ id: String) -> Int { results[id]?.count ?? 0 }
    func isEligible(_ id: String) -> Bool { count(id) >= Self.minimumCount }

    private var counts: [String: Int] { results.mapValues(\.count) }

    var automaticPicks: [String] { Self.automaticPicks(counts: counts) }

    var picks: [String] {
        let chosen = (customPicks ?? automaticPicks).filter(isEligible)
        return isEditing ? chosen : Self.filled(chosen, counts: counts)
    }

    /// Six, or every eligible brand when a small library has fewer.
    var requiredPicks: Int {
        min(Self.minimumPicks, Self.catalogue.filter { isEligible($0.id) }.count)
    }

    /// The editor can't be closed until this is false, unless the row is
    /// turned off.
    var needsMorePicks: Bool { isEnabled && picks.count < requiredPicks }

    var missingPicks: Int { max(0, requiredPicks - picks.count) }

    var showsRow: Bool { isEnabled && status == .ready && !picks.isEmpty }

    /// Starts editing with at least six, saving any top-up of older choices
    /// made before six were required.
    func beginEditing() {
        isEditing = true
        topUpForEditing()
    }

    func endEditing() {
        isEditing = false
    }

    /// Waits for match counts, so a partial set is never saved.
    private func topUpForEditing() {
        guard isEditing, status == .ready, let custom = customPicks else { return }
        let full = Self.filled(custom, counts: counts)
        if full != custom { setPicks(full) }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        savePreferences()
    }

    /// Removes a picked brand, or adds an eligible one while fewer than 20
    /// are picked.
    func toggle(_ id: String) {
        var current = picks
        if let index = current.firstIndex(of: id) {
            current.remove(at: index)
        } else if current.count < Self.maxPicks, isEligible(id) {
            current.append(id)
        }
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

    /// The Popular rows for a brand page (see `pageRows(for:result:)`).
    func pageRows(for id: String) -> [(title: String, items: [BrowseItem])] {
        Self.pageRows(for: brand(id), result: results[id] ?? StudioNetworkResult())
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

        /// Synced through the private vault, which lists this key.
        var preferencesKey: String { "tvos.homeStudiosNetworks.v1.\(server).\(profile)" }

        /// This device's `LoadRecord`. Not synced.
        var loadRecordKey: String { "studiosNetworks.loadRecord.v1.\(server).\(profile)" }

        /// `Caches/StudiosNetworks/<name>-v1-<token>.json`, creating the folder.
        func cacheURL(_ name: String) -> URL? {
            let token = Data("\(server)|\(profile)".utf8).base64EncodedString()
                .filter { $0.isLetter || $0.isNumber }
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
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
        if changed { switchScope(to: scope) }
        let stored = scope
            .flatMap { defaults.data(forKey: $0.preferencesKey) }
            .flatMap { try? JSONDecoder().decode(StoredPreferences.self, from: $0) }
            ?? StoredPreferences()
        isEnabled = stored.isEnabled
        customPicks = stored.picks.map { picks in
            var seen = Set<String>()
            return Array(picks.filter { seen.insert($0).inserted }.prefix(Self.maxPicks))
        }
    }

    private func switchScope(to scope: Scope?) {
        loadTask?.cancel()
        loadTask = nil
        loadedScope = scope
        searchIndexCache = nil
        results = [:]
        resultsSavedAt = nil
        resultsSavedRevision = nil
        resultsMissTrending = false
        artworkExpiresAt = nil
        artworkRefreshedAt = nil
        trendingRetriedAt = nil
        progressText = nil
        status = .idle
    }

    private func savePreferences() {
        guard let scope = loadedScope,
              let data = try? JSONEncoder().encode(StoredPreferences(isEnabled: isEnabled, picks: customPicks)),
              defaults.data(forKey: scope.preferencesKey) != data else { return }
        defaults.set(data, forKey: scope.preferencesKey)
    }

    // MARK: Loading

    /// `retrying` is for Try Again: it starts a load even after loads that
    /// were cut short (see `beginGuardedLoad`).
    func loadIfNeeded(retrying: Bool = false) async {
        if retrying { retryRequested = true }
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
            guard self.loadTask == nil, status == .ready, artworkNeedsRefresh || trendingNeedsRetry else { return }
        }
        guard let scope = loadedScope else { return }
        // Ready results only need fresh posters, for an app left open past
        // their expiry, or a trending list that didn't load.
        let isReady = status == .ready
        if isReady, !artworkNeedsRefresh, !trendingNeedsRetry { return }
        // A retry shows as loading straight away, so nothing waiting on it
        // mistakes the last attempt's failure for this one's.
        if status == .failed || status == .needsAccount { status = .loading }
        // One task covers the cache read and any load, so Home and Settings
        // asking at the same time share a single load.
        let task = Task { [weak self] in
            if isReady {
                if self?.artworkNeedsRefresh == true { await self?.refreshArtwork(scope) }
                if self?.trendingNeedsRetry == true { await self?.retryTrending(scope) }
            } else {
                await self?.prepare(scope)
            }
            if self?.loadedScope == scope { self?.loadTask = nil }
        }
        loadTask = task
        await task.value
    }

    /// Shows saved results straight away when there are any, refreshing them
    /// in the background once a day; otherwise runs the first load.
    private func prepare(_ scope: Scope) async {
        guard let cached = await Self.read(StudioNetworkResultsFile.self, scope.cacheURL("results")) else {
            guard loadedScope == scope else { return }
            status = .loading
            await load(scope)
            return
        }
        guard loadedScope == scope else { return }
        results = cached.results
        resultsSavedAt = cached.savedAt
        resultsSavedRevision = cached.revision
        resultsMissTrending = cached.missesTrending ?? false
        status = .ready
        topUpForEditing()
        let expiry = await Self.artworkExpiry(in: cached.results)
        guard loadedScope == scope else { return }
        artworkExpiresAt = expiry
        // Brands added since the results were saved have nothing to show
        // until they're matched, so a new brand refreshes them early, as do
        // results matched the way an older version did.
        let missesBrands = Self.catalogue.contains { cached.results[$0.id] == nil }
        let isOutdated = cached.revision != Self.resultsRevision
        let isOld = Date().timeIntervalSince(cached.savedAt) > Self.refreshInterval
        if missesBrands || isOutdated || isOld {
            await load(scope)
            return
        }
        Self.saveMissingMovieLookup(library: scope.cacheURL("library"), lookup: scope.cacheURL("movies"))
        if artworkNeedsRefresh { await refreshArtwork(scope) }
        if trendingNeedsRetry { await retryTrending(scope) }
    }

    private func load(_ scope: Scope) async {
        guard beginGuardedLoad(scope) else {
            guard loadedScope == scope else { return }
            progressText = nil
            status = results.isEmpty ? .failed : .ready
            return
        }
        var finished = false
        defer { endGuardedLoad(scope, finished: finished) }
        listsLoaded = 0
        libraryIsRead = false
        do {
            // TMDb's lists don't depend on the library, so they download while
            // the library is read and are matched once both are in. A brand
            // list's failure throws to the catch below, so a partial result
            // never replaces good saved results or resets the refresh timer.
            // A trending list that doesn't load doesn't throw: see
            // `trendingResults`.
            async let lists = Self.brandLists(Self.catalogue) { [weak self] in self?.noteListsLoaded(scope) }
            async let trending = Self.trendingLists()
            let index = try await libraryForMatching(scope)
            await Self.saveMovieLookup(index, to: scope.cacheURL("movies"))
            libraryIsRead = true
            if loadedScope == scope { showMatchingProgress() }
            // The saved results stay on screen while TMDb is matched, and stay
            // if it fails, so expired posters take the library's fresh links now.
            if loadedScope == scope, !results.isEmpty, artworkHasLapsed {
                await applyArtwork(from: index, scope)
            }
            let brandLists = try await lists
            let trendingLists = await trending
            // A trending list that didn't load keeps each brand's last one.
            let loaded = await Self.matched(brandLists, trending: trendingLists, previous: results, index: index)
            try Task.checkCancellation()
            guard loadedScope == scope else { return }
            let savedAt = Date()
            results = loaded
            resultsSavedAt = savedAt
            resultsSavedRevision = Self.resultsRevision
            resultsMissTrending = !trendingLists.isComplete
            // A retry is timed from these results, not an earlier retry.
            trendingRetriedAt = nil
            status = .ready
            topUpForEditing()
            progressText = nil
            await Self.write(StudioNetworkResultsFile(savedAt: savedAt, results: loaded, revision: Self.resultsRevision,
                                                      missesTrending: resultsMissTrending),
                             scope.cacheURL("results"))
            finished = true
            let expiry = await Self.artworkExpiry(in: loaded)
            if loadedScope == scope { artworkExpiresAt = expiry }
        } catch {
            guard loadedScope == scope else { return }
            progressText = nil
            // Results on screen stay if only the refresh failed. A retry
            // after Needs sign-in starts from loading even with results in
            // memory, so set ready again rather than leave it loading.
            status = results.isEmpty ? .failed : .ready
        }
    }

    /// The saved library index while it's from today, tagged with the current
    /// names and its posters still load; otherwise a fresh library read.
    private func libraryForMatching(_ scope: Scope) async throws -> StudioNetworkIndexFile {
        if let cached = await Self.read(StudioNetworkIndexFile.self, scope.cacheURL("library")),
           cached.revision == Self.indexRevision,
           Date().timeIntervalSince(cached.savedAt) < Self.refreshInterval,
           await Self.hasCurrentArtwork(cached) {
            return cached
        }
        // Counts as a poster refresh, so a page that waited on a read that
        // failed doesn't read the library again straight away. Not once the
        // account or profile has switched.
        if loadedScope == scope { artworkRefreshedAt = Date() }
        return try await readLibrary(scope, reportsProgress: true)
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

    /// Results saved without a trending list read it again an hour after
    /// they were matched, then at most once an hour, whenever Home or a brand
    /// page asks for the results.
    private var trendingNeedsRetry: Bool {
        guard resultsMissTrending, let since = trendingRetriedAt ?? resultsSavedAt else { return false }
        return Date().timeIntervalSince(since) > Self.trendingRetryDelay
    }

    /// Reads only the trending lists again and matches them with the saved
    /// library, keeping the rest of the results and when they were matched,
    /// so a failed trending read costs its 40 requests to retry, not a whole
    /// refresh. A retry that fails again changes nothing.
    private func retryTrending(_ scope: Scope) async {
        trendingRetriedAt = Date()
        let trending = await Self.trendingLists()
        guard trending.isComplete, loadedScope == scope,
              let index = await Self.read(StudioNetworkIndexFile.self, scope.cacheURL("library")) else { return }
        let updated = await Self.withTrending(trending, in: results, index: index)
        guard loadedScope == scope else { return }
        results = updated
        resultsMissTrending = false
        await Self.write(StudioNetworkResultsFile(savedAt: resultsSavedAt ?? Date(), results: updated,
                                                  revision: resultsSavedRevision, missesTrending: false),
                         scope.cacheURL("results"))
    }

    /// Swaps fresh poster URLs into the shown results by reading the library
    /// again, without matching with TMDb. Results are kept for a day, but
    /// Silo's signed artwork URLs stop working after a few hours and every
    /// poster would be left on its blurred placeholder. Status and progress
    /// stay as they are, so this runs unseen behind the current results.
    private func refreshArtwork(_ scope: Scope) async {
        artworkRefreshedAt = Date()
        guard beginGuardedLoad(scope) else { return }
        var finished = false
        defer { endGuardedLoad(scope, finished: finished) }
        do {
            let index = try await readLibrary(scope, reportsProgress: false)
            await Self.saveMovieLookup(index, to: scope.cacheURL("movies"))
            try Task.checkCancellation()
            guard loadedScope == scope else { return }
            await applyArtwork(from: index, scope)
            finished = true
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
                                                  revision: resultsSavedRevision, missesTrending: resultsMissTrending),
                         scope.cacheURL("results"))
    }

    /// Whether a saved index's posters will still load for a while. Runs off
    /// the main actor, as the index holds every library title.
    private nonisolated static func hasCurrentArtwork(_ index: StudioNetworkIndexFile) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let expiry = artworkExpiry(of: [index.movies.values, index.series.values].joined()) else { return true }
            return expiry.timeIntervalSinceNow >= artworkRefreshLead
        }.value
    }

    // MARK: Interrupted loads

    /// This device's loads for one server and profile, kept so a load that
    /// keeps getting the app closed partway through stops starting on its own.
    private struct LoadRecord: Codable {
        /// The app version that recorded it, so an update starts afresh.
        var app: String
        /// The process whose load is running, nil when none is.
        var running: String?
        /// Loads in a row cut short by the app closing while open.
        var interrupted = 0
    }

    /// Loads in a row cut short before they stop starting on their own.
    static let maxInterruptedLoads = 2
    private static let processID = UUID().uuidString
    private static var appVersion: String {
        "\(AppleDeviceIdentity.bundleAppVersion) (\(AppleDeviceIdentity.bundleAppBuild))"
    }

    /// Starts a load or poster refresh unless the last two were cut short by
    /// the app crashing or being closed while open, as tvOS does when a very
    /// large library uses too much memory. Every launch would otherwise start
    /// the same load from the beginning and close again. Try Again, or a new
    /// app version, starts one anyway.
    private func beginGuardedLoad(_ scope: Scope) -> Bool {
        var record = loadRecord(scope).flatMap { $0.app == Self.appVersion ? $0 : nil }
            ?? LoadRecord(app: Self.appVersion)
        // A load an earlier process left running never ended. It counts when
        // that process crashed or was closed while open, not when it was
        // closed in the background, which is routine.
        if let running = record.running, running != Self.processID {
            if AppHealthMonitor.previousSessionEndedUnexpectedly { record.interrupted += 1 }
            record.running = nil
        }
        if retryRequested {
            retryRequested = false
            record.interrupted = 0
        }
        let starts = record.interrupted < Self.maxInterruptedLoads
        if starts { record.running = Self.processID }
        saveLoadRecord(record, scope)
        return starts
    }

    /// A load that finished clears the interrupted ones before it. One that
    /// failed or was cancelled leaves them as they were.
    private func endGuardedLoad(_ scope: Scope, finished: Bool) {
        guard var record = loadRecord(scope), record.running == Self.processID else { return }
        record.running = nil
        if finished { record.interrupted = 0 }
        saveLoadRecord(record, scope)
    }

    private func loadRecord(_ scope: Scope) -> LoadRecord? {
        UserDefaults.standard.data(forKey: scope.loadRecordKey)
            .flatMap { try? JSONDecoder().decode(LoadRecord.self, from: $0) }
    }

    private func saveLoadRecord(_ record: LoadRecord, _ scope: Scope) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: scope.loadRecordKey)
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

    // MARK: Search index

    /// Every movie and series in the saved library index, for Search to match
    /// titles on the device. nil while it first loads and until the library
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
    /// background and kept until a newer one is saved. nil until the library
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
            return (try? JSONPieceWriter.write(to: url) { try lookup.writeFields(to: &$0) }) != nil
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
                  let index = try? JSONDecoder().decode(StudioNetworkIndexMovieCards.self, from: data)
            else { return }
            let movies = LibraryMovieLookup(cards: index.movies, savedAt: index.savedAt)
            guard (try? JSONPieceWriter.write(to: lookup) { try movies.writeFields(to: &$0) }) != nil else { return }
            await StudiosNetworksStore.movieLookupSaved()
        }
    }

    // MARK: Account removal

    /// Removes this device's cached results, library index and movie lookup
    /// for a profile, used when its account is removed.
    nonisolated static func removeCache(server: String, profile: String) {
        let scope = Scope(server: server, profile: profile)
        for name in ["results", "library", "movies"] {
            if let url = scope.cacheURL(name) { try? FileManager.default.removeItem(at: url) }
        }
        UserDefaults.standard.removeObject(forKey: scope.loadRecordKey)
    }
}
