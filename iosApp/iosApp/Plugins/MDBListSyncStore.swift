#if os(iOS) || os(tvOS)
import Foundation
import CryptoKit
import Observation

@Observable @MainActor
final class MDBListSyncStore {
    static let shared = MDBListSyncStore()
    private(set) var isConnected = false
    private(set) var isSyncing = false
    private(set) var syncProgress: MDBListSyncProgress?
    private var pendingWatchlistWork = false
    private(set) var status = "Not connected"
    private let keychain = SharedKeychain(audience: .currentUser)
    private let client = MDBListClient()
    private var loadedScope: String?
    private var credential = ""
    private var revision = UUID()
    private var nextSync = Date.distantPast
    private var state = Checkpoint()
    private var imports = ImportState()
    private var watchlistEntries: [String: WatchlistEntry] = [:]
    private(set) var watchlistRevision = 0

    struct WatchlistEntry: Codable {
        var item: MDBListWatchlistItem
        var local: Bool
        var remote: Bool
    }
    private var importIndex: [MDBListItemID: Set<Int>] = [:]

    struct ImportState: Codable {
        var records: [[MDBListItemID]] = []
        var matched: [String: [MDBListItemID]] = [:]
        var ignored: Set<String> = []
    }


    struct Checkpoint: Codable {
        var userID: Int = 0
        var acknowledged: Set<String> = []
        var exportedContentIDs: Set<String> = []
        var pending: [String: String] = [:]
        var remoteWatched: Set<MDBListItemID> = []
        var lastSync: Date?
    }

    var contextKey: String { scope ?? "signed-out" }
    private var scope: String? {
        guard let account = VividCloudPreferences.matchingActiveAccount,
              let profile = account.profile?.id else { return nil }
        return VividCloudPreferences.pluginScope(server: account.serverID, user: account.userID, profile: profile)
    }
    private func credentialKey(_ scope: String) -> String { "vivid.mdblist.key.v1." + scope }
    private func importKey(_ scope: String) -> String { "vivid.mdblist.imports.v1." + scope }
    private func checkpointKey(_ scope: String) -> String { "vivid.mdblist.history.v1." + scope }

