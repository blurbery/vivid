import Foundation
import OSLog

/// One other saved profile's titles for the current search, shown as a row
/// under the active profile's results.
struct OtherProfileResults: Identifiable, Equatable {
    let account: TVSavedAccount
    var items: [BrowseItem]

    var id: String { account.id }
}

/// Searches the other saved profiles' libraries without switching to them.
///
/// Every request here is read-only and detached from the active session: it
/// never goes through `HTTPClient.performWithAuthRetry` or `sendScoped`,
/// never writes to `TokenStore`, never posts `.vividSessionExpired`, and a
/// refreshed access token only lives in memory.
enum OtherProfileSearch {
    /// How many titles each other profile's row shows.
    static let rowLimit = 20
    /// How long one profile's search may take before its row is left out.
    /// Each row shows as soon as its profile answers, so a slow server only
    /// delays its own row.
    static let timeout: Duration = .seconds(20)

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "OtherProfileSearch"
    )

    /// Whether Search may look in `account`: not the active profile, signed
    /// in with a saved session, and locked by neither a Vivid PIN nor a Silo
    /// profile PIN. Pure, for tests.
    nonisolated static func isSearchable(
        _ account: TVSavedAccount,
        activeID: String?,
        hasLocalPIN: Bool,
        hasSession: Bool
    ) -> Bool {
        guard account.id != activeID, !account.requiresLogin, hasSession, !hasLocalPIN else { return false }
        // A Silo profile PIN guards that profile's library on the server too,
        // so it stays out until someone enters it by switching.
        return account.pinEnabled != true && account.profile?.hasPin != true
    }

    /// Whether the profile in use may see other profiles' rows. A Silo kids
    /// profile only sees its own library. Its live profile is nil until the
    /// profile list loads, so the saved card's copy stands in, and a Silo
    /// profile known by neither shows no rows. Emby and Jellyfin have no kids
    /// profiles, so they always may. Pure, for tests.
    nonisolated static func allowsOtherProfiles(
        activeProvider: MediaServerProvider?,
        liveProfile: UserProfile?,
        savedProfile: UserProfile?
    ) -> Bool {
        guard let activeProvider else { return false }
        guard activeProvider == .silo else { return true }
        guard let current = liveProfile ?? savedProfile else { return false }
        return !current.isChild && savedProfile?.isChild != true
    }

    /// The saved profiles Search looks in, in their saved order.
    @MainActor
    static func searchableAccounts() -> [TVSavedAccount] {
        searchableAccounts(in: .shared)
    }

    @MainActor
    static func searchableAccounts(in store: TVSavedAccountStore) -> [TVSavedAccount] {
        guard allowsOtherProfiles(
            activeProvider: store.activeAccount.map { MediaServerProvider.forServerID($0.serverID) },
            liveProfile: CurrentProfileStore.shared.profile,
            savedProfile: store.activeAccount?.profile
        ) else { return [] }
        return store.accounts.filter { account in
            let session = store.savedSession(for: account)
            // The card's copy of the profile can be older than the session's.
            guard session?.profile?.hasPin != true else { return false }
            return isSearchable(account, activeID: store.activeID, hasLocalPIN: store.hasPIN(account.id),
                                hasSession: session != nil)
        }
    }

    /// Searches every searchable profile at once, each bounded by `timeout`,
    /// and hands each profile's row to `onRow` as soon as that profile
    /// answers, so a slow server never holds back the others. Profiles that
    /// fail, time out or find nothing never reach `onRow`. Returns when every
    /// profile has answered or timed out, or at once when cancelled.
    @MainActor
    static func searchAll(
        query: String,
        type: String,
        onRow: @escaping @MainActor (OtherProfileResults) -> Void
    ) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Task.isCancelled else { return }
        let store = TVSavedAccountStore.shared
        // Everything the requests need is read here, on the main actor, so
        // the network work never touches the store or the registry.
        let targets = searchableAccounts(in: store).compactMap { account in
            Target(account, store: store).map { (account, $0) }
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: (Int, [BrowseItem]?).self) { group in
            for (index, entry) in targets.enumerated() {
                let target = entry.1
                group.addTask {
                    let items = await Self.firstResult(within: Self.timeout, provider: target.provider) {
                        try await Self.search(target, query: text, type: type, limit: Self.rowLimit)
                    }
                    return (index, items)
                }
            }
            for await (index, items) in group {
                guard !Task.isCancelled else { return }
                guard let items, !items.isEmpty else { continue }
                onRow(OtherProfileResults(account: targets[index].0, items: items))
            }
        }
    }

    // MARK: - One profile

    /// What one saved profile's search needs, read on the main actor.
    struct Target: Sendable, Equatable {
        let accountID: String
        let provider: MediaServerProvider
        let serverURL: String
        let accessToken: String
        let refreshToken: String
        /// The Silo viewing profile, sent as `X-Profile-Id`.
        let profileID: String?
        /// The proof for `profileID`, only when the session holds one for it.
        let profileToken: String?
        /// Emby's or Jellyfin's own user ID.
        let nativeUserID: String?

        @MainActor
        init?(_ account: TVSavedAccount, store: TVSavedAccountStore) {
            guard let session = store.savedSession(for: account), !session.accessToken.isEmpty else { return nil }
            // On Apple TV a server no saved profile is using can be missing
            // from the registry, and its address is in its ID.
            let address = ServerRegistry.shared.entry(with: account.serverID)?.url
                ?? ServerRegistry.address(forServerID: account.serverID)
            guard let address, !address.isEmpty else { return nil }
            self.init(account, session: session, serverURL: address)
        }

        init?(_ account: TVSavedAccount, session: TVSavedAccountSession, serverURL: String) {
            let provider = MediaServerProvider.forServerID(account.serverID)
            switch provider {
            case .silo:
                // The member a bound card always enters, otherwise the one its
                // session restores to, as switching to it would.
                guard let profile = account.siloProfileID ?? session.profile?.id else { return nil }
                profileID = profile
                profileToken = session.profile?.id == profile ? session.profileToken : nil
            case .emby, .jellyfin:
                guard let user = session.nativeUserID, !user.isEmpty else { return nil }
                profileID = nil
                profileToken = nil
            }
            accountID = account.id
            self.provider = provider
            self.serverURL = ServerRegistry.normalize(url: serverURL)
            accessToken = session.accessToken
            refreshToken = session.refreshToken
            nativeUserID = session.nativeUserID
        }
    }

    /// The catalogue query Search sends, without the image-size keys: those
    /// follow the active server's capability, not this one's.
    nonisolated static func catalogQuery(_ query: String, type: String, limit: Int) -> [String: String] {
        ["source": "query", "q": query, "type": type, "limit": String(limit), "offset": "0"]
    }

    static func search(
        _ target: Target,
        query: String,
        type: String,
        limit: Int,
        client: HTTPClient = .shared
    ) async throws -> [BrowseItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let parameters = catalogQuery(text, type: type, limit: limit)
        let items: [BrowseItem]
        switch target.provider {
        case .silo:
            items = try await siloItems(target, query: parameters, client: client)
        case .jellyfin:
            // No captured identity, so a 401 only fails this search: it never
            // retires a token or posts a session expiry.
            let connection = JellyfinConnection(serverURL: target.serverURL, token: target.accessToken,
                                                userID: target.nativeUserID, identity: nil)
            let raw = try await JellyfinAdapter(connection: connection)
                .route(method: "GET", path: "/api/v1/catalog", query: parameters, body: nil)
            items = try JellyfinAdapter.decode(raw, as: CatalogResponse.self).items
        case .emby:
            let connection = EmbyConnection(serverURL: target.serverURL, token: target.accessToken,
                                            userID: target.nativeUserID, identity: nil)
            let raw = try await EmbyAdapter(connection: connection)
                .route(method: "GET", path: "/api/v1/catalog", query: parameters, body: nil)
            items = try EmbyAdapter.decode(raw, as: CatalogResponse.self).items
        }
        try Task.checkCancellation()
        return Array(items.filter { VividMediaType.isSupportedSectionItem($0.type) }.prefix(limit))
    }

    // MARK: - Silo

    /// The catalogue page signed with the profile's own tokens. A 401 gets one
    /// in-memory refresh and one retry; a second 401 just fails the search.
    private static func siloItems(_ target: Target, query: [String: String], client: HTTPClient) async throws -> [BrowseItem] {
        func read(_ token: String) async throws -> Data {
            try await client.getForSavedProfile(serverURL: target.serverURL, path: "/api/v1/catalog", query: query,
                                                accessToken: token, profileID: target.profileID,
                                                profileToken: target.profileToken)
        }
        let token = await RefreshedAccess.shared.token(for: target.accountID, saved: target.accessToken)
        let data: Data
        do {
            data = try await read(token)
        } catch HTTPError.http(let status, _) where status == 401 {
            guard !target.refreshToken.isEmpty,
                  let fresh = try await RefreshedAccess.shared.replacement(
                      for: target.accountID, saved: target.accessToken, rejected: token,
                      renew: { [serverURL = target.serverURL, refreshToken = target.refreshToken] in
                          try await client.refreshedAccessForSavedProfile(serverURL: serverURL, refreshToken: refreshToken)
                      })
            else { throw HTTPError.http(statusCode: 401, body: nil) }
            data = try await read(fresh)
        }
        return try catalogItems(from: data, serverURL: target.serverURL)
    }

    /// Decodes a v1-shaped catalogue reply with every poster and backdrop on
    /// the profile's own server. Artwork views join a relative path to the
    /// active server, so one that can't be made absolute here is dropped.
    nonisolated static func catalogItems(from data: Data, serverURL: String) throws -> [BrowseItem] {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.invalidResponse
        }
        let base = URL(string: ServerRegistry.normalize(url: serverURL))
        if let items = object["items"] as? [[String: Any]] {
            object["items"] = items.map { item in
                var item = item
                for key in artworkKeys {
                    guard let raw = item[key] as? String else { continue }
                    if let resolved = SiloAPICompatibility.artworkURL(raw, relativeTo: base) {
                        item[key] = resolved.absoluteString
                    } else {
                        item.removeValue(forKey: key)
                    }
                }
                return item
            }
        }
        let normalised = try JSONSerialization.data(withJSONObject: object)
        return try HTTPClient.makeJSONDecoder().decode(CatalogResponse.self, from: normalised).items
    }

    private static let artworkKeys = ["poster_url", "backdrop_url", "posterUrl", "backdropUrl"]

    // MARK: - Bounding

    /// A failure's kind and code, with no address, token or title.
    private static func failureSummary(_ error: Error) -> String {
        if let urlError = error as? URLError { return "url=\(urlError.code.rawValue)" }
        if case HTTPError.http(let status, _) = error { return "http=\(status)" }
        return "type=\(String(describing: type(of: error)))"
    }

    /// `operation`'s result, or nil when it fails, takes longer than
    /// `timeout`, or the caller is cancelled. It doesn't wait for the
    /// operation to wind down (a server probe can outlast cancellation), so a
    /// cancelled search returns at once. Every failure is quiet, including a
    /// profile switch cancelling the request mid-flight.
    private static func firstResult<Value: Sendable>(
        within timeout: Duration,
        provider: MediaServerProvider,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let outcome = Outcome<Value?>()
        let work = Task {
            do {
                outcome.finish(try await operation())
            } catch {
                // A cancellation after a timeout or a newer search is expected,
                // so only other failures say what went wrong.
                if !Task.isCancelled {
                    Self.logger.debug("\(provider.rawValue, privacy: .public) search failed \(Self.failureSummary(error), privacy: .public)")
                }
                outcome.finish(nil)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled {
                Self.logger.debug("\(provider.rawValue, privacy: .public) search timed out")
            }
            outcome.finish(nil)
        }
        let value = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            outcome.finish(nil)
        }
        work.cancel()
        timer.cancel()
        return value
    }
}

