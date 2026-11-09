import SwiftUI

/// Loads, matches, caches and remembers the pinned Studios & Networks row.
///
/// Uses Vivid's TMDb relay. TMDb supplies each brand's logo and its
/// popularity-ordered titles; only titles in the library are kept, matched by
/// TMDb ID when the server lists one and otherwise by exact title and year.
/// Results and the library index are cached per server and profile, so Home
/// shows the row straight away and refreshes once a day in the background.
/// The library index is a SQLite file (`StudioLibraryDatabase`), so memory
/// never grows with the size of the library.
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
    nonisolated static let resultsRevision = 6
    /// Bumped when a brand's names change, so the saved library index is
    /// tagged again. Reading the library is the slow part, so it's separate.
    nonisolated static let indexRevision = 6
    /// Blocks in each of TMDb's weekly trending lists, 500 titles each: the
    /// whole list, as TMDb's only covers the world, not a brand, and a
    /// smaller brand's titles sit far down it. The relay answers a block in
    /// one request, so the list takes 20.
    nonisolated static let trendingBlocks = 20
    /// Trending blocks read at once. A block the relay hasn't cached reads 25
    /// pages from TMDb, so only a few go at a time.
    nonisolated static let concurrentTrendingBlocks = 4
    nonisolated static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// A library read cut short carries on from where it stopped if it's
    /// started again within this long. Later, it starts again, as Silo's
    /// signed poster links from the first part would be close to expiring.
    nonisolated static let resumeWindow: TimeInterval = 60 * 60
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
    /// The saved library for the current server and profile, opened once.
    @ObservationIgnored private var library: (scope: Scope, database: StudioLibraryDatabase)?
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

        /// `Caches/StudiosNetworks/<name>-v<version>-<token>.<ext>`, creating
        /// the folder. Version 1 held the library as JSON.
        func cacheURL(_ name: String, version: Int = 2, extension ext: String = "json") -> URL? {
            let token = Data("\(server)|\(profile)".utf8).base64EncodedString()
                .filter { $0.isLetter || $0.isNumber }
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            let folder = caches.appendingPathComponent("StudiosNetworks", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("\(name)-v\(version)-\(token).\(ext)")
        }

        /// The library index in use. Only a complete read is moved here.
        var libraryURL: URL? { cacheURL("library", extension: "sqlite") }
        /// The library index a read is writing, kept if it's cut short.
        var buildingLibraryURL: URL? { cacheURL("library-building", extension: "sqlite") }

        /// Files older versions saved, which are no longer read.
        var legacyCacheURLs: [URL] {
            ["results", "library", "movies"].compactMap { cacheURL($0, version: 1) }
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
        library = nil
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
            guard self.loadTask == nil, status == .ready,
                  artworkNeedsRefresh || trendingNeedsRetry || libraryNeedsReload else { return }
        }
        guard let scope = loadedScope else { return }
        // Ready results only need fresh posters, for an app left open past
        // their expiry, a trending list that didn't load, or the library file
        // behind them read again.
        let isReady = status == .ready
        if isReady, !artworkNeedsRefresh, !trendingNeedsRetry, !libraryNeedsReload { return }
        // A retry shows as loading straight away, so nothing waiting on it
        // mistakes the last attempt's failure for this one's.
        if status == .failed || status == .needsAccount { status = .loading }
        // One task covers the cache read and any load, so Home and Settings
        // asking at the same time share a single load.
        let task = Task { [weak self] in
            if isReady, self?.libraryNeedsReload == true {
                await self?.load(scope)
            } else if isReady {
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
        if let folder = scope.cacheURL("results")?.deletingLastPathComponent() {
            Self.removeAbandonedPartials(in: folder)
        }
        Self.removeLegacyCaches(scope)
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
        let expiry = await Self.artworkExpiry(in: cached.results, library: openLibrary(scope))
        guard loadedScope == scope else { return }
        artworkExpiresAt = expiry
        // Brands added since the results were saved have nothing to show
        // until they're matched, so a new brand refreshes them early, as do
        // results matched the way an older version did.
        let missesBrands = Self.catalogue.contains { cached.results[$0.id] == nil }
        // Results whose library file has gone, as when the system clears
        // caches, have nothing behind their grids, Search or collection rows.
        let isOutdated = cached.revision != Self.resultsRevision || openLibrary(scope) == nil
        let isOld = Date().timeIntervalSince(cached.savedAt) > Self.refreshInterval
        if missesBrands || isOutdated || isOld {
            await load(scope)
            return
        }
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
            let library = try await libraryForMatching(scope)
            libraryIsRead = true
            if loadedScope == scope { showMatchingProgress() }
            // The saved results stay on screen while TMDb is matched, and stay
            // if it fails, so expired posters take the library's fresh links now.
            if loadedScope == scope, !results.isEmpty, artworkHasLapsed {
                await applyArtwork(from: library, scope)
            }
            let brandLists = try await lists
            let trendingLists = await trending
            // Matching holds the brands' matched titles, so it waits for the
            // player too.
            try await Self.waitWhilePlayerOpen()
            // A trending list that didn't load keeps each brand's last one.
            let loaded = await Self.matched(brandLists, trending: trendingLists, previous: results, library: library)
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
            let expiry = await Self.artworkExpiry(in: loaded, library: library)
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

    /// The saved library while it's from today, read with the current brand
    /// names and its posters still load; otherwise a fresh library read.
    private func libraryForMatching(_ scope: Scope) async throws -> StudioLibraryDatabase {
        if let saved = openLibrary(scope),
           saved.meta("revision") == String(Self.indexRevision),
           let savedAt = saved.meta("savedAt").flatMap(Double.init),
           Date().timeIntervalSince1970 - savedAt < Self.refreshInterval,
           !Self.artworkHasLapsed(expiresAt: await Self.posterExpiry(of: saved)) {
            return saved
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

    /// Results on screen whose library file has gone, as when the system
    /// clears caches or a reload at launch failed, have nothing behind their
    /// grids, Search or collection rows, so the library is read again, at
    /// most every 15 minutes.
    private var libraryNeedsReload: Bool {
        guard status == .ready, let scope = loadedScope, openLibrary(scope) == nil else { return false }
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
        guard trending.isComplete, loadedScope == scope, let library = openLibrary(scope) else { return }
        let updated = await Self.withTrending(trending, in: results, library: library)
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
            let library = try await readLibrary(scope, reportsProgress: false)
            try Task.checkCancellation()
            guard loadedScope == scope else { return }
            await applyArtwork(from: library, scope)
            finished = true
        } catch {
            // Keep the current results. The next visit after the cooldown
            // tries again, and the daily refresh reads the library anyway.
        }
    }

    /// Swaps a library read's poster links into the shown results and saves
    /// them, keeping when they were matched.
    private func applyArtwork(from library: StudioLibraryDatabase, _ scope: Scope) async {
        let current = results
        let refreshed = await Task.detached(priority: .utility) { () -> [String: StudioNetworkResult] in
            let shown = Set(current.values.flatMap { $0.items.map(\.contentId) })
            var fresh: [String: BrowseItem] = [:]
            for item in library.items(contentIds: Array(shown)) { fresh[item.contentId] = item }
            var tagged: [String: [String]] = [:]
            for id in current.keys { tagged[id] = library.taggedIDs(brand: id) }
            return Self.replacingArtwork(in: current, with: fresh, tagged: tagged)
        }.value
        let expiry = await Self.artworkExpiry(in: refreshed, library: library)
        guard loadedScope == scope else { return }
        results = refreshed
        artworkExpiresAt = expiry
        await Self.write(StudioNetworkResultsFile(savedAt: resultsSavedAt ?? Date(), results: refreshed,
                                                  revision: resultsSavedRevision, missesTrending: resultsMissTrending),
                         scope.cacheURL("results"))
    }

    /// The earliest signed poster link among the results and the saved
    /// library behind their grids.
    private nonisolated static func artworkExpiry(
        in results: [String: StudioNetworkResult], library: StudioLibraryDatabase?
    ) async -> Date? {
        let shown = await artworkExpiry(in: results)
        guard let library else { return shown }
        let saved = await posterExpiry(of: library)
        return [shown, saved].compactMap { $0 }.min()
    }

    /// Reads every title, so it runs off the main actor.
    private nonisolated static func posterExpiry(of library: StudioLibraryDatabase) async -> Date? {
        await Task.detached(priority: .utility) { library.earliestPosterExpiry() }.value
    }

    // MARK: Interrupted loads

    /// This device's loads for one server and profile, kept so a load that
    /// keeps getting the app closed partway through stops starting on its own.
    struct LoadRecord: Codable, Equatable {
        /// The app version that recorded it, so an update starts afresh.
        var app: String
        /// The process ID whose load is running, nil when none is.
        var running: String?
        /// Loads in a row cut short by the app closing while open.
        var interrupted = 0
        /// When the last of them was cut short.
        var interruptedAt: Date?
    }

    /// Loads in a row cut short before they stop starting on their own.
    nonisolated static let maxInterruptedLoads = 2
    private static let processID = String(getpid())
    private static var appVersion: String {
        "\(AppleDeviceIdentity.bundleAppVersion) (\(AppleDeviceIdentity.bundleAppBuild))"
    }

    /// Starts a load or poster refresh unless the last two were cut short by
    /// the app crashing or being closed while open, as tvOS does when a very
    /// large library uses too much memory. Every launch would otherwise start
    /// the same load from the beginning and close again.
    private func beginGuardedLoad(_ scope: Scope) -> Bool {
        let (starts, record) = Self.guardedStart(
            loadRecord(scope), app: Self.appVersion, process: Self.processID,
            previousExit: AppHealthMonitor.previousExit, retrying: retryRequested, now: Date()
        )
        retryRequested = false
        saveLoadRecord(record, scope)
        return starts
    }

    /// Whether a load starts, and the record to save. A load an earlier
    /// process left running counts as cut short only when that exact process
    /// crashed or was closed while open, not when it was closed in the
    /// background, which is routine. Try Again, a new app version, or a day
    /// passing since the last one was cut short starts one anyway; a day on,
    /// one more cut short stops them again, so at worst the app closes once a
    /// day rather than on every launch.
    nonisolated static func guardedStart(
        _ saved: LoadRecord?, app: String, process: String,
        previousExit: AppHealthMonitor.PreviousExit?, retrying: Bool, now: Date
    ) -> (starts: Bool, record: LoadRecord) {
        var record = saved.flatMap { $0.app == app ? $0 : nil } ?? LoadRecord(app: app)
        if let running = record.running, running != process {
            // The library read waits while the player is open, so a close
            // during playback isn't the load's.
            if let exit = previousExit, !exit.playerOpen, let pid = exit.pid, String(pid) == running {
                record.interrupted += 1
                record.interruptedAt = now
            }
            record.running = nil
        }
        if retrying { record.interrupted = 0 }
        if record.interrupted >= maxInterruptedLoads, let since = record.interruptedAt,
           now.timeIntervalSince(since) > refreshInterval {
            record.interrupted = maxInterruptedLoads - 1
        }
        let starts = record.interrupted < maxInterruptedLoads
        if starts { record.running = process }
        return (starts, record)
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

    /// The saved library for `scope`, opened once and kept until a newer read
    /// replaces it. nil until the library has been read.
    private func openLibrary(_ scope: Scope) -> StudioLibraryDatabase? {
        if let library, library.scope == scope { return library.database }
        // A file an older version wrote has another layout, so it isn't
        // read; the next load replaces it.
        guard let url = scope.libraryURL, FileManager.default.fileExists(atPath: url.path),
              let database = try? StudioLibraryDatabase(url: url, writable: false),
              database.meta("revision") == String(Self.indexRevision) else { return nil }
        library = (scope, database)
        return database
    }

    /// Reads every library title from the server into a new library file,
    /// carrying on from a read cut short within the last hour, and puts it in
    /// place of the saved one once it's complete.
    private func readLibrary(_ scope: Scope, reportsProgress: Bool) async throws -> StudioLibraryDatabase {
        guard let buildingURL = scope.buildingLibraryURL, let libraryURL = scope.libraryURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let building = try await Self.openBuilding(buildingURL)
        if reportsProgress { titlesRead = [:] }
        let report: @MainActor (String, Int) -> Void = { [weak self] type, count in
            guard reportsProgress, let self, self.loadedScope == scope else { return }
            self.titlesRead[type] = count
            let titles = self.titlesRead.values.reduce(0, +).formatted()
            self.progressText = String(localized: "Reading your library… \(titles) titles", comment: "Studios & Networks first-load progress. The count is already formatted, e.g. 1,234")
        }
        async let movies: Void = Self.readLibrary(.movie, into: building, report: report)
        async let series: Void = Self.readLibrary(.series, into: building, report: report)
        _ = try await (movies, series)
        try await Task.detached(priority: .utility) {
            try building.setMeta("savedAt", value: String(Date().timeIntervalSince1970))
            building.close()
            try Self.replaceDatabase(at: libraryURL, with: buildingURL)
        }.value
        // Readers still holding the replaced file finish with it; the next
        // lookup opens the new one.
        if library?.scope == scope { library = nil }
        movieLookupRevision &+= 1
        guard let saved = openLibrary(scope) else { throw CocoaError(.fileReadUnknown) }
        return saved
    }

    /// The library file a read writes to: the one a read cut short left, if
    /// it's recent and written the same way, or a new one.
    private nonisolated static func openBuilding(_ url: URL) async throws -> StudioLibraryDatabase {
        try await Task.detached(priority: .utility) {
            if let existing = try? StudioLibraryDatabase(url: url, writable: true) {
                if existing.meta("revision") == String(indexRevision),
                   let started = existing.meta("startedAt").flatMap(Double.init),
                   Date().timeIntervalSince1970 - started < resumeWindow {
                    return existing
                }
                existing.close()
            }
            removeDatabase(at: url)
            let fresh = try StudioLibraryDatabase(url: url, writable: true)
            try fresh.setMeta("revision", value: String(indexRevision))
            try fresh.setMeta("startedAt", value: String(Date().timeIntervalSince1970))
            return fresh
        }.value
    }

    /// Moves a complete library file over the saved one in a single rename.
    private nonisolated static func replaceDatabase(at url: URL, with built: URL) throws {
        try? FileManager.default.removeItem(at: journal(of: url))
        try? FileManager.default.removeItem(at: journal(of: built))
        guard rename(built.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private nonisolated static func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: journal(of: url))
    }

    private nonisolated static func journal(of url: URL) -> URL {
        URL(fileURLWithPath: url.path + "-journal")
    }

    private nonisolated static func removeLegacyCaches(_ scope: Scope) {
        for url in scope.legacyCacheURLs { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Library titles

    /// The saved library's titles with these content IDs, in the order
    /// given, for Search's matches and a brand page's grid.
    func libraryItems(_ contentIds: [String]) async -> [BrowseItem] {
        guard !contentIds.isEmpty, let scope = Scope.current, let library = openLibrary(scope) else { return [] }
        return await Task.detached(priority: .userInitiated) { library.items(contentIds: contentIds) }.value
    }

    /// A brand's All in Your Library titles, read when its page opens.
    func libraryTitles(for brandId: String) async -> [BrowseItem] {
        await libraryItems(results[brandId]?.allIDs ?? [])
    }

    /// Changes when a brand's grid needs reading again: its titles changed,
    /// or a new library read brought fresh poster links.
    func libraryGridKey(for brandId: String) -> StudioLibraryGridKey {
        StudioLibraryGridKey(ids: results[brandId]?.allIDs ?? [], revision: movieLookupRevision)
    }

    // MARK: Search index

    /// Every movie and series in the saved library, for Search to match
    /// titles on the device. nil while it first loads and until the library
    /// has been read, so a search never waits for it: the first call starts
    /// the load in the background. It follows the saved library, which every
    /// library read replaces, and the previous one serves while a newer loads.
    /// It holds titles only; Search reads its matches' details afterwards.
    func searchIndex() -> LibrarySearchIndex? {
        guard let scope = Scope.current, let url = scope.libraryURL,
              let modified = Self.modificationDate(url) else { return nil }
        let cached = searchIndexCache.flatMap { $0.scope == scope ? $0 : nil }
        if let cached, cached.modified == modified { return cached.index }
        if searchIndexTask == nil, let library = openLibrary(scope) {
            searchIndexTask = Task { [weak self] in
                let index = await Task.detached(priority: .userInitiated) { () -> LibrarySearchIndex? in
                    let titles = library.searchTitles()
                    return titles.isEmpty ? nil : LibrarySearchIndex(titles: titles)
                }.value
                guard let self else { return }
                self.searchIndexTask = nil
                if let index, Scope.current == scope { self.searchIndexCache = (scope, modified, index) }
            }
        }
        return cached?.index
    }

    // MARK: Movie lookup

    /// Finds library movies for a movie page's collection row in the saved
    /// library. nil until the library has been read.
    func movieLookup() async -> LibraryMovieLookup? {
        guard let scope = Scope.current, let library = openLibrary(scope) else { return nil }
        return LibraryMovieLookup(library: library)
    }

    /// Removes files a write left unfinished when the app closed partway
    /// through (see `JSONPieceWriter`). A recent one may still be in use.
    nonisolated static func removeAbandonedPartials(in folder: URL, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
            let url = folder.appendingPathComponent(name)
            guard let modified = modificationDate(url), now.timeIntervalSince(modified) > 10 * 60 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Account removal

    /// Removes this device's cached results, library index and movie lookup
    /// for a profile, used when its account is removed.
    nonisolated static func removeCache(server: String, profile: String) {
        let scope = Scope(server: server, profile: profile)
        if let url = scope.cacheURL("results") { try? FileManager.default.removeItem(at: url) }
        for url in [scope.libraryURL, scope.buildingLibraryURL].compactMap({ $0 }) { removeDatabase(at: url) }
        removeLegacyCaches(scope)
        UserDefaults.standard.removeObject(forKey: scope.loadRecordKey)
    }
}
