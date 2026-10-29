#if os(iOS) || os(tvOS)
import Foundation
import Observation

/// Simkl sign-in and sync for the active server account and profile.
///
/// Each device signs in on its own. Refreshing a Simkl sign-in ends the
/// previous access token, so one sign-in shared through the iCloud vault
/// would keep cutting the other devices off. The tokens stay in this
/// device's Keychain and never join the vault.
@Observable @MainActor
final class SimklSyncStore {
    static let shared = SimklSyncStore()

    struct SignInPrompt: Equatable {
        let userCode: String
        let verificationURL: URL
        let completeURL: URL?
        let expiresAt: Date
        var approvalURL: URL { completeURL ?? verificationURL }
    }

    private(set) var isConnected = false
    private(set) var isSyncing = false
    private(set) var signIn: SignInPrompt?
    private(set) var signInMessage: String?
    private(set) var syncProgress: SimklSyncProgress?
    private(set) var status = String(localized: "Not connected")
    private(set) var watchlistRevision = 0

    private let keychain = SharedKeychain(audience: .currentUser)
    private let client = SimklClient()
    private var loadedScope: String?
    private var tokens: SimklTokens?
    private var revision = UUID()
    private var nextSync = Date.distantPast
    private var state = Checkpoint()
    private var cache: LibraryCache?
    private var signInTask: Task<Void, Never>?
    private var signInID: UUID?
    private var moreWatchlistWork = false

    // Simkl asks apps to sync on launch and after changes, a few times an
    // hour at most. Its daily allowance is shared with the person's other apps.
    private static let foregroundInterval: TimeInterval = 15 * 60
    private static let routineInterval: TimeInterval = 60 * 60
    private static let changeDelay: TimeInterval = 90
    private static let quotaFloor = 20

    struct Checkpoint: Codable {
        var accountID = 0
        var watchlist: [String: WatchlistEntry] = [:]
        var pendingCompletions: [String: PendingCompletion] = [:]
        var exported: [String: Date] = [:]
        /// Simkl Plan to Watch titles not found on the server, and when.
        var unmatched: [Int: Date] = [:]
        /// Watchlist entries that aren't a movie or series, or can't be read.
        var skipped: Set<String> = []
        var retryAfter: Date?
        var lastAttempt: Date?
        var lastSync: Date?
        var lastFullWatchlistCheck: Date?
        var failures = 0
    }
    struct PendingCompletion: Codable {
        var watchedAt: String
        var attempts = 0
    }
    /// What the last sync confirmed. `remote` only ever comes from reading
    /// the Simkl library, never from Vivid's own writes.
    struct WatchlistEntry: Codable {
        var kind: SimklKind
        var ids: SimklIDs
        var local: Bool
        var remote: Bool
        var lookedUpAt: Date?
    }
    /// The library and the activities snapshot it reflects, kept together
    /// in Caches. If the system clears it, the next sync reads it again.
    struct LibraryCache: Codable {
        var accountID: Int
        var activities: SimklActivities
        var items: [Int: SimklLibraryItem]
    }
    private struct Target {
        let kind: SimklKind
        let ids: SimklIDs
    }

