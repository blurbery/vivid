import Foundation
import Observation

/// One collection the Collections row can show, with the library it was read
/// from, so its page opens the same way as from For You.
struct HomeCollection: Codable, Identifiable, Hashable {
    let collection: LibraryCollection
    let libraryID: Int

    var id: String { collection.id }

    /// The library ID given to the profile's own Silo collections, which
    /// belong to no library. Silo's library IDs start at 1.
    static let personalLibraryID = 0
}

/// Loads, caches and remembers the Collections row pinned to the bottom of
/// Home.
///
/// The list is the server's own collections (For You's Server source) plus,
/// on Silo, the profile's own (its Mine source). Emby and Jellyfin answer in
/// one request; Silo is read from each movie, series and mixed library and
/// the profile's collections list. Other profiles' shared collections are
/// left out. The list is cached per server and profile, so Home shows the row
/// straight away and refreshes it in the background.
@MainActor
@Observable
final class HomeCollectionsStore {
    static let shared = HomeCollectionsStore()

    /// The most collections the row can hold, and how many automatic shows.
    static let maxPicks = 20
    /// Collections in each picker carousel.
    static let carouselSize = 20
    /// How long a loaded list is used before Home reads it again.
    static let refreshInterval: TimeInterval = 30 * 60
    /// How long a failed read waits before another visit tries again. Emby
    /// takes many seconds to count each collection's titles, so a server that
    /// can't finish isn't asked again on every visit.
    nonisolated static let retryDelay: TimeInterval = 5 * 60
    /// Silo signs poster URLs for a few hours, so the list is read again this
    /// long before the first one expires.
    nonisolated static let artworkRefreshLead: TimeInterval = 15 * 60

    enum Status: Equatable { case idle, needsAccount, loading, ready, failed }

    private(set) var status: Status = .idle
    /// Every collection that can be chosen: the profile's own first, then the
    /// server's, each A to Z.
    private(set) var collections: [HomeCollection] = []
    private(set) var isEnabled = true
    /// nil means automatic: the server collections with the most titles.
    private(set) var customPicks: [String]?
    /// The chosen or automatic picks still on the server, up to 20. Worked
    /// out when the list or the choices change, so the settings page doesn't
    /// redo it for every poster it draws.
    private(set) var picks: [String] = []
    /// The A to Z list in carousels of 20.
    private(set) var carousels: [[HomeCollection]] = []

    @ObservationIgnored private var collectionsByID: [String: HomeCollection] = [:]
    /// Each collection's title count. Emby leaves counts out of its quick
    /// collection lists, so For You takes them from here (`withKnownCount`).
    private var itemCounts: [String: Int] = [:]

    private var loadedScope: Scope?
    private var loadedAt: Date?
    /// When the first signed poster URL in the list stops working. nil when
    /// none carries an expiry, as with Emby and Jellyfin.
    private var artworkExpiresAt: Date?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var hydratedScope: Scope?
    /// False while some Silo libraries or the profile's own collections
    /// failed to load, so the list may lack collections still on the server.
    @ObservationIgnored private var listIsComplete = true
    /// When the last read failed, for `retryDelay`.
    @ObservationIgnored private var failedAt: Date?
    /// When a turned-down poster last made the list read again, for `retryDelay`.
    @ObservationIgnored private var rejectedPosterReloadAt: Date?
    @ObservationIgnored private var rejectedPosterObserver: NSObjectProtocol?
    private let defaults = SharedDefaults.shared