/// Access tokens refreshed for other saved profiles during this run. They
/// live in memory only, against the saved access token they stand in for, so
/// a profile that is signed in again starts from its new session.
private actor RefreshedAccess {
    static let shared = RefreshedAccess()

    private struct Flight {
        let saved: String
        let id: UUID
        let task: Task<String, Error>
    }

    private var fresh: [String: (saved: String, token: String)] = [:]
    private var flights: [String: Flight] = [:]
    /// Saved sessions whose refresh the server turned down, so each search
    /// doesn't ask again this run.
    private var refused: [String: String] = [:]

    /// The token to try first: one refreshed for this saved session, or the
    /// saved one.
    func token(for accountID: String, saved: String) -> String {
        guard let entry = fresh[accountID], entry.saved == saved else { return saved }
        return entry.token
    }

    /// A newer token after `rejected` was turned down, with one refresh shared
    /// by every search that needs it. Nil when there's nothing newer to try.
    func replacement(
        for accountID: String,
        saved: String,
        rejected: String,
        renew: @escaping @Sendable () async throws -> String
    ) async throws -> String? {
        if let entry = fresh[accountID], entry.saved == saved, entry.token != rejected { return entry.token }
        guard refused[accountID] != saved else { return nil }
        let flight: Flight
        if let current = flights[accountID], current.saved == saved {
            flight = current
        } else {
            // Unstructured, so one waiting search being cancelled can't take
            // the refresh away from the others.
            flight = Flight(saved: saved, id: UUID(), task: Task { try await renew() })
            flights[accountID] = flight
        }
        do {
            let token = try await flight.task.value
            if flights[accountID]?.id == flight.id { flights[accountID] = nil }
            fresh[accountID] = (saved, token)
            return token == rejected ? nil : token
        } catch {
            if flights[accountID]?.id == flight.id { flights[accountID] = nil }
            if case HTTPError.http(let status, _) = error, [400, 401, 403].contains(status) {
                refused[accountID] = saved
            }
            throw error
        }
    }
}

/// A value set once, by whichever of several racers gets there first.
private final class Outcome<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case waiting(CheckedContinuation<Value, Never>?)
        case finished(Value)
    }

    private let lock = NSLock()
    private var state = State.waiting(nil)

    func finish(_ value: Value) {
        lock.lock()
        guard case .waiting(let waiter) = state else {
            lock.unlock()
            return
        }
        state = .finished(value)
        lock.unlock()
        waiter?.resume(returning: value)
    }

    /// Waits for the value. Called once.
    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case .finished(let value):
                lock.unlock()
                continuation.resume(returning: value)
            case .waiting:
                state = .waiting(continuation)
                lock.unlock()
            }
        }
    }
}
