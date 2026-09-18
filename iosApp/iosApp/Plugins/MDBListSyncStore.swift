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
    private var quotaRetryAfter = Date.distantPast
    private var state = Checkpoint()
    private var watchlistEntries: [String: WatchlistEntry] = [:]
    private(set) var watchlistRevision = 0

    struct WatchlistEntry: Codable {
        var item: MDBListWatchlistItem
        var local: Bool
        var remote: Bool
    }
    struct Checkpoint: Codable {
        var userID: Int = 0
        var acknowledged: Set<String> = []
        var exportedContentIDs: Set<String> = []
        var pendingCompletions: [String: String]? = [:]
        var quotaRetryAfter: Date?
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
        if let current {
            UserDefaults.standard.removeObject(forKey: importKey(current))
            UserDefaults.standard.removeObject(forKey: importKey(current) + ".ignored")
        }
        watchlistEntries = current.flatMap { UserDefaults.standard.data(forKey: "vivid.mdblist.watchlist.v1." + $0) }
            .flatMap { try? JSONDecoder().decode([String: WatchlistEntry].self, from: $0) } ?? [:]
        isConnected = !credential.isEmpty
        status = isConnected ? "Connected" : "Not connected"
        nextSync = .distantPast
        quotaRetryAfter = state.quotaRetryAfter ?? .distantPast
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
            watchlistEntries = [:]
            UserDefaults.standard.removeObject(forKey: importKey(capturedScope) + ".ignored")
        }
        quotaRetryAfter = state.quotaRetryAfter ?? .distantPast
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

    func syncNow() {
        Task { await sync(force: true) }
    }

    // Only called after the originating server confirms a completed watch.
    func completedWatch(contentID: String, expected: CapturedOrdinaryRequestAuth?) async {
        guard let expected, let current = await TokenStore.shared.captureOrdinaryRequestAuth(),
              current.account == expected.account, current.profileId == expected.profileId else { return }
        reload()
        guard isConnected, !state.exportedContentIDs.contains(contentID) else { return }
        if state.pendingCompletions?[contentID] == nil {
            if state.pendingCompletions == nil { state.pendingCompletions = [:] }
            state.pendingCompletions?[contentID] = ISO8601DateFormatter().string(from: Date())
        }
        do { try save(); nextSync = .distantPast }
        catch { status = "Your server progress is saved. MDBList will try again later." }
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
        guard isConnected, !isSyncing, Date() >= quotaRetryAfter,
              force || Date() >= nextSync, let scope else { return }
        isSyncing = true
        defer { isSyncing = false; syncProgress = nil }
        let generation = revision
        let key = credential
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              let profile = auth.profileId, auth.accessToken != nil,
              self.scope == scope, revision == generation else { return }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                                           profileId: profile, clientFamily: "apple",
                                           credentialGenerationID: auth.account.credentialGenerationID)
        status = "Syncing…"
        pendingWatchlistWork = false
        syncProgress = MDBListSyncProgress(step: 1, label: "Sending completed watches")
        // Ten-minute checks bound routine usage; failures back off as well.
        nextSync = Date().addingTimeInterval(600)
        do {
            let userID = try await client.validate(key: key)
            try await validate(scope: scope, revision: generation, auth: auth)
            if state.userID != userID {
                let queued = state.userID == 0 ? state.pendingCompletions : [:]
                state = Checkpoint(userID: userID, pendingCompletions: queued)
                watchlistEntries = [:]
                UserDefaults.standard.removeObject(forKey: importKey(scope) + ".ignored")
                try save()
            }
            var unresolvedExports = 0
            let pending = (state.pendingCompletions ?? [:]).sorted { $0.value < $1.value }
            for (contentID, watchedAt) in pending {
                try await validate(scope: scope, revision: generation, auth: auth)
                syncProgress = MDBListSyncProgress(step: 1, label: "Sending completed watches")
                let detail: ItemDetail
                do {
                    let raw = try await HTTPClient.shared.requestData(method: "GET",
                        path: "/api/v1/catalog/items/\(contentID)", requestIdentity: identity)
                    detail = try Self.decoder().decode(ItemDetail.self, from: raw.data)
                } catch HTTPError.http(statusCode: 404, body: _) {
                    unresolvedExports += 1
                    continue
                }
                try await validate(scope: scope, revision: generation, auth: auth)
                guard detail.type == "movie" || detail.type == "episode" else {
                    state.pendingCompletions?.removeValue(forKey: contentID)
                    try save()
                    continue
                }
                guard detail.userData?.played == true else {
                    if detail.userData?.played == false {
                        state.pendingCompletions?.removeValue(forKey: contentID)
                        try save()
                    } else { unresolvedExports += 1 }
                    continue
                }
                let ids = Self.identifiers(detail)
                guard let preferred = ids.first else { unresolvedExports += 1; continue }
                if !ids.contains(where: { state.acknowledged.contains($0.key) }) {
                    do {
                        try await client.add(preferred, watchedAt: watchedAt, key: key)
                    } catch MDBListFailure.incomplete {
                        try await validate(scope: scope, revision: generation, auth: auth)
                        unresolvedExports += 1
                        continue
                    }
                    try await validate(scope: scope, revision: generation, auth: auth)
                }
                state.acknowledged.formUnion(ids.map(\.key))
                state.exportedContentIDs.insert(contentID)
                state.pendingCompletions?.removeValue(forKey: contentID)
                try save()
            }
            try await syncWatchlist(scope: scope, generation: generation, auth: auth, identity: identity, key: key)
            try await validate(scope: scope, revision: generation, auth: auth)
            state.lastSync = Date()
            try save()
            if unresolvedExports > 0 {
                status = "Sync finished. \(unresolvedExports) watched items could not be matched or confirmed and will be retried."
            } else {
                status = pendingWatchlistWork ? "This batch is synced. More watchlist changes remain for the next check." : "Watched history and watchlists are synced."
            }
        } catch is CancellationError {
            if revision == generation { try? save(); status = "Connected. Sync paused." }
        } catch {
            if revision == generation { try? save() }
            if revision == generation { status = (error as? MDBListFailure)?.localizedDescription ?? "Sync interrupted. It will try again later." }
            if revision == generation, case MDBListFailure.quota = error {
                quotaRetryAfter = Date().addingTimeInterval(3600)
                state.quotaRetryAfter = quotaRetryAfter
                nextSync = quotaRetryAfter
                try? save()
            }
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
        syncProgress = MDBListSyncProgress(step: 2, label: "Reading watchlists")
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
            syncProgress = MDBListSyncProgress(step: 2, label: "Checking watchlist matches", completed: index, total: lookupCount)
            if let item = try await detail(id) {
                if let old = watchlistEntries[id], !old.item.matches(item) { continue }
                resolved[id] = item
            }
        }
        for (index, item) in remote.enumerated() {
            syncProgress = MDBListSyncProgress(step: 2, label: "Checking watchlist matches", completed: lookupIDs.count + index, total: lookupCount)
            guard !resolved.values.contains(where: { $0.matches(item) }) else { continue }
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let candidates = try await catalog(path: "/api/v1/catalog",
                query: ["q": item.title, "type": item.type == "show" ? "series" : "movie"])
            // Never choose from a truncated candidate set or fan out across a huge ambiguous title.
            guard candidates.count <= 100 else { continue }
            var matches: [String: MDBListWatchlistItem] = [:]
            for (candidateIndex, candidate) in candidates.enumerated() {
                syncProgress = MDBListSyncProgress(step: 2, label: "Matching \(item.title)", completed: candidateIndex, total: candidates.count)
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
            syncProgress = MDBListSyncProgress(step: 2, label: "Syncing watchlist changes", completed: index, total: resolved.count)
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
        syncProgress = MDBListSyncProgress(step: 2, label: "Verifying watchlist changes")
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
        UserDefaults.standard.set(try JSONEncoder().encode(watchlistEntries), forKey: "vivid.mdblist.watchlist.v1." + scope)
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