    private init() {
        rejectedPosterObserver = NotificationCenter.default.addObserver(
            forName: .vividArtworkLinkRejected, object: nil, queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor in self?.posterLinkRejected(url) }
        }
    }

    // MARK: Row

    func collection(_ id: String) -> HomeCollection? { collectionsByID[id] }

    /// `collection` with the title count this list has for it, when it came
    /// without one and the list is for the current server and profile.
    func withKnownCount(_ collection: LibraryCollection) -> LibraryCollection {
        guard collection.itemCount == nil, isCurrent, let count = itemCounts[collection.id] else {
            return collection
        }
        return collection.withItemCount(count)
    }

    /// The row's collections in order, for the current server and profile only.
    var rowCollections: [HomeCollection] {
        isCurrent ? picks.compactMap(collection) : []
    }

    var showsRow: Bool { isEnabled && !rowCollections.isEmpty }

    func isPicked(_ id: String) -> Bool { picks.contains(id) }

    /// Whether the loaded list belongs to the signed-in server and profile.
    private var isCurrent: Bool {
        loadedScope != nil && loadedScope == Scope.current
    }

    // MARK: Choosing

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        savePreferences()
    }

    /// Removes a chosen collection, or adds one while fewer than 20 are chosen.
    func toggle(_ id: String) {
        var edited = picks
        if let index = edited.firstIndex(of: id) {
            edited.remove(at: index)
        } else if edited.count < Self.maxPicks, collection(id) != nil {
            edited.append(id)
        } else {
            return
        }
        choose(edited)
    }

    /// Swaps a chosen collection with its neighbour `offset` places along.
    func move(_ id: String, by offset: Int) {
        var edited = picks
        guard let index = edited.firstIndex(of: id), edited.indices.contains(index + offset) else { return }
        edited.swapAt(index, index + offset)
        choose(edited)
    }

    func place(_ id: String, at index: Int) {
        var edited = picks
        guard let from = edited.firstIndex(of: id) else { return }
        edited.remove(at: from)
        edited.insert(id, at: min(max(0, index), edited.count))
        choose(edited)
    }

    func resetToAutomatic() {
        setCustomPicks(nil)
        savePreferences()
    }

    private func choose(_ edited: [String]) {
        setCustomPicks(Self.keepingUnloadedPicks(
            edited, previous: customPicks, loaded: Set(collectionsByID.keys), listIsComplete: listIsComplete
        ))
        savePreferences()
    }

    private func setCollections(_ entries: [HomeCollection]) {
        collections = entries
        collectionsByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        itemCounts = collectionsByID.compactMapValues(\.collection.itemCount)
        carousels = Self.carousels(entries)
        updatePicks()
    }

    private func setCustomPicks(_ ids: [String]?) {
        customPicks = ids
        updatePicks()
    }

    private func updatePicks() {
        let updated = Self.picks(custom: customPicks, available: collections.map(\.collection))
        if updated != picks { picks = updated }
    }

    // MARK: Ordering

    /// The server collections with the most titles, ties A to Z. Silo's smart
    /// collections have no count, so they come last. The profile's own
    /// collections show only when chosen.
    static func automaticPicks(_ collections: [LibraryCollection]) -> [String] {
        let ranked = collections
            .filter { $0.kind != .userCollections }
            .sorted { lhs, rhs in
                switch (lhs.itemCount, rhs.itemCount) {
                case let (left?, right?) where left != right: left > right
                case (.some, nil): true
                case (nil, .some): false
                default: precedes(lhs, rhs)
                }
            }
        return ranked.prefix(maxPicks).map(\.id)
    }

    /// The chosen or automatic picks still on the server, once each, up to 20.
    /// An empty choice stays empty rather than falling back to automatic.
    static func picks(custom: [String]?, available: [LibraryCollection]) -> [String] {
        let availableIDs = Set(available.map(\.id))
        let chosen = custom ?? automaticPicks(available)
        return Array(uniqued(chosen.filter(availableIDs.contains)).prefix(maxPicks))
    }

    static func carousels(_ collections: [HomeCollection]) -> [[HomeCollection]] {
        stride(from: 0, to: collections.count, by: carouselSize).map { start in
            Array(collections[start..<min(start + carouselSize, collections.count)])
        }
    }

    /// An edit while some libraries failed to load keeps the earlier choices
    /// from those libraries, after the edited ones, instead of losing them.
    /// With a complete list, choices that aren't in it are gone from the
    /// server and are dropped.
    static func keepingUnloadedPicks(_ edited: [String], previous: [String]?,
                                     loaded: Set<String>, listIsComplete: Bool) -> [String] {
        guard !listIsComplete, let previous else { return edited }
        return edited + previous.filter { !loaded.contains($0) && !edited.contains($0) }
    }

    /// A partial Silo list keeps the earlier entries from the libraries that
    /// failed this time, so they don't empty. The profile's own collections
    /// count as one more library. Libraries that answered show exactly what
    /// they returned.
    static func merged(_ fresh: [HomeCollection], previous: [HomeCollection],
                       failedLibraries: Set<Int>) -> [HomeCollection] {
        guard !failedLibraries.isEmpty else { return fresh }
        let freshIDs = Set(fresh.map(\.id))
        let kept = previous.filter { failedLibraries.contains($0.libraryID) && !freshIDs.contains($0.id) }
        return sorted(fresh + kept)
    }

    /// The profile's own collections first, so they are easy to find in the
    /// settings carousels, then the server's, each A to Z.
    static func sorted(_ entries: [HomeCollection]) -> [HomeCollection] {
        entries.sorted { lhs, rhs in
            let lhsIsMine = lhs.collection.kind == .userCollections
            let rhsIsMine = rhs.collection.kind == .userCollections
            return lhsIsMine == rhsIsMine ? precedes(lhs.collection, rhs.collection) : lhsIsMine
        }
    }

    /// A to Z skipping a leading article, then by ID so the order is stable.
    private static func precedes(_ lhs: LibraryCollection, _ rhs: LibraryCollection) -> Bool {
        switch TitleSortOrder.compare(lhs.name, rhs.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.id < rhs.id
        }
    }

    private static func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    nonisolated static func retryIsDue(after failure: Date?, now: Date = Date()) -> Bool {
        guard let failure else { return true }
        return now.timeIntervalSince(failure) >= retryDelay
    }

    nonisolated static func artworkExpiry(of entries: [HomeCollection]) -> Date? {
        entries.compactMap { $0.collection.posterUrl.flatMap(SiloAPICompatibility.artworkExpiry) }.min()
    }

    // MARK: Scope and preferences

    struct Scope: Equatable {
        let server: String
        let profile: String

        static var current: Scope? {
            guard let server = ServerRegistry.shared.activeServerId,
                  let profile = AuthService.shared.profileId, !profile.isEmpty else { return nil }
            return Scope(server: server, profile: profile)
        }

        /// Synced through the private vault, which lists this key.
        var preferencesKey: String { "tvos.homeCollections.v1.\(server).\(profile)" }

        var cacheURL: URL? {
            let token = Data("\(server)|\(profile)".utf8).base64EncodedString()
                .filter { $0.isLetter || $0.isNumber }
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            let folder = caches.appendingPathComponent("HomeCollections", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("collections-v1-\(token).json")
        }
    }

    private struct StoredPreferences: Codable, Equatable {
        var isEnabled = true
        var picks: [String]?
    }

    /// Picks up a profile or server switch, or preferences synced from
    /// another device. Another profile's collections are never shown.
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
        // Saved choices can hold a few beyond 20 while a library is failing to
        // load (see `keepingUnloadedPicks`); the row still shows 20 at most.
        setCustomPicks(stored.picks.map { Array(Self.uniqued($0).prefix(Self.maxPicks * 2)) })
    }

    private func switchScope(to scope: Scope?) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        loadedScope = scope
        hydratedScope = nil
        listIsComplete = true
        failedAt = nil
        rejectedPosterReloadAt = nil
        setCollections([])
        loadedAt = nil
        artworkExpiresAt = nil
        status = .idle
    }

    private func savePreferences() {
        guard let scope = loadedScope else { return }
        let encoder = JSONEncoder()
        // Unchanged choices encode to the same bytes, so syncing doesn't see a
        // new value on every save.
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(StoredPreferences(isEnabled: isEnabled, picks: customPicks)),
              defaults.data(forKey: scope.preferencesKey) != data else { return }
        defaults.set(data, forKey: scope.preferencesKey)
    }

    // MARK: Loading

    /// Shows the cached list, then reads the server again when the list is
    /// older than the refresh interval, its posters are about to expire, or
    /// `force` is set. A failed read waits `retryDelay` unless forced, so
    /// pulling to refresh and the settings page still read at once.
    func loadIfNeeded(force: Bool = false) async {
        refresh()
        guard let scope = loadedScope else {
            status = .needsAccount
            return
        }
        if hydratedScope != scope {
            hydratedScope = scope
            await hydrate(scope)
        }
        guard loadedScope == scope else { return }
        if !force, listIsFresh || !Self.retryIsDue(after: failedAt) { return }
        if let loadTask {
            await loadTask.value
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        if collections.isEmpty { status = .loading }
        let task = Task { await self.load(scope, generation: generation) }
        loadTask = task
        await task.value
    }

    /// A poster from this list that the server turned down usually means its
    /// signed link has expired or the poster was replaced, while the list
    /// still reads as fresh: say a read at launch failed and the saved list
    /// stayed up. The list is read again, as pull to refresh does, so the
    /// posters get new links. Every poster on screen can fail at once, so this
    /// reads at most once per `retryDelay`.
    private func posterLinkRejected(_ url: URL) {
        guard isCurrent, Self.retryIsDue(after: rejectedPosterReloadAt) else { return }
        let serverURL = MediaServerProvider.active == .silo
            ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
        guard Self.lists(poster: url, in: collections, serverURL: serverURL) else { return }
        rejectedPosterReloadAt = Date()
        Task { await loadIfNeeded(force: true) }
    }

    /// Whether `url` is one of the entries' posters, resolved the way artwork
    /// views resolve it.
    nonisolated static func lists(poster url: URL, in entries: [HomeCollection], serverURL: URL?) -> Bool {
        entries.contains { entry in
            guard let raw = entry.collection.posterUrl, !raw.isEmpty else { return false }
            return SiloAPICompatibility.artworkURL(raw, relativeTo: serverURL) == url
        }
    }

    private var listIsFresh: Bool {
        guard let loadedAt, Date().timeIntervalSince(loadedAt) < Self.refreshInterval else { return false }
        guard let artworkExpiresAt else { return true }
        return artworkExpiresAt.timeIntervalSinceNow > Self.artworkRefreshLead
    }

    private func hydrate(_ scope: Scope) async {
        guard let cached = await Self.readCache(server: scope.server, profile: scope.profile),
              loadedScope == scope, collections.isEmpty else { return }
        // Sorted again, so a list saved under an older order reads right.
        setCollections(Self.sorted(cached.collections))
        loadedAt = cached.savedAt
        artworkExpiresAt = Self.artworkExpiry(of: cached.collections)
        status = .ready
    }

    private func load(_ scope: Scope, generation: Int) async {
        defer { if generation == loadGeneration { loadTask = nil } }
        let isStillWanted = { generation == self.loadGeneration && self.loadedScope == scope && !Task.isCancelled }
        do {
            let read = try await Self.readServer(profileID: scope.profile)
            guard isStillWanted() else { return }
            failedAt = nil
            let entries = Self.merged(read.entries, previous: collections, failedLibraries: read.failedLibraries)
            setCollections(entries)
            listIsComplete = read.failedLibraries.isEmpty
            artworkExpiresAt = Self.artworkExpiry(of: entries)
            status = .ready
            // A partial list isn't cached or treated as fresh, so the next
            // Home visit reads the server again.
            guard listIsComplete else {
                loadedAt = nil
                return
            }
            loadedAt = Date()
            Self.saveCache(read.entries, server: scope.server, profile: scope.profile)
        } catch {
            guard isStillWanted() else { return }
            failedAt = Date()
            // A list already on screen stays up; with nothing to show, report
            // the failure rather than an empty state that reads as none.
            status = collections.isEmpty ? .failed : .ready
        }
    }

    // MARK: Reading the server

    private typealias ServerRead = (entries: [HomeCollection], failedLibraries: Set<Int>)

    private static func readServer(profileID: String) async throws -> ServerRead {
        if MediaServerProvider.active.usesNativeUser {
            return (try await nativeUserCollections(), [])
        }
        return try await siloCollections(profileID: profileID)
    }

    /// Emby and Jellyfin: every box set in one request. Automatic and the
    /// row's captions need counts, which Emby only sends when asked and takes
    /// many seconds to work out.
    private static func nativeUserCollections() async throws -> [HomeCollection] {
        let response: LibraryCollectionsWireResponse = try await HTTPClient.shared.get(
            "/api/v1/collections", query: ["counts": "true"])
        return sorted(response.collections
            .filter { ($0.kind ?? .regular) == .regular }
            .map { HomeCollection(collection: $0, libraryID: 0) })
    }

    /// Silo: each movie, series and mixed library's regular collections and
    /// the profile's own, with the libraries that failed to answer.
    /// `HomeCollection.personalLibraryID` stands for the profile's own list
    /// when it fails. A collection in more than one library shows once.
    private static func siloCollections(profileID: String) async throws -> ServerRead {
        async let personalRead = personalCollections(profileID: profileID)
        let libraries = try await StartupContentPrefetcher.fetchUserLibraries().libraries.filter {
            $0.isMovieLibrary || $0.isSeriesLibrary || $0.isMixedLibrary
        }
        // One library failing shouldn't hide the others' collections.
        var byLibrary: [Int: [LibraryCollection]] = [:]
        var failedLibraries = Set<Int>()
        var failure: Error?
        await withTaskGroup(of: (Int, Result<[LibraryCollection], Error>).self) { group in
            for library in libraries {
                group.addTask { (library.id, await regularCollections(libraryID: library.id)) }
            }
            for await (libraryID, result) in group {
                switch result {
                case .success(let collections):
                    byLibrary[libraryID] = collections
                case .failure(let error):
                    failure = error
                    failedLibraries.insert(libraryID)
                }
            }
        }
        var personal: [LibraryCollection] = []
        switch await personalRead {
        case .success(let collections):
            personal = collections
        case .failure(let error):
            failure = failure ?? error
            failedLibraries.insert(HomeCollection.personalLibraryID)
        }
        if byLibrary.isEmpty, personal.isEmpty, let failure { throw failure }

        var seen = Set<String>()
        var entries: [HomeCollection] = []
        for library in libraries {
            for collection in byLibrary[library.id] ?? [] where seen.insert(collection.id).inserted {
                entries.append(HomeCollection(collection: collection, libraryID: library.id))
            }
        }
        for collection in personal where seen.insert(collection.id).inserted {
            entries.append(HomeCollection(collection: collection, libraryID: HomeCollection.personalLibraryID))
        }
        return (sorted(entries), failedLibraries)
    }

    private nonisolated static func regularCollections(libraryID: Int) async -> Result<[LibraryCollection], Error> {
        do {
            let response = try await VividAPI.shared.visibleLibraryCollections(libraryId: libraryID)
            return .success(response.resolvedSections.flatMap { section in
                section.collections.filter { ($0.kind ?? section.kind) == .regular }
            })
        } catch {
            return .failure(error)
        }
    }

    private static func personalCollections(profileID: String) async -> Result<[LibraryCollection], Error> {
        do {
            return .success(try await VividAPI.shared.personalCollections(profileID: profileID))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Cache

    /// The saved list for one server and profile.
    struct CacheFile: Codable {
        let savedAt: Date
        let collections: [HomeCollection]
    }

    /// Saves, reads and removals run in order, so a save still under way
    /// can't put back a list that account removal just deleted.
    private nonisolated static let cacheQueue = DispatchQueue(label: "vivid.home.collections", qos: .userInitiated)

    nonisolated static func saveCache(_ entries: [HomeCollection], server: String, profile: String,
                                      savedAt: Date = Date()) {
        cacheQueue.async(qos: .utility) {
            guard let url = Scope(server: server, profile: profile).cacheURL,
                  let data = try? JSONEncoder().encode(CacheFile(savedAt: savedAt, collections: entries)) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func readCache(server: String, profile: String) async -> CacheFile? {
        await withCheckedContinuation { continuation in
            cacheQueue.async {
                let file = Scope(server: server, profile: profile).cacheURL
                    .flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? JSONDecoder().decode(CacheFile.self, from: $0) }
                continuation.resume(returning: file)
            }
        }
    }

    nonisolated static func removeCache(server: String, profile: String) {
        cacheQueue.async {
            if let url = Scope(server: server, profile: profile).cacheURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
