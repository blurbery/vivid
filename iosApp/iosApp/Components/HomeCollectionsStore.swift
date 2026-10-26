import Foundation
import Observation

/// One server collection the Collections row can show, with the library it
/// was read from so its page opens the same way as from For You.
struct HomeCollection: Codable, Identifiable, Hashable {
    let collection: LibraryCollection
    let libraryID: Int

    var id: String { collection.id }
}

/// Loads, caches and remembers the Collections row pinned to the bottom of Home.
///
/// Reads the server's own collections, as For You does with Source set to
/// Server: Emby and Jellyfin in one request, Silo from each movie, series and
/// mixed library. User collections are left out. The list is cached per
/// server and profile, so Home shows the row straight away and refreshes it
/// in the background.
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
    /// Silo signs poster URLs for a few hours, so the list is read again
    /// this long before the first one expires.
    nonisolated static let artworkRefreshLead: TimeInterval = 15 * 60

    enum Status: Equatable { case idle, needsAccount, loading, ready, failed }

    private(set) var status: Status = .idle
    /// Every server collection, A to Z.
    private(set) var collections: [HomeCollection] = []
    private(set) var isEnabled = true
    /// nil means automatic: the collections with the most titles.
    private(set) var customPicks: [String]?
    /// Chosen or automatic picks that are still on the server, up to 20.
    /// Kept up to date when the list or the choices change, so the settings
    /// page doesn't work them out again for every poster it draws.
    private(set) var picks: [String] = []
    /// The A to Z list split into carousels of 20.
    private(set) var carousels: [[HomeCollection]] = []
    @ObservationIgnored private var collectionsByID: [String: HomeCollection] = [:]

    private var loadedScope: Scope?
    private var loadedAt: Date?
    /// When the first signed poster URL in the list stops working. Nil when
    /// none carries an expiry, as with Emby and Jellyfin.
    private var artworkExpiresAt: Date?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var hydratedScope: Scope?
    private let defaults = SharedDefaults.shared

    // MARK: Picks

    func collection(_ id: String) -> HomeCollection? { collectionsByID[id] }

    var automaticPicks: [String] { Self.automaticPicks(collections.map(\.collection)) }

    /// The collections with the most titles, ties A to Z. Silo's smart
    /// collections have no count, so they come last.
    static func automaticPicks(_ collections: [LibraryCollection]) -> [String] {
        Array(collections
            .sorted { lhs, rhs in
                switch (lhs.itemCount, rhs.itemCount) {
                case let (l?, r?) where l != r: return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return Self.precedes(lhs, rhs)
                }
            }
            .prefix(maxPicks)
            .map(\.id))
    }

    /// Chosen or automatic picks that are still on the server, up to 20.
    static func picks(custom: [String]?, available: [LibraryCollection]) -> [String] {
        let ids = Set(available.map(\.id))
        let chosen = custom ?? automaticPicks(available)
        return Array(NSOrderedSet(array: chosen.filter(ids.contains)).array
            .compactMap { $0 as? String }.prefix(maxPicks))
    }

    /// The row's collections in order, for the current server and profile only.
    var rowCollections: [HomeCollection] {
        guard loadedScope != nil, loadedScope == Scope.current else { return [] }
        return picks.compactMap(collection)
    }

    var showsRow: Bool { isEnabled && !rowCollections.isEmpty }

    static func carousels(_ collections: [HomeCollection]) -> [[HomeCollection]] {
        stride(from: 0, to: collections.count, by: carouselSize).map {
            Array(collections[$0..<min($0 + carouselSize, collections.count)])
        }
    }

    func isPicked(_ id: String) -> Bool { picks.contains(id) }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        savePreferences()
    }

    func toggle(_ id: String) {
        var current = picks
        if let index = current.firstIndex(of: id) {
            current.remove(at: index)
        } else if current.count < Self.maxPicks, collection(id) != nil {
            current.append(id)
        } else {
            return
        }
        setPicks(current)
    }

    func move(_ id: String, by offset: Int) {
        var current = picks
        guard let index = current.firstIndex(of: id) else { return }
        let target = index + offset
        guard current.indices.contains(target) else { return }
        current.swapAt(index, target)
        setPicks(current)
    }

    func place(_ id: String, at index: Int) {
        var current = picks
        guard let from = current.firstIndex(of: id) else { return }
        current.remove(at: from)
        current.insert(id, at: min(max(0, index), current.count))
        setPicks(current)
    }

    func resetToAutomatic() {
        setCustomPicks(nil)
        savePreferences()
    }

    private func setPicks(_ ids: [String]) {
        setCustomPicks(ids)
        savePreferences()
    }

    private func setCollections(_ entries: [HomeCollection]) {
        collections = entries
        collectionsByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

    // MARK: Preferences

    struct Scope: Equatable {
        let server: String
        let profile: String

        static var current: Scope? {
            guard let server = ServerRegistry.shared.activeServerId,
                  let profile = AuthService.shared.profileId, !profile.isEmpty else { return nil }
            return Scope(server: server, profile: profile)
        }

        var preferencesKey: String { "tvos.homeCollections.v1.\(server).\(profile)" }

        var cacheURL: URL? {
            let token = Data("\(server)|\(profile)".utf8).base64EncodedString()
                .filter { $0.isLetter || $0.isNumber }
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return nil }
            let folder = caches.appendingPathComponent("HomeCollections", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("collections-v1-\(token).json")
        }
    }

    private struct StoredPreferences: Codable, Equatable {
        var isEnabled = true
        var picks: [String]?
    }

    private struct CacheFile: Codable {
        let savedAt: Date
        let collections: [HomeCollection]
    }

    /// Picks up a profile or server switch, or preferences synced from
    /// another device. Another profile's collections are never shown.
    func refresh(force: Bool = false) {
        let scope = Scope.current
        let changed = scope != loadedScope
        guard force || changed else { return }
        if changed {
            loadTask?.cancel()
            loadTask = nil
            loadGeneration += 1
            loadedScope = scope
            hydratedScope = nil
            setCollections([])
            loadedAt = nil
            artworkExpiresAt = nil
            status = .idle
        }
        let stored = scope.flatMap { scope in
            defaults.data(forKey: scope.preferencesKey).flatMap { try? JSONDecoder().decode(StoredPreferences.self, from: $0) }
        } ?? StoredPreferences()
        isEnabled = stored.isEnabled
        setCustomPicks(stored.picks.map { Array(NSOrderedSet(array: $0).array.compactMap { $0 as? String }.prefix(Self.maxPicks)) })
    }

    private func savePreferences() {
        guard let scope = loadedScope else { return }
        let encoder = JSONEncoder()
        // Unchanged choices encode to the same bytes, so syncing doesn't see
        // a new value on every save.
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(StoredPreferences(isEnabled: isEnabled, picks: customPicks)),
              defaults.data(forKey: scope.preferencesKey) != data else { return }
        defaults.set(data, forKey: scope.preferencesKey)
    }

    // MARK: Loading

    /// Shows the cached list, then reads the server again when the list is
    /// older than the refresh interval, its posters are about to expire, or
    /// `force` is set.
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
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.refreshInterval,
           artworkExpiresAt.map({ $0.timeIntervalSinceNow > Self.artworkRefreshLead }) ?? true {
            return
        }
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

    private func hydrate(_ scope: Scope) async {
        guard let url = scope.cacheURL else { return }
        let cached = await Task.detached(priority: .userInitiated) {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CacheFile.self, from: $0) }
        }.value
        guard let cached, loadedScope == scope, collections.isEmpty else { return }
        setCollections(cached.collections)
        loadedAt = cached.savedAt
        artworkExpiresAt = Self.artworkExpiry(of: cached.collections)
        status = .ready
    }

    private func load(_ scope: Scope, generation: Int) async {
        defer { if generation == loadGeneration { loadTask = nil } }
        do {
            let fresh = try await Self.fetchCollections()
            guard generation == loadGeneration, loadedScope == scope, !Task.isCancelled else { return }
            setCollections(fresh)
            loadedAt = Date()
            artworkExpiresAt = Self.artworkExpiry(of: fresh)
            status = .ready
            Self.save(CacheFile(savedAt: Date(), collections: fresh), to: scope.cacheURL)
        } catch {
            guard generation == loadGeneration, loadedScope == scope, !Task.isCancelled else { return }
            // A list already on screen stays up; with nothing to show, report
            // the failure rather than an empty state that reads as none.
            status = collections.isEmpty ? .failed : .ready
        }
    }

    private static func fetchCollections() async throws -> [HomeCollection] {
        if MediaServerProvider.active.usesNativeUser {
            let response: LibraryCollectionsWireResponse = try await HTTPClient.shared.get("/api/v1/collections")
            return sorted(response.collections
                .filter { ($0.kind ?? .regular) == .regular }
                .map { HomeCollection(collection: $0, libraryID: 0) })
        }
        let libraries = try await StartupContentPrefetcher.fetchUserLibraries().libraries.filter {
            $0.isMovieLibrary || $0.isSeriesLibrary || $0.isMixedLibrary
        }
        // One library failing shouldn't hide the others' collections.
        var byLibrary: [Int: [LibraryCollection]] = [:]
        var failure: Error?
        await withTaskGroup(of: (Int, Result<[LibraryCollection], Error>).self) { group in
            for library in libraries {
                group.addTask {
                    do {
                        let response = try await VividAPI.shared.libraryCollections(libraryId: library.id)
                        let regular = response.resolvedSections.flatMap { section in
                            section.collections.filter { ($0.kind ?? section.kind) == .regular }
                        }
                        return (library.id, .success(regular))
                    } catch {
                        return (library.id, .failure(error))
                    }
                }
            }
            for await (libraryID, result) in group {
                switch result {
                case .success(let collections): byLibrary[libraryID] = collections
                case .failure(let error): failure = error
                }
            }
        }
        if byLibrary.isEmpty, let failure { throw failure }
        var seen = Set<String>()
        var entries: [HomeCollection] = []
        for library in libraries {
            for collection in byLibrary[library.id] ?? [] where seen.insert(collection.id).inserted {
                entries.append(HomeCollection(collection: collection, libraryID: library.id))
            }
        }
        return sorted(entries)
    }

    static func sorted(_ entries: [HomeCollection]) -> [HomeCollection] {
        entries.sorted { precedes($0.collection, $1.collection) }
    }

    private static func precedes(_ lhs: LibraryCollection, _ rhs: LibraryCollection) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    nonisolated static func artworkExpiry(of entries: [HomeCollection]) -> Date? {
        entries.compactMap { $0.collection.posterUrl.flatMap(SiloAPICompatibility.artworkExpiry) }.min()
    }

    private nonisolated static func save(_ file: CacheFile, to url: URL?) {
        guard let url else { return }
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func removeCache(server: String, profile: String) {
        if let url = Scope(server: server, profile: profile).cacheURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