    var contextKey: String { scope ?? "signed-out" }
    private var scope: String? {
        guard let account = VividCloudPreferences.matchingActiveAccount,
              let profile = account.profile?.id else { return nil }
        return VividCloudPreferences.pluginScope(server: account.serverID, user: account.userID, profile: profile)
    }
    private static func tokenKey(_ scope: String) -> String { "vivid.simkl.tokens.v1." + scope }
    private static func checkpointKey(_ scope: String) -> String { "vivid.simkl.state.v1." + scope }
    private static func cacheURL(_ scope: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("Simkl", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("library-v1-\(scope).json")
    }

    func reload() {
        let current = scope
        let storedTokens = current.flatMap { Self.readTokens(Self.tokenKey($0), keychain) }
        guard loadedScope != current || tokens != storedTokens else { return }
        if loadedScope != current {
            cancelSignIn()
            signInMessage = nil
        }
        revision = UUID()
        syncProgress = nil
        loadedScope = current
        tokens = storedTokens
        cache = nil
        state = current.flatMap { UserDefaults.standard.data(forKey: Self.checkpointKey($0)) }
            .flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) } ?? Checkpoint()
        isConnected = tokens != nil
        status = isConnected ? String(localized: "Connected") : String(localized: "Not connected")
        nextSync = state.pendingCompletions.isEmpty
            ? (state.lastAttempt ?? .distantPast).addingTimeInterval(Self.foregroundInterval) : .distantPast
    }

    // MARK: Sign-in

    func beginSignIn() {
        reload()
        guard signInTask == nil, !isConnected else { return }
        signInMessage = nil
        guard SimklApp.isAvailable else { signInMessage = SimklFailure.notConfigured.localizedDescription; return }
        guard let captured = scope else { signInMessage = SimklFailure.noProfile.localizedDescription; return }
        let id = UUID()
        signInID = id
        signInTask = Task { [weak self] in await self?.runSignIn(id: id, scope: captured) }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInID = nil
        signIn = nil
    }

    private func runSignIn(id: UUID, scope captured: String) async {
        defer {
            if signInID == id {
                signInID = nil
                signInTask = nil
                signIn = nil
            }
        }
        func current() -> Bool { signInID == id && scope == captured && !Task.isCancelled }
        do {
            let authorization = try await client.requestDeviceCode()
            guard current() else { return }
            signIn = SignInPrompt(userCode: authorization.userCode, verificationURL: authorization.verificationURL,
                                  completeURL: authorization.completeURL, expiresAt: authorization.expiresAt)
            var interval = authorization.interval
            // Simkl sends no signal for a declined request, so the code's
            // own expiry ends the wait.
            while Date().addingTimeInterval(interval) < authorization.expiresAt {
                try await Task.sleep(for: .seconds(interval))
                guard current() else { return }
                let poll: SimklTokenPoll
                // Leaving Vivid to approve can drop a request. Keep waiting.
                do { poll = try await client.pollToken(deviceCode: authorization.deviceCode) }
                catch SimklFailure.unavailable { continue }
                guard current() else {
                    if case .approved(let tokens) = poll { await client.revoke(token: tokens.refreshToken) }
                    return
                }
                switch poll {
                case .pending: continue
                case .slowDown: interval += 5
                case .expired: throw SimklFailure.signInTimedOut
                case .approved(let tokens):
                    try await finishSignIn(tokens, id: id, scope: captured)
                    return
                }
            }
            throw SimklFailure.signInTimedOut
        } catch is CancellationError {
        } catch {
            if signInID == id {
                signInMessage = (error as? SimklFailure ?? .unavailable).localizedDescription
            }
        }
    }

    private func finishSignIn(_ tokens: SimklTokens, id: UUID, scope captured: String) async throws {
        // Simkl quietly grants read-only access when write isn't allowed.
        guard tokens.canWrite else {
            await client.revoke(token: tokens.refreshToken)
            throw SimklFailure.missingWriteAccess
        }
        let accountID: Int
        do { accountID = try await client.accountID(token: tokens.accessToken) }
        catch {
            await client.revoke(token: tokens.refreshToken)
            throw error
        }
        guard signInID == id, scope == captured, loadedScope == captured else {
            await client.revoke(token: tokens.refreshToken)
            throw CancellationError()
        }
        guard Self.writeTokens(tokens, key: Self.tokenKey(captured), keychain) else {
            await client.revoke(token: tokens.refreshToken)
            throw SimklFailure.storage
        }
        if state.accountID != accountID {
            let queued = state.accountID == 0 ? state.pendingCompletions : [:]
            state = Checkpoint(accountID: accountID)
            state.pendingCompletions = queued
            cache = nil
            Self.removeCache(captured)
        }
        self.tokens = tokens
        revision = UUID()
        isConnected = true
        status = String(localized: "Connected")
        nextSync = .distantPast
        try save()
        syncNow()
    }

    func disconnect() throws {
        reload()
        guard let scope else { throw SimklFailure.noProfile }
        cancelSignIn()
        let previous = tokens
        guard keychain.delete(Self.tokenKey(scope)) else { throw SimklFailure.storage }
        tokens = nil
        revision = UUID()
        isConnected = false
        signInMessage = nil
        status = String(localized: "Not connected")
        syncProgress = nil
        if let previous {
            let client = client
            Task { await client.revoke(token: previous.refreshToken) }
        }
    }

    /// Removing a saved account removes its Simkl sign-in and sync state
    /// from this device. Simkl keeps the person's history and lists.
    static func forget(scope: String) {
        let keychain = SharedKeychain(audience: .currentUser)
        if let tokens = readTokens(tokenKey(scope), keychain) {
            let client = SimklClient()
            Task { await client.revoke(token: tokens.refreshToken) }
        }
        _ = keychain.delete(tokenKey(scope))
        UserDefaults.standard.removeObject(forKey: checkpointKey(scope))
        removeCache(scope)
        if shared.loadedScope == scope {
            shared.loadedScope = nil
            shared.reload()
        }
    }

    // MARK: Changes from Vivid

    func syncNow() {
        Task { await sync(force: true) }
    }

    // Only called after the originating server confirms a completed watch.
    func completedWatch(contentID: String, expected: CapturedOrdinaryRequestAuth?) async {
        guard let expected, let current = await TokenStore.shared.captureOrdinaryRequestAuth(),
              current.account == expected.account, current.profileId == expected.profileId else { return }
        reload()
        guard isConnected, state.exported[contentID] == nil else { return }
        if state.pendingCompletions[contentID] == nil {
            state.pendingCompletions[contentID] = PendingCompletion(watchedAt: ISO8601DateFormatter().string(from: Date()))
        }
        do {
            try save()
            nextSync = min(nextSync, Date().addingTimeInterval(Self.changeDelay))
        } catch { status = String(localized: "Your server progress is saved. Simkl will try again later.") }
    }

    func watchlistChanged(expected: CapturedOrdinaryRequestAuth?) async {
        guard let expected, let current = await TokenStore.shared.captureOrdinaryRequestAuth(),
              current.account == expected.account, current.profileId == expected.profileId else { return }
        reload()
        guard isConnected else { return }
        nextSync = min(nextSync, Date().addingTimeInterval(Self.changeDelay))
    }

    func run() async {
        reload()
        while !Task.isCancelled {
            await sync()
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    // MARK: Sync

    func sync(force: Bool = false) async {
        reload()
        let now = Date()
        guard SimklApp.isAvailable, isConnected, !isSyncing, let scope, now >= (state.retryAfter ?? .distantPast) else { return }
        // Sync now still waits a minute between runs.
        if force {
            guard now >= (state.lastAttempt ?? .distantPast).addingTimeInterval(60) else { return }
        } else {
            guard now >= nextSync else { return }
        }
        let generation = revision
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              let profile = auth.profileId, auth.accessToken != nil,
              self.scope == scope, revision == generation, !isSyncing else { return }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                                           profileId: profile, clientFamily: "apple",
                                           credentialGenerationID: auth.account.credentialGenerationID)
        isSyncing = true
        defer { isSyncing = false; syncProgress = nil }
        status = String(localized: "Syncing…")
        moreWatchlistWork = false
        state.lastAttempt = now
        nextSync = now.addingTimeInterval(Self.routineInterval)
        do {
            try save()
            syncProgress = SimklSyncProgress(step: 1, label: String(localized: "Reading your Simkl library"))
            let (library, libraryChanged) = try await refreshLibrary(scope: scope, generation: generation, auth: auth)
            // Watchlist first: a title is only taken off Plan to Watch while
            // Simkl still shows no history for it.
            try await syncWatchlist(library: library, changed: libraryChanged, scope: scope,
                                    generation: generation, auth: auth, identity: identity)
            syncProgress = SimklSyncProgress(step: 3, label: String(localized: "Sending completed watches"))
            let (unresolved, mismatched) = try await exportCompletions(scope: scope, generation: generation,
                                                                       auth: auth, identity: identity)
            try await validate(scope: scope, revision: generation, auth: auth)
            state.lastSync = Date()
            state.failures = 0
            try save()
            if mismatched > 0 {
                status = String(localized: "Sync finished. Simkl filed \(mismatched) watched items under a different kind of title. Check them on Simkl.")
            } else if unresolved > 0 {
                status = String(localized: "Sync finished. \(unresolved) watched items could not be matched or confirmed and will be retried.")
            } else {
                status = moreWatchlistWork ? String(localized: "This batch is synced. More watchlist changes remain for the next check.") : String(localized: "Watched history and watchlist are synced.")
            }
        } catch is CancellationError {
            if revision == generation { try? save(); status = String(localized: "Connected. Sync paused.") }
        } catch {
            guard revision == generation else { return }
            handle(error, scope: scope)
        }
    }

    private func handle(_ error: Error, scope: String) {
        let failure = error as? SimklFailure
        let now = Date()
        switch failure {
        case .quota(let retryAfter)?:
            state.retryAfter = now.addingTimeInterval(retryAfter ?? SimklClient.secondsUntilQuotaReset(from: now))
        case .suspended?:
            state.retryAfter = now.addingTimeInterval(6 * 3600)
        case .rateLimited?, .writeLocked?:
            nextSync = now.addingTimeInterval(5 * 60)
        case .unauthorised?, .signInExpired?, .missingWriteAccess?:
            endSession(scope: scope, reason: failure == .missingWriteAccess ? .missingWriteAccess : .signInExpired)
            return
        default:
            state.failures += 1
            let backoff = min(2 * 3600, 5 * 60 * pow(2, Double(min(state.failures - 1, 5))))
            nextSync = now.addingTimeInterval(backoff)
        }
        try? save()
        status = failure?.localizedDescription ?? String(localized: "Sync interrupted. It will try again later.")
    }

    /// The grant can't be used any more. The checkpoint stays, so signing
    /// in to the same Simkl account carries on from it.
    private func endSession(scope: String, reason: SimklFailure) {
        guard self.scope == scope else { return }
        try? save()
        _ = keychain.delete(Self.tokenKey(scope))
        tokens = nil
        revision = UUID()
        isConnected = false
        syncProgress = nil
        status = String(localized: "Not connected")
        signInMessage = reason.localizedDescription
    }

    private func refreshLibrary(scope: String, generation: UUID,
                                auth: CapturedOrdinaryRequestAuth) async throws -> ([Int: SimklLibraryItem], Bool) {
        if cache == nil { cache = Self.readCache(scope) }
        if let cached = cache, cached.accountID != state.accountID { cache = nil }
        let current = try await authorised(scope) { try await self.client.activities(token: $0) }
        try await validate(scope: scope, revision: generation, auth: auth)
        guard let saved = cache else {
            // The first read takes the whole library, one type at a time.
            var items: [Int: SimklLibraryItem] = [:]
            if current.all != nil {
                for type in ["movies", "shows", "anime"] {
                    let page = try await authorised(scope) { try await self.client.library(type, dateFrom: nil, token: $0) }
                    try await validate(scope: scope, revision: generation, auth: auth)
                    for item in page { items[item.simkl] = item }
                }
            }
            storeCache(LibraryCache(accountID: state.accountID, activities: current, items: items), scope: scope)
            return (items, true)
        }
        guard current.all != saved.activities.all else { return (saved.items, false) }
        var items = saved.items
        for (domain, type) in SimklActivities.domains.sorted(by: { $0.key < $1.key }) {
            if current.statusesMoved(domain, since: saved.activities) {
                let delta = try await authorised(scope) {
                    try await self.client.library(type, dateFrom: saved.activities.all, token: $0)
                }
                try await validate(scope: scope, revision: generation, auth: auth)
                for item in delta { items[item.simkl] = item }
            }
            // Removals never show up in a delta. Compare the full ID list.
            if current.removalsMoved(domain, since: saved.activities) {
                let present = try await authorised(scope) { try await self.client.libraryIDs(type, token: $0) }
                try await validate(scope: scope, revision: generation, auth: auth)
                let cached = items.values.filter { $0.type == type }.map(\.simkl)
                if let gone = SimklRemovalCheck.removals(cached: cached, present: present) {
                    for simkl in gone { items.removeValue(forKey: simkl) }
                } else {
                    let full = try await authorised(scope) { try await self.client.library(type, dateFrom: nil, token: $0) }
                    try await validate(scope: scope, revision: generation, auth: auth)
                    for simkl in cached { items.removeValue(forKey: simkl) }
                    for item in full { items[item.simkl] = item }
                }
            }
        }
        storeCache(LibraryCache(accountID: state.accountID, activities: current, items: items), scope: scope)
        return (items, true)
    }

    private func syncWatchlist(library: [Int: SimklLibraryItem], changed: Bool, scope: String, generation: UUID,
                               auth: CapturedOrdinaryRequestAuth, identity: HTTPRequestIdentity) async throws {
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
                    guard seen.insert(item.contentId).inserted else { throw SimklFailure.incomplete }
                    items.append(item)
                }
                offset += response.items.count
                let more = response.hasMore ?? (response.total.map { offset < $0 } ?? (response.items.count == 100))
                if !more { return items }
                guard !response.items.isEmpty, page < 99 else { throw SimklFailure.incomplete }
            }
            throw SimklFailure.incomplete
        }
        var details: [String: Target] = [:]
        var missingDetails = Set<String>()
        func target(_ contentID: String) async throws -> Target? {
            try await validateContext()
            if let cached = details[contentID] { return cached }
            if missingDetails.contains(contentID) { return nil }
            do {
                let raw = try await HTTPClient.shared.requestData(method: "GET", path: "/api/v1/catalog/items/\(contentID)",
                    requestIdentity: identity)
                let item = try Self.decoder().decode(ItemDetail.self, from: raw.data)
                try await validateContext()
                let kind: SimklKind
                switch item.type {
                case "movie": kind = .movie
                case "series": kind = .show
                default: missingDetails.insert(contentID); return nil
                }
                let resolved = Target(kind: kind, ids: SimklIDs(tmdb: item.tmdbId, imdb: item.imdbId, tvdb: item.tvdbId))
                details[contentID] = resolved
                return resolved
            } catch HTTPError.http(statusCode: 404, body: _) { missingDetails.insert(contentID); return nil }
        }

        let local = Set(try await catalog(path: "/api/v1/watchlist").map(\.contentId))
        let now = Date()
        let confirmedLocal = Set(state.watchlist.filter { $0.value.local }.keys)
        let fullCheckDue = now >= (state.lastFullWatchlistCheck ?? .distantPast).addingTimeInterval(24 * 3600)
        // Nothing moved on either side: no server lookups and no writes.
        guard changed || local.subtracting(state.skipped) != confirmedLocal || fullCheckDue else { return }
        syncProgress = SimklSyncProgress(step: 2, label: String(localized: "Checking watchlist matches"))

        // Match each watchlist title with its Simkl ID. A title found more
        // than once, or not at all, is left alone.
        var mapped: [String: Int] = [:]
        var targets: [String: Target] = [:]
        var lookedUp: [String: Date] = [:]
        var skipped = Set<String>()
        var lookups = 0
        let tracked = local.union(state.watchlist.filter { $0.value.local || $0.value.remote }.keys).sorted()
        for (index, id) in tracked.enumerated() {
            syncProgress = SimklSyncProgress(step: 2, label: String(localized: "Checking watchlist matches"),
                                             completed: index, total: tracked.count)
            guard let found = try await target(id) else { skipped.insert(id); continue }
            targets[id] = found
            if let known = state.watchlist[id]?.ids.simkl, state.watchlist[id]?.kind == found.kind {
                mapped[id] = known
                continue
            }
            let matches = library.values.filter { $0.kind == found.kind && $0.ids.matches(found.ids) }
            if matches.count == 1 { mapped[id] = matches[0].simkl; continue }
            guard matches.isEmpty, found.ids.hasExternal, lookups < 40 else { continue }
            if let looked = state.watchlist[id]?.lookedUpAt, now.timeIntervalSince(looked) < 7 * 24 * 3600 { continue }
            lookups += 1
            // Not in the library under these IDs. Simkl's own lookup tells a
            // title it doesn't track apart from one it lists under other IDs.
            let resolved = try? await client.resolve(found.ids, kind: found.kind)
            try await validateContext()
            lookedUp[id] = now
            if let resolved { mapped[id] = resolved }
        }
        state.skipped = skipped.intersection(local)

        // Plan to Watch titles Vivid hasn't matched yet are searched for on
        // the server by title, and kept only on an exact ID match.
        let known = Set(mapped.values).union(state.watchlist.values.compactMap(\.ids.simkl))
        let unmatched = library.values.filter { $0.isPlanToWatch && !known.contains($0.simkl) && $0.ids.hasExternal }
            .sorted { $0.simkl < $1.simkl }
        var searches = 0
        for row in unmatched {
            if let searched = state.unmatched[row.simkl], now.timeIntervalSince(searched) < 24 * 3600 { continue }
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            guard searches < 20 else { moreWatchlistWork = true; break }
            searches += 1
            syncProgress = SimklSyncProgress(step: 2, label: String(localized: "Matching \(title)"))
            let candidates = try await catalog(path: "/api/v1/catalog",
                query: ["q": title, "type": row.kind == .movie ? "movie" : "series"])
            // Never choose from a truncated candidate set or a huge ambiguous title.
            var matches: [String: Target] = [:]
            if candidates.count <= 100 {
                for candidate in candidates {
                    if let found = try await target(candidate.contentId), found.kind == row.kind, found.ids.matches(row.ids) {
                        matches[candidate.contentId] = found
                    }
                }
            }
            if matches.count == 1, let match = matches.first, mapped[match.key] == nil {
                targets[match.key] = match.value
                mapped[match.key] = row.simkl
                state.unmatched.removeValue(forKey: row.simkl)
            } else {
                state.unmatched[row.simkl] = now
            }
        }
        state.unmatched = state.unmatched.filter { library[$0.key]?.isPlanToWatch == true }

        // Each title's new baseline. A title with a pending write keeps its
        // old one until the write is confirmed, so a failed write is tried
        // again on the next sync.
        var remoteAdds: [(String, SimklListItem, WatchlistEntry)] = []
        var remoteRemoves: [(String, SimklLibraryItem, WatchlistEntry)] = []
        var localWrites: [(String, Bool, WatchlistEntry)] = []
        var mutations = 0
        var localRemovals = 0
        let mappedCounts = Dictionary(mapped.values.map { ($0, 1) }, uniquingKeysWith: +)
        for (index, entry) in targets.sorted(by: { $0.key < $1.key }).enumerated() {
            let (id, found) = entry
            syncProgress = SimklSyncProgress(step: 2, label: String(localized: "Syncing watchlist changes"),
                                             completed: index, total: targets.count)
            let simkl = mapped[id]
            // Two server titles matched to one Simkl title are left alone.
            if let simkl, mappedCounts[simkl, default: 0] > 1 { continue }
            let remote = simkl.flatMap { library[$0] }
            let previous = state.watchlist[id]
            let isLocal = local.contains(id)
            let action = SimklWatchlistPolicy.action(local: isLocal, remote: remote, mapped: simkl != nil,
                previousLocal: previous?.local, previousRemote: previous?.remote)
            if action != .none {
                // A limited batch bounds the effect of any one sync.
                guard mutations < 32, action != .removeLocal || localRemovals < 10 else { moreWatchlistWork = true; continue }
                mutations += 1
            }
            var ids = found.ids
            ids.simkl = simkl
            var updated = WatchlistEntry(kind: found.kind, ids: ids, local: isLocal,
                                         remote: remote?.isPlanToWatch == true,
                                         lookedUpAt: lookedUp[id] ?? previous?.lookedUpAt)
            switch action {
            case .none:
                state.watchlist[id] = updated
            case .addRemote:
                remoteAdds.append((id, SimklListItem(kind: found.kind, ids: ids), updated))
            case .removeRemote:
                if let remote {
                    updated.local = false
                    remoteRemoves.append((id, remote, updated))
                }
            case .addLocal:
                updated.local = true
                localWrites.append((id, true, updated))
            case .removeLocal:
                localRemovals += 1
                updated.local = false
                localWrites.append((id, false, updated))
            }
        }
        try save()

        // Simkl writes, one batch each. `remote` in each baseline is what
        // Simkl showed before the write; the next library read confirms it.
        if !remoteAdds.isEmpty {
            // A title Simkl can't find comes back in not_found. It isn't
            // offered again until it leaves and rejoins the watchlist.
            _ = try await authorised(scope) { try await self.client.addToPlanToWatch(remoteAdds.map(\.1), token: $0) }
            try await validateContext()
            for (id, _, updated) in remoteAdds { state.watchlist[id] = updated }
            try save()
        }
        if !remoteRemoves.isEmpty {
            _ = try await authorised(scope) { try await self.client.removeFromLibrary(remoteRemoves.map(\.1), token: $0) }
            try await validateContext()
            for (id, _, updated) in remoteRemoves { state.watchlist[id] = updated }
            try save()
        }
        if !localWrites.isEmpty {
            for (id, present, _) in localWrites {
                _ = try await HTTPClient.shared.requestData(method: present ? "PUT" : "DELETE",
                    path: "/api/v1/watchlist/\(id)", requestIdentity: identity)
                try await validateContext()
            }
            ResponseCache.shared.remove(CacheKey.watchlist)
            ResponseCache.shared.invalidateAllItemMetadata()
            watchlistRevision += 1
            // Read the server back. A failed write never moves the baseline.
            syncProgress = SimklSyncProgress(step: 2, label: String(localized: "Verifying watchlist changes"))
            let confirmed = Set(try await catalog(path: "/api/v1/watchlist").map(\.contentId))
            for (id, present, updated) in localWrites where confirmed.contains(id) == present {
                state.watchlist[id] = updated
            }
        }
        state.watchlist = state.watchlist.filter { $0.value.local || $0.value.remote }
        if !moreWatchlistWork { state.lastFullWatchlistCheck = now }
        try save()
    }

    private func exportCompletions(scope: String, generation: UUID, auth: CapturedOrdinaryRequestAuth,
                                   identity: HTTPRequestIdentity) async throws -> (Int, Int) {
        func validateContext() async throws {
            try await validate(scope: scope, revision: generation, auth: auth)
        }
        func detail(_ contentID: String) async throws -> ItemDetail? {
            do {
                let raw = try await HTTPClient.shared.requestData(method: "GET",
                    path: "/api/v1/catalog/items/\(contentID)", requestIdentity: identity)
                let item = try Self.decoder().decode(ItemDetail.self, from: raw.data)
                try await validateContext()
                return item
            } catch HTTPError.http(statusCode: 404, body: _) { return nil }
        }
        func retryLater(_ contentID: String) {
            state.pendingCompletions[contentID]?.attempts += 1
            // A title Simkl or the server never matches isn't retried forever.
            if (state.pendingCompletions[contentID]?.attempts ?? 0) >= 5 {
                state.pendingCompletions.removeValue(forKey: contentID)
            }
        }
        let pending = state.pendingCompletions.sorted { $0.value.watchedAt < $1.value.watchedAt }.prefix(50)
        guard !pending.isEmpty else { return (0, 0) }
        var entries: [SimklHistoryEntry] = []
        var owners: [String] = []
        var series: [String: SimklIDs] = [:]
        var unresolved = 0
        for (index, (contentID, completion)) in pending.enumerated() {
            syncProgress = SimklSyncProgress(step: 3, label: String(localized: "Sending completed watches"),
                                             completed: index, total: pending.count)
            try await validateContext()
            guard let item = try await detail(contentID) else { unresolved += 1; retryLater(contentID); continue }
            guard item.type == "movie" || item.type == "episode" else {
                state.pendingCompletions.removeValue(forKey: contentID)
                continue
            }
            guard item.userData?.played == true else {
                if item.userData?.played == false { state.pendingCompletions.removeValue(forKey: contentID) }
                else { unresolved += 1; retryLater(contentID) }
                continue
            }
            let entry: SimklHistoryEntry?
            if item.type == "movie" {
                let ids = SimklIDs(tmdb: item.tmdbId, imdb: item.imdbId, tvdb: item.tvdbId)
                entry = ids.hasExternal ? SimklHistoryEntry(ids: ids, season: nil, episode: nil, watchedAt: completion.watchedAt) : nil
            } else if let seriesID = item.seriesId, let season = item.seasonNumber, let episode = item.episodeNumber,
                      season >= 0, episode > 0 {
                if series[seriesID] == nil, let show = try await detail(seriesID) {
                    series[seriesID] = SimklIDs(tmdb: show.tmdbId, imdb: show.imdbId, tvdb: show.tvdbId)
                }
                let ids = series[seriesID] ?? SimklIDs()
                entry = ids.hasExternal ? SimklHistoryEntry(ids: ids, season: season, episode: episode, watchedAt: completion.watchedAt) : nil
            } else { entry = nil }
            guard let entry else { unresolved += 1; retryLater(contentID); continue }
            entries.append(entry)
            owners.append(contentID)
        }
        try save()
        guard !entries.isEmpty else { return (unresolved, 0) }
        let result = try await authorised(scope) { try await self.client.addHistory(entries, token: $0) }
        try await validateContext()
        for (index, contentID) in owners.enumerated() {
            if result.accepted.contains(index) {
                state.pendingCompletions.removeValue(forKey: contentID)
                state.exported[contentID] = Date()
            } else {
                unresolved += 1
                retryLater(contentID)
            }
        }
        if state.exported.count > 2000 {
            let keep = state.exported.sorted { $0.value > $1.value }.prefix(2000)
            state.exported = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        try save()
        return (unresolved, result.mismatched.count)
    }

    // MARK: Tokens and requests

    /// Runs one Simkl request with a fresh token, refreshing once if Simkl
    /// turns the token down. Stops before the daily allowance runs out.
    private func authorised<T>(_ scope: String, _ call: (String) async throws -> T) async throws -> T {
        if let remaining = client.requestsRemaining, remaining < Self.quotaFloor {
            throw SimklFailure.quota(retryAfter: SimklClient.secondsUntilQuotaReset(from: Date()))
        }
        guard var current = tokens else { throw SimklFailure.signInRequired }
        if current.expiresAt.timeIntervalSinceNow < 12 * 3600 { current = try await refreshTokens(scope: scope) }
        do { return try await call(current.accessToken) }
        catch SimklFailure.unauthorised {
            return try await call(try await refreshTokens(scope: scope).accessToken)
        }
    }

    private func refreshTokens(scope: String) async throws -> SimklTokens {
        guard let current = tokens else { throw SimklFailure.signInRequired }
        let renewed = try await client.refresh(refreshToken: current.refreshToken)
        guard self.scope == scope, tokens == current else { throw CancellationError() }
        // The old access token has stopped working, so keep the new one
        // even if Keychain refuses it. The refresh token itself is unchanged.
        tokens = renewed
        guard Self.writeTokens(renewed, key: Self.tokenKey(scope), keychain) else { throw SimklFailure.storage }
        return renewed
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
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: Self.checkpointKey(scope))
    }

    private func storeCache(_ value: LibraryCache, scope: String) {
        cache = value
        guard let url = Self.cacheURL(scope), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func readCache(_ scope: String) -> LibraryCache? {
        guard let url = cacheURL(scope), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryCache.self, from: data)
    }

    private static func removeCache(_ scope: String) {
        guard let url = cacheURL(scope) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func readTokens(_ key: String, _ keychain: SharedKeychain) -> SimklTokens? {
        keychain.get(key).flatMap { try? JSONDecoder().decode(SimklTokens.self, from: Data($0.utf8)) }
    }

    private static func writeTokens(_ tokens: SimklTokens, key: String, _ keychain: SharedKeychain) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens), let text = String(data: data, encoding: .utf8) else { return false }
        return keychain.set(text, for: key)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
#endif