    func reload() {
        let current = scope
        let storedCredential = current.flatMap { keychain.get(credentialKey($0)) } ?? ""
        guard loadedScope != current || credential != storedCredential else { return }
        revision = UUID()
        syncProgress = nil
        loadedScope = current
        credential = storedCredential
        state = current.flatMap { UserDefaults.standard.data(forKey: checkpointKey($0)) }
            .flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) } ?? Checkpoint()
        imports = current.flatMap { UserDefaults.standard.data(forKey: importKey($0)) }
            .flatMap { try? JSONDecoder().decode(ImportState.self, from: $0) } ?? ImportState()
        if let current {
            imports.ignored.formUnion(UserDefaults.standard.stringArray(forKey: importKey(current) + ".ignored") ?? [])
        }
        watchlistEntries = current.flatMap { UserDefaults.standard.data(forKey: "vivid.mdblist.watchlist.v1." + $0) }
            .flatMap { try? JSONDecoder().decode([String: WatchlistEntry].self, from: $0) } ?? [:]
        rebuildImportIndex()
        isConnected = !credential.isEmpty
        status = isConnected ? "Connected" : "Not connected"
        nextSync = .distantPast
    }

    func connect(_ input: String) async throws {
        reload()
        guard let capturedScope = scope else { throw MDBListFailure.noProfile }
        let capturedRevision = revision
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4096, !key.contains(where: \.isWhitespace) else {
            throw MDBListFailure.invalidKey
        }
        let userID = try await client.validate(key: key)
        try Task.checkCancellation()
        guard scope == capturedScope, revision == capturedRevision else { throw CancellationError() }
        try VividCloudPreferences.shared.setPluginCredential(key, for: credentialKey(capturedScope))
        if state.userID != userID {
            state = Checkpoint(userID: userID)
            imports = ImportState()
            watchlistEntries = [:]
            importIndex = [:]
            UserDefaults.standard.removeObject(forKey: importKey(capturedScope) + ".ignored")
        }
        credential = key
        revision = UUID()
        isConnected = true
        status = "Connected"
        nextSync = .distantPast
        try save()
        VividCloudPreferences.shared.schedule()
    }

    func disconnect() throws {
        reload()
        guard let scope else { throw MDBListFailure.noProfile }
        try VividCloudPreferences.shared.setPluginCredential(nil, for: credentialKey(scope))
        credential = ""
        revision = UUID()
        isConnected = false
        status = "Not connected"
        syncProgress = nil
        VividCloudPreferences.shared.schedule()
    }

    func importHistory() {
        Task { await sync(force: true) }
    }

    func run() async {
        reload()
        while !Task.isCancelled {
            await sync()
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    func sync(force: Bool = false) async {
        reload()
        guard isConnected, !isSyncing, force || Date() >= nextSync,
              let scope, let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              let profile = auth.profileId, auth.accessToken != nil else { return }
        let generation = revision
        let key = credential
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                                           profileId: profile, clientFamily: "apple",
                                           credentialGenerationID: auth.account.credentialGenerationID)
        isSyncing = true
        status = "Syncing…"
        pendingWatchlistWork = false
        syncProgress = MDBListSyncProgress(step: 1, label: "Reading watchlists")
        defer { isSyncing = false; syncProgress = nil }
        // Ten-minute checks bound routine usage; failures back off as well.
        nextSync = Date().addingTimeInterval(600)
        do {
            let userID = try await client.validate(key: key)
            try await validate(scope: scope, revision: generation, auth: auth)
            if state.userID != userID {
                state = Checkpoint(userID: userID)
                imports = ImportState()
                watchlistEntries = [:]
                rebuildImportIndex()
                UserDefaults.standard.removeObject(forKey: importKey(scope) + ".ignored")
                try save()
            }
            try await syncWatchlist(scope: scope, generation: generation, auth: auth, identity: identity, key: key)
            syncProgress = MDBListSyncProgress(step: 2, label: "Reading MDBList history")
            let history = try await client.history(key: key)
            try await validate(scope: scope, revision: generation, auth: auth)
            let remote = history.reduce(into: Set<MDBListItemID>()) { $0.formUnion($1.ids) }
            // A complete, validated snapshot is required before any export.
            let previousRecords = Set(imports.records.map(Set.init))
            let incomingRecords = Set(history.map(\.ids).filter { !$0.isEmpty })
            imports.records = previousRecords.union(incomingRecords).map(Array.init)
            rebuildImportIndex()
            if previousRecords != Set(imports.records.map(Set.init)) {
                ResponseCache.shared.invalidateAllItemMetadata()
                #if os(tvOS)
                ItemDetailCache.shared.clearAll()
                #endif
            }
            state.remoteWatched.formUnion(remote)
            state.acknowledged.formUnion(remote.map(\.key))
            try save()
            var unresolvedExports = 0
            var visited = Set<String>()
            for mediaType in ["movie", "episode"] {
                let step = mediaType == "movie" ? 3 : 4
                let label = mediaType == "movie" ? "Syncing movie history" : "Syncing episode history"
                syncProgress = MDBListSyncProgress(step: step, label: label)
                var offset = 0
                var snapshot: String?
                for page in 0..<1000 {
                    try await validate(scope: scope, revision: generation, auth: auth)
                    var query = ["source": "history", "type": mediaType, "offset": String(offset), "limit": "100"]
                    if let snapshot { query["snapshot"] = snapshot }
                    let response = try await HTTPClient.shared.requestData(method: "GET", path: "/api/v1/catalog",
                                                                           query: query, requestIdentity: identity)
                    let catalog = try Self.decoder().decode(CatalogResponse.self, from: response.data)
                    try await validate(scope: scope, revision: generation, auth: auth)
                    if snapshot == nil { snapshot = catalog.snapshot }
                    var batch: [(contentID: String, ids: [MDBListItemID], date: String)] = []
                    func flushBatch() async throws {
                        guard !batch.isEmpty else { return }
                        try save() // Pending timestamps are durable before any network write.
                        try await validate(scope: scope, revision: generation, auth: auth)
                        syncProgress = MDBListSyncProgress(step: step, label: "Uploading watched \(mediaType == "movie" ? "movies" : "episodes")", completed: offset, total: catalog.total)
                        let accepted = try await client.addBatch(batch.map { ($0.ids[0], $0.date) }, key: key)
                        try await validate(scope: scope, revision: generation, auth: auth)
                        for entry in batch {
                            guard accepted.contains(entry.ids[0]) else { unresolvedExports += 1; continue }
                            state.acknowledged.formUnion(entry.ids.map(\.key))
                            state.exportedContentIDs.insert(entry.contentID)
                            state.pending.removeValue(forKey: entry.ids[0].key)
                        }
                        try save()
                        batch.removeAll(keepingCapacity: true)
                    }
                    for (index, item) in catalog.items.enumerated() {
                        syncProgress = MDBListSyncProgress(step: step, label: label,
                            completed: offset + index, total: catalog.total)
                        guard visited.insert(item.contentId).inserted else { continue }
                        guard item.type == "movie" || item.type == "episode" else { continue }
                        guard !state.exportedContentIDs.contains(item.contentId) else { continue }
                        try await validate(scope: scope, revision: generation, auth: auth)
                        let detail: ItemDetail
                        do {
                            let detailResponse = try await HTTPClient.shared.requestData(method: "GET",
                                path: "/api/v1/catalog/items/\(item.contentId)", requestIdentity: identity)
                            detail = try Self.decoder().decode(ItemDetail.self, from: detailResponse.data)
                        } catch HTTPError.http(statusCode: 404, body: _) {
                            unresolvedExports += 1
                            continue
                        }
                        try await validate(scope: scope, revision: generation, auth: auth)
                        // History can contain unfinished playback. Only completed leaves export.
                        guard detail.userData?.played == true || item.userState?.played == true else { continue }
                        let ids = Self.identifiers(detail)
                        guard let preferred = ids.first else { unresolvedExports += 1; continue }
                        if ids.contains(where: { state.acknowledged.contains($0.key) }) {
                            state.acknowledged.formUnion(ids.map(\.key))
                            state.exportedContentIDs.insert(item.contentId)
                            continue
                        }
                        let watchedAt = state.pending[preferred.key] ?? ISO8601DateFormatter().string(from: Date())
                        state.pending[preferred.key] = watchedAt
                        batch.append((item.contentId, ids, watchedAt))
                        if batch.count == 50 { try await flushBatch() }
                    }
                    try await flushBatch()
                    try save()
                    offset += catalog.items.count
                    syncProgress = MDBListSyncProgress(step: step, label: label, completed: offset, total: catalog.total)
                    let more = catalog.hasMore ?? (catalog.total.map { offset < $0 } ?? (catalog.items.count == 100))
                    if !more { break }
                    guard !catalog.items.isEmpty, page < 999 else { throw MDBListFailure.incomplete }
                }
            }
            try await validate(scope: scope, revision: generation, auth: auth)
            state.lastSync = Date()
            try save()
            if unresolvedExports > 0 {
                status = "Sync finished. \(unresolvedExports) watched items could not be matched or confirmed and will be retried."
            } else {
                status = pendingWatchlistWork ? "This batch is synced. More watchlist changes remain for the next check." : "Synced. Imported history stays in Vivid."
            }
        } catch is CancellationError {
            if revision == generation { try? save(); status = "Connected. Sync paused." }
        } catch {
            if revision == generation { try? save() }
            if revision == generation { status = (error as? MDBListFailure)?.localizedDescription ?? "Sync interrupted. It will try again later." }
            if case MDBListFailure.quota = error { nextSync = Date().addingTimeInterval(3600) }
        }
    }

    func watchlistChanged(expected: CapturedOrdinaryRequestAuth?) async {
        guard let expected, let current = await TokenStore.shared.captureOrdinaryRequestAuth(),
              current.account == expected.account, current.profileId == expected.profileId else { return }
        reload()
        guard isConnected else { return }
        nextSync = .distantPast
    }

    private func syncWatchlist(scope: String, generation: UUID, auth: CapturedOrdinaryRequestAuth,
                              identity: HTTPRequestIdentity, key: String) async throws {
        func validateContext() async throws {
            try await validate(scope: scope, revision: generation, auth: auth)
        }
        func catalog(path: String, query: [String: String] = [:]) async throws -> [BrowseItem] {
            var items: [BrowseItem] = []
            var seen = Set<String>()
            var offset = 0
            var snapshot: String?
            for page in 0..<100 {
                try await validateContext()
                var q = query.merging(["offset": String(offset), "limit": "100"]) { _, new in new }
                if let snapshot { q["snapshot"] = snapshot }
                let raw = try await HTTPClient.shared.requestData(method: "GET", path: path, query: q, requestIdentity: identity)
                let response = try Self.decoder().decode(CatalogResponse.self, from: raw.data)
                try await validateContext()
                if snapshot == nil { snapshot = response.snapshot }
                for item in response.items {
                    guard seen.insert(item.contentId).inserted else { throw MDBListFailure.incomplete }
                    items.append(item)
                }
                offset += response.items.count
                let more = response.hasMore ?? (response.total.map { offset < $0 } ?? (response.items.count == 100))
                if !more { return items }
                guard !response.items.isEmpty, page < 99 else { throw MDBListFailure.incomplete }
            }
            throw MDBListFailure.incomplete
        }
        var detailCache: [String: MDBListWatchlistItem] = [:]
        var missingDetails = Set<String>()
        func detail(_ contentID: String) async throws -> MDBListWatchlistItem? {
            try await validateContext()
            if let cached = detailCache[contentID] { return cached }
            if missingDetails.contains(contentID) { return nil }
            do {
                let raw = try await HTTPClient.shared.requestData(method: "GET", path: "/api/v1/catalog/items/\(contentID)",
                    requestIdentity: identity)
                let item = try Self.decoder().decode(ItemDetail.self, from: raw.data)
                try await validateContext()
                let resolved = MDBListWatchlistItem(type: item.type == "series" ? "show" : item.type,
                    title: item.title, tmdb: item.tmdbId, imdb: item.imdbId)
                detailCache[contentID] = resolved
                return resolved
            } catch HTTPError.http(statusCode: 404, body: _) { missingDetails.insert(contentID); return nil }
        }
        let remote = try await client.watchlist(key: key)
        try await validateContext()
        let local = try await catalog(path: "/api/v1/watchlist")
        let localIDs = Set(local.map(\.contentId))
        var resolved: [String: MDBListWatchlistItem] = [:]
        // Revalidate mappings even for absent local entries: a missing library item
        // must never be mistaken for an intentional watchlist removal.
        let activeMappings = watchlistEntries.filter { _, entry in
            entry.local || entry.remote || remote.contains(where: { $0.matches(entry.item) })
        }
        let lookupIDs = localIDs.union(activeMappings.keys).sorted()
        let lookupCount = lookupIDs.count + remote.count
        for (index, id) in lookupIDs.enumerated() {
            syncProgress = MDBListSyncProgress(step: 1, label: "Checking watchlist matches", completed: index, total: lookupCount)
            if let item = try await detail(id) {
                if let old = watchlistEntries[id], !old.item.matches(item) { continue }
                resolved[id] = item
            }
        }
        for (index, item) in remote.enumerated() {
            syncProgress = MDBListSyncProgress(step: 1, label: "Checking watchlist matches", completed: lookupIDs.count + index, total: lookupCount)
            guard !resolved.values.contains(where: { $0.matches(item) }) else { continue }
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let candidates = try await catalog(path: "/api/v1/catalog",
                query: ["q": item.title, "type": item.type == "show" ? "series" : "movie"])
            // Never choose from a truncated candidate set or fan out across a huge ambiguous title.
            guard candidates.count <= 100 else { continue }
            var matches: [String: MDBListWatchlistItem] = [:]
            for (candidateIndex, candidate) in candidates.enumerated() {
                syncProgress = MDBListSyncProgress(step: 1, label: "Matching \(item.title)", completed: candidateIndex, total: candidates.count)
                if let found = try await detail(candidate.contentId), found.matches(item) { matches[candidate.contentId] = found }
            }
            if matches.count == 1 { resolved.merge(matches) { current, _ in current } }
        }
        var localWrites = false
        defer { if localWrites { watchlistRevision += 1 } }
        var remoteWrites = false
        var plans: [(String, MDBListWatchlistItem, Bool)] = []
        var mutations = 0
        for (index, entry) in resolved.sorted(by: { $0.key < $1.key }).enumerated() {
            let (id, item) = entry
            syncProgress = MDBListSyncProgress(step: 1, label: "Syncing watchlist changes", completed: index, total: resolved.count)
            // Ambiguous server copies and conflicting remote IDs remain untouched.
            guard resolved.values.filter({ $0.matches(item) }).count == 1 else { continue }
            let overlaps = remote.filter { !$0.keys.isDisjoint(with: item.keys) }
            guard overlaps.allSatisfy({ $0.matches(item) }) else { continue }
            let remotePresent = !overlaps.isEmpty
            let localPresent = localIDs.contains(id)
            let previous = watchlistEntries[id]
            let desired = MDBListWatchlistPolicy.desired(local: localPresent, remote: remotePresent,
                previousLocal: previous?.local, previousRemote: previous?.remote)
            try await validateContext()
            if localPresent != desired || remotePresent != desired {
                guard mutations < 32 else { pendingWatchlistWork = true; break }
                mutations += 1
            }
            if remotePresent != desired {
                try await client.setWatchlist(item, present: desired, key: key)
                try await validateContext()
                remoteWrites = true
            }
            if localPresent != desired {
                _ = try await HTTPClient.shared.requestData(method: desired ? "PUT" : "DELETE",
                    path: "/api/v1/watchlist/\(id)", requestIdentity: identity)
                try await validateContext()
                ResponseCache.shared.remove(CacheKey.watchlist)
                ResponseCache.shared.invalidateAllItemMetadata()
                localWrites = true
            }
            plans.append((id, item, desired))
        }
        guard !plans.isEmpty else { try save(); return }
        // Read back writes. Failed or partial responses never advance the baseline.
        syncProgress = MDBListSyncProgress(step: 1, label: "Verifying watchlist changes")
        let confirmedRemote = remoteWrites ? try await client.watchlist(key: key) : remote
        try await validateContext()
        let confirmedLocal = Set(try await catalog(path: "/api/v1/watchlist").map(\.contentId))
        var unconfirmed = false
        for (id, item, desired) in plans {
            guard confirmedLocal.contains(id) == desired,
                  confirmedRemote.contains(where: { $0.matches(item) }) == desired else { unconfirmed = true; continue }
            watchlistEntries[id] = WatchlistEntry(item: item, local: desired, remote: desired)
        }
        try save()
        if unconfirmed { throw MDBListFailure.incomplete }
    }

    private func validate(scope: String, revision: UUID, auth: CapturedOrdinaryRequestAuth) async throws {
        try Task.checkCancellation()
        guard self.scope == scope, self.revision == revision, isConnected,
              let current = await TokenStore.shared.captureOrdinaryRequestAuth(),
              current.account == auth.account, current.profileId == auth.profileId,
              current.accessToken != nil else { throw CancellationError() }
        try Task.checkCancellation()
        guard self.scope == scope, self.revision == revision else { throw CancellationError() }
    }

    private func save() throws {
        guard let scope = loadedScope, scope == self.scope else { throw CancellationError() }
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: checkpointKey(scope))
        UserDefaults.standard.set(try JSONEncoder().encode(imports), forKey: importKey(scope))
        UserDefaults.standard.set(try JSONEncoder().encode(watchlistEntries), forKey: "vivid.mdblist.watchlist.v1." + scope)
    }

    /// A playback intent protects even the interval before the first server progress report.
    func ignoreImport(contentID: String) {
        reload()
        guard scope != nil else { return }
        imports.ignored.insert(contentID)
        imports.matched.removeValue(forKey: contentID)
        persistIgnores()
        ResponseCache.shared.remove(CacheKey.itemDetail(contentID))
        ResponseCache.shared.remove(CacheKey.itemWatchDetail(contentID))
    }

    func removeLocalImport(contentID: String, expected: CapturedOrdinaryRequestAuth?) async throws -> Bool {
        guard let expected, let current = await TokenStore.shared.captureOrdinaryRequestAuth(),
              current.account == expected.account, current.profileId == expected.profileId else { return false }
        reload()
        guard imports.matched[contentID] != nil, !imports.ignored.contains(contentID) else { return false }
        let generation = revision
        let capturedScope = scope
        guard let profile = expected.profileId else { throw HTTPError.requestIdentityChanged }
        let identity = HTTPRequestIdentity(serverId: expected.account.serverId, serverURL: expected.account.serverURL,
            profileId: profile, clientFamily: "apple", credentialGenerationID: expected.account.credentialGenerationID)
        let raw = try await HTTPClient.shared.requestData(method: "GET", path: "/api/v1/catalog/items/\(contentID)", requestIdentity: identity)
        let detail = try Self.decoder().decode(ItemDetail.self, from: raw.data)
        guard revision == generation, scope == capturedScope else { throw CancellationError() }
        let localOnly = MDBListImportPolicy.isEligible(played: detail.userData?.played,
            inProgress: detail.userData?.isInProgress, position: detail.userData?.positionSeconds, locallyStarted: false)
        ignoreImport(contentID: contentID)
        return localOnly
    }

    func decorate<T>(_ value: T, expected: CapturedOrdinaryRequestAuth?) async -> T {
        guard let expected, expected.accessToken != nil,
              let current = await TokenStore.shared.captureOrdinaryRequestAuth(),
              current.account == expected.account, current.profileId == expected.profileId,
              current.accessToken != nil else { return value }
        reload()
        guard let account = TVSavedAccountStore.shared.activeAccount,
              account.serverID == expected.account.serverId,
              AuthService.shared.profileId == expected.profileId, !imports.records.isEmpty else { return value }
        // There are no suspension points between checking ownership and applying local state.
        if var detail = value as? ItemDetail {
            let ids = Self.identifiers(detail)
            if matchesImport(ids) {
                detail.userData = importedState(detail.userData, contentID: detail.contentId, ids: ids)
            } else { imports.matched.removeValue(forKey: detail.contentId) }
            return (detail as? T) ?? value
        }
        if var episodes = value as? EpisodesResponse {
            for index in episodes.episodes.indices {
                let item = episodes.episodes[index]
                let ids = [("tmdb", item.tmdbId), ("tvdb", item.tvdbId)].compactMap {
                    MDBListItemID(type: "episode", provider: $0.0, value: $0.1)
                }
                if matchesImport(ids) {
                    episodes.episodes[index].userData = importedState(item.userData, contentID: item.contentId, ids: ids)
                } else { imports.matched.removeValue(forKey: item.contentId) }
            }
            return (episodes as? T) ?? value
        }
        if var watch = value as? WatchDetail, watch.type == "movie" || watch.type == "episode",
           let ids = imports.matched[watch.contentId], matchesImport(ids) {
            watch.userData = importedState(watch.userData, contentID: watch.contentId, ids: ids)
            return (watch as? T) ?? value
        }
        return value
    }

    private func importedState(_ original: LeafItemUserData?, contentID: String, ids: [MDBListItemID]) -> LeafItemUserData? {
        if original?.played == true || original?.isInProgress == true || (original?.positionSeconds ?? 0) > 0 {
            if imports.ignored.insert(contentID).inserted { persistIgnores() }
            imports.matched.removeValue(forKey: contentID)
            return original
        }
        guard MDBListImportPolicy.isEligible(played: original?.played,
            inProgress: original?.isInProgress, position: original?.positionSeconds,
            locallyStarted: imports.ignored.contains(contentID)), var result = original else { return original }
        imports.matched[contentID] = ids
        result.played = true
        return result // Position, in-progress flag, duration and file/version hints are untouched.
    }

    private func rebuildImportIndex() {
        importIndex = [:]
        for (index, record) in imports.records.enumerated() {
            for id in record { importIndex[id, default: []].insert(index) }
        }
    }

    private func matchesImport(_ ids: [MDBListItemID]) -> Bool {
        let candidates = ids.reduce(into: Set<Int>()) { $0.formUnion(importIndex[$1] ?? []) }
        return MDBListImportPolicy.matches(ids, records: candidates.map { imports.records[$0] })
    }

    private func persistIgnores() {
        guard let scope = loadedScope, scope == self.scope else { return }
        UserDefaults.standard.set(Array(imports.ignored), forKey: importKey(scope) + ".ignored")
    }

    static func identifiers(_ item: ItemDetail) -> [MDBListItemID] {
        [("tmdb", item.tmdbId), ("imdb", item.imdbId), ("tvdb", item.tvdbId)].compactMap {
            MDBListItemID(type: item.type, provider: $0.0, value: $0.1)
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
#endif
