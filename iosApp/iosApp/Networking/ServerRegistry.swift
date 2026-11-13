import Foundation
import OSLog

/// A server the user has added to the device. Its tokens live in Keychain
/// under `id`, never in the entry, and its name is the one the server
/// advertises.
struct ServerEntry: Codable, Identifiable, Equatable, Hashable {
    /// Base64url of the normalised address (see `ServerRegistry.serverId(for:)`),
    /// or a provider-prefixed ID for Emby and Jellyfin. Treated as opaque.
    let id: String

    /// The normalised address: trimmed, with no trailing slash.
    var url: String

    /// The server's advertised name (branding, or the older health name),
    /// filled on first connect and refreshed when the server is activated.
    var fetchedName: String?

    /// When the server was last activated. Only used for sorting.
    var lastUsedAt: Date

    /// The advertised name, or the address without one.
    var displayName: String {
        if let fetchedName, !fetchedName.isEmpty { return fetchedName }
        return url
    }

    /// Only read while moving the older registry's profile into the current
    /// user's launch store. New entries leave it nil, because the server list
    /// is shared between Apple TV users while the profile choice isn't.
    fileprivate(set) var legacyProfileId: String?

    init(id: String, url: String, fetchedName: String?, profileId: String? = nil, lastUsedAt: Date) {
        self.id = id
        self.url = url
        self.fetchedName = fetchedName
        self.lastUsedAt = lastUsedAt
        self.legacyProfileId = profileId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case fetchedName
        case profileId
        case lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        fetchedName = try container.decodeIfPresent(String.self, forKey: .fetchedName)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        legacyProfileId = try container.decodeIfPresent(String.self, forKey: .profileId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(fetchedName, forKey: .fetchedName)
        // Kept only until the profile has been moved and read back, so a
        // move that's interrupted can try again.
        try container.encodeIfPresent(legacyProfileId, forKey: .profileId)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
    }
}

/// The saved registry on iPhone and iPad (and in older Apple TV builds).
private struct RegistryState: Codable {
    var activeServerId: String?
    var entries: [ServerEntry]
}

/// The saved registry on Apple TV, where the active ID is kept separately.
private struct SharedRegistryState: Codable {
    var entries: [ServerEntry]
}

enum ServerRegistryError: LocalizedError {
    case persistenceFailed

    var errorDescription: String? {
        String(localized: "Vivid couldn't save the server list. Please try again.")
    }
}

/// A lock-protected copy of the active server ID for code off the main actor.
private final class ActiveServerIDSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func read() -> String? {
        lock.withLock { value }
    }

    func write(_ newValue: String?) {
        lock.withLock { value = newValue }
    }
}

/// The servers the user has added and which one is active, observed by
/// SwiftUI.
///
/// The registry owns each server's address and name; `TokenStore` owns its
/// tokens. On iPhone and iPad the list and active ID are saved in shared
/// defaults (mirrored to the App Group for Top Shelf). On Apple TV each
/// native user's list is in their own Keychain and the active ID in their
/// defaults. Switching servers writes the active ID and address, then
/// retargets `TokenStore` at the new server's Keychain slot.
@Observable
final class ServerRegistry {
    static let shared = ServerRegistry()

    private let activeServerSnapshot = ActiveServerIDSnapshot()

    /// The active server ID for background code, which can't read the
    /// observable property safely.
    static var activeServerIDSnapshot: String? {
        shared.activeServerSnapshot.read()
    }

    private static let defaultsKey = "vividServerRegistry.v1"
    private static let sharedTVRegistryAccount = "com.blurbery.vivid.serverRegistry.v2"
    private static let currentTVRegistryAccount = "com.blurbery.vivid.serverRegistry.currentUser.v1"

    private struct SavedAccountServerReference: Decodable { let serverID: String }

    /// The servers an Apple TV user's saved accounts (and active server)
    /// use, so moving off the shared legacy registry only takes their own.
    static func ownedLegacyServerIDs(savedAccounts: Data?, activeServerID: String?) -> Set<String> {
        let accounts = savedAccounts.flatMap {
            try? JSONDecoder().decode([SavedAccountServerReference].self, from: $0)
        } ?? []
        var ids = Set(accounts.map(\.serverID))
        if let activeServerID, !activeServerID.isEmpty { ids.insert(activeServerID) }
        return ids
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "ServerRegistry"
    )

    /// Every change goes through `persist()`, so saved and observed state
    /// stay together.
    private(set) var entries: [ServerEntry] = []
    private(set) var activeServerId: String? {
        didSet { activeServerSnapshot.write(activeServerId) }
    }

    private let defaults: SharedDefaults
    private let keychain: SharedKeychain
    private let launchPreferences: ProfileLaunchPreferences
    private let persistenceOverride: (([ServerEntry], String?) -> Bool)?
    private var needsRegistryReadRetry = false
    private var needsProfileMigrationRetry = false

    init(
        defaults: SharedDefaults = .shared,
        keychain: SharedKeychain = SharedKeychain(),
        launchPreferences: ProfileLaunchPreferences = .shared,
        persistenceOverride: (([ServerEntry], String?) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.launchPreferences = launchPreferences
        self.persistenceOverride = persistenceOverride
        load()
        do { try migrateLegacyProfileMappingsIfNeeded() }
        catch { needsProfileMigrationRetry = true }
        activeServerSnapshot.write(activeServerId)
    }

    // MARK: - Reading

    var activeServer: ServerEntry? {
        guard let activeServerId else { return nil }
        return entry(with: activeServerId)
    }

    var activeServerUrl: String { activeServer?.url ?? "" }
    var activeProfileId: String? { defaults.string(forKey: SharedStorage.profileIdKey) }
    var hasActiveServer: Bool { activeServer != nil }

    func entry(with id: String) -> ServerEntry? {
        entries.first { $0.id == id }
    }

    /// The active server first, then most recently used.
    var sortedEntries: [ServerEntry] {
        entries.sorted { a, b in
            if a.id == activeServerId { return true }
            if b.id == activeServerId { return false }
            return a.lastUsedAt > b.lastUsedAt
        }
    }

    // MARK: - Adding and naming

    /// Adds or updates an entry, keeping the saved name when the new entry
    /// has none. `preservingProfile: false` forgets the remembered profile
    /// (the profile itself lives in `ProfileLaunchPreferences`). Nil when it
    /// couldn't be saved, in which case nothing changes.
    @discardableResult
    func addOrUpdate(_ entry: ServerEntry, preservingProfile: Bool = true) -> ServerEntry? {
        let previousEntries = entries
        var merged = entry
        let index = entries.firstIndex { $0.id == entry.id }
        if let index {
            if merged.fetchedName?.isEmpty ?? true { merged.fetchedName = entries[index].fetchedName }
            entries[index] = merged
        } else {
            entries.append(merged)
        }
        guard persist() else {
            entries = previousEntries
            persist()
            // On Apple TV this means the Keychain write failed; otherwise
            // Add Server silently does nothing.
            recordRegistryEvent(phase: "addServer", outcome: "failed", reason: "persistFailed")
            return nil
        }
        // Logged after the host is registered, so no line is written while
        // the redactor doesn't know it yet.
        registerDiagnosticsSensitiveHosts([entry])
        recordRegistryEvent(phase: "addServer", outcome: "succeeded", reason: index == nil ? "addedNew" : "updatedExisting")
        if !preservingProfile {
            launchPreferences.clearRememberedProfile(for: entry.id)
        }
        return merged
    }

    /// Saves a non-empty name the server advertised. False when the server
    /// isn't known or the change couldn't be saved.
    @discardableResult
    func updateFetchedName(for serverId: String, fetchedName: String?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == serverId }) else { return false }
        let previousEntries = entries
        if let fetchedName, !fetchedName.isEmpty { entries[index].fetchedName = fetchedName }
        guard persist() else {
            entries = previousEntries
            persist()
            return false
        }
        return true
    }

    // MARK: - Switching

    /// Makes a server active. The switch runs inside an HTTP identity
    /// transition: outgoing requests are cancelled and caches cleared before
    /// the new server is published, so nothing from the old server lands
    /// afterwards. False when the server is unknown, another transition owns
    /// the client, the task was cancelled or the change couldn't be saved.
    @discardableResult
    func switchTo(serverId: String, resolveDestinationProfile: Bool = false) async -> Bool {
        guard entries.contains(where: { $0.id == serverId }) else {
            Self.logger.error("switchTo called with unknown server id")
            recordRegistryEvent(phase: "switchServer", outcome: "failed", reason: "unknownServer")
            return false
        }
        guard let lease = await HTTPClient.shared.beginIdentityTransition() else {
            // Otherwise the tap appears to do nothing, with no error anywhere.
            recordRegistryEvent(phase: "switchServer", outcome: "failed", reason: "transitionUnavailable")
            return false
        }
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(lease)
            return false
        }
        await HTTPClient.shared.cancelInFlightRequests()
        guard !Task.isCancelled, await commitSwitchTo(serverId: serverId, abortIfCancelled: true) else {
            await HTTPClient.shared.endIdentityTransition(lease)
            return false
        }
        if resolveDestinationProfile, AuthService.shared.isLoggedIn {
            _ = await AuthService.shared.resolveActiveProfileForSession(holding: lease)
        }
        await HTTPClient.shared.endIdentityTransition(lease)
        await resetServerScopedFeatures()
        return true
    }

    /// Commits a switch while the caller already holds the transition lease.
    /// Sign-in uses this to publish its new tokens, defaults and active
    /// server with no gap in between.
    @discardableResult
    func commitSwitchTo(serverId: String, holding transitionLease: HTTPIdentityTransitionLease) async -> Bool {
        guard entries.contains(where: { $0.id == serverId }),
              await HTTPClient.shared.isIdentityTransitionActive(transitionLease)
        else {
            Self.logger.error("gated switchTo called without its identity transition")
            recordRegistryEvent(phase: "switchServer", outcome: "failed", reason: "staleTransitionLease")
            return false
        }
        // Sign-in has already written the new credentials under this lease,
        // so finish even if cancelled now: stopping would leave the old
        // server routed with the new credentials.
        return await commitSwitchTo(serverId: serverId, abortIfCancelled: false)
    }

    /// Writes the server change while requests are paused, rolling it back
    /// if it can't be saved.
    @discardableResult
    private func commitSwitchTo(serverId: String, abortIfCancelled: Bool) async -> Bool {
        guard let entry = entry(with: serverId) else {
            Self.logger.error("switchTo target was removed while waiting for transition")
            return false
        }
        await AuthService.shared.clearCachesForServerChange()
        if abortIfCancelled, Task.isCancelled { return false }

        let snapshot = routingSnapshot()
        mirror(entry)
        activeServerId = serverId
        if let index = entries.firstIndex(where: { $0.id == serverId }) {
            entries[index].lastUsedAt = Date()
        }
        guard persist() else {
            restore(snapshot)
            // The old server is still active, so the failure is logged here;
            // the transition gate stops a diagnostics line being recorded.
            Self.logger.error("switchTo failed to persist the destination server")
            return false
        }
        await TokenStore.shared.switchActiveServer(serverId: serverId)
        return true
    }

    /// Signs out of a server without removing it: its tokens and remembered
    /// profile go, its address and name stay.
    func signOut(serverId: String) async {
        await TokenStore.shared.deleteTokens(for: serverId)
        launchPreferences.clearRememberedProfile(for: serverId)
        // Checked after the awaits: if another server became active
        // meanwhile, its profile selection mustn't be cleared.
        let signsOutActiveServer = serverId == activeServerId
        if signsOutActiveServer {
            defaults.removeObject(forKey: SharedStorage.profileIdKey)
        }
        recordRegistryEvent(phase: "signOutServer", outcome: "succeeded", reason: signsOutActiveServer ? "activeServer" : "otherServer")
    }

    /// Removes a saved server, its tokens and remembered profile. Removing
    /// the active server makes the most recently used one active (or none),
    /// inside an identity transition like `switchTo`.
    @discardableResult
    func remove(serverId: String, resolveFallbackProfile: Bool = false) async -> Bool {
        guard let lease = await HTTPClient.shared.beginIdentityTransition() else {
            recordRegistryEvent(phase: "removeServer", outcome: "failed", reason: "transitionUnavailable")
            return false
        }
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(lease)
            recordRegistryEvent(phase: "removeServer", outcome: "cancelled", reason: "taskCancelled")
            return false
        }
        guard entries.contains(where: { $0.id == serverId }) else {
            await HTTPClient.shared.endIdentityTransition(lease)
            recordRegistryEvent(phase: "removeServer", outcome: "failed", reason: "unknownServer")
            return false
        }
        let removesActiveServer = activeServerId == serverId
        // Removing the active server can't be recorded once the gate is
        // closed, so those failures are logged instead.
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(lease)
            if removesActiveServer {
                Self.logger.error("removeServer cancelled before removing the server")
            } else {
                recordRegistryEvent(phase: "removeServer", outcome: "cancelled", reason: "taskCancelledBeforeRemoval")
            }
            return false
        }
        if removesActiveServer {
            // Stop the old server's responses and clear every cache before
            // the fallback is published.
            await HTTPClient.shared.cancelInFlightRequests()
            await AuthService.shared.clearCachesForServerChange()
            guard !Task.isCancelled else {
                await HTTPClient.shared.endIdentityTransition(lease)
                Self.logger.error("removeServer cancelled after clearing caches")
                return false
            }
        }

        let snapshot = routingSnapshot()
        entries.removeAll { $0.id == serverId }
        if removesActiveServer {
            let fallback = entries.sorted { $0.lastUsedAt > $1.lastUsedAt }.first
            mirror(fallback)
            activeServerId = fallback?.id
        }
        guard persist() else {
            restore(snapshot)
            await HTTPClient.shared.endIdentityTransition(lease)
            if removesActiveServer {
                Self.logger.error("removeServer failed to persist the removal")
            } else {
                recordRegistryEvent(phase: "removeServer", outcome: "failed", reason: "persistFailed")
            }
            return false
        }

        if removesActiveServer {
            await TokenStore.shared.switchActiveServer(serverId: activeServerId ?? "")
        } else {
            recordRegistryEvent(phase: "removeServer", outcome: "succeeded", reason: "otherServer")
        }
        await TokenStore.shared.deleteTokens(for: serverId)
        launchPreferences.clearRememberedProfile(for: serverId)
        if removesActiveServer, resolveFallbackProfile, AuthService.shared.isLoggedIn {
            _ = await AuthService.shared.resolveActiveProfileForSession(holding: lease)
        }
        await HTTPClient.shared.endIdentityTransition(lease)
        if removesActiveServer { await resetServerScopedFeatures() }
        return true
    }

    /// Drops the old server's feature checks and cached profile once the
    /// address, profile, active ID and token slot all point at the new
    /// server, then checks again. A switch between signed-in servers can
    /// keep the session authenticated, so nothing else would trigger the
    /// checks before the next foreground.
    private func resetServerScopedFeatures() async {
        await MainActor.run {
            ImageSizeCapability.shared.reset()
            RequestsFeatureStore.shared.reset()
            CurrentProfileStore.shared.reset()
            RequestsEventBus.shared.reset()
            Task { await RequestsFeatureStore.shared.refresh() }
            Task { await CurrentProfileStore.shared.refresh() }
            Task { await ImageSizeCapability.shared.refresh() }
        }
    }

    // MARK: - Routing defaults

    /// The registry and the routing defaults, so a change that can't be
    /// saved can be put back.
    private struct RoutingSnapshot {
        let entries: [ServerEntry]
        let activeServerId: String?
        let serverURL: String?
        let mirroredServerID: String?
        let profileID: String?
    }

    private func routingSnapshot() -> RoutingSnapshot {
        RoutingSnapshot(
            entries: entries,
            activeServerId: activeServerId,
            serverURL: defaults.string(forKey: SharedStorage.serverUrlKey),
            mirroredServerID: defaults.string(forKey: SharedStorage.activeServerIdKey),
            profileID: defaults.string(forKey: SharedStorage.profileIdKey)
        )
    }

    private func restore(_ snapshot: RoutingSnapshot) {
        entries = snapshot.entries
        activeServerId = snapshot.activeServerId
        persist()
        defaults.set(snapshot.serverURL, forKey: SharedStorage.serverUrlKey)
        defaults.set(snapshot.mirroredServerID, forKey: SharedStorage.activeServerIdKey)
        defaults.set(snapshot.profileID, forKey: SharedStorage.profileIdKey)
    }

    /// Points the routing defaults at `entry` (or clears them) and drops the
    /// previous server's profile selection. Written before the observable
    /// active ID changes, so views reacting to it read matching defaults.
    private func mirror(_ entry: ServerEntry?) {
        if let entry {
            defaults.set(entry.url, forKey: "serverUrl")
            defaults.set(entry.id, forKey: SharedStorage.activeServerIdKey)
        } else {
            defaults.removeObject(forKey: "serverUrl")
            defaults.removeObject(forKey: SharedStorage.activeServerIdKey)
        }
        defaults.removeObject(forKey: SharedStorage.profileIdKey)
    }

    // MARK: - Addresses

    /// The registry key for an address. The exact normalised spelling is
    /// kept, because this value already scopes credentials and local data.
    static func serverId(for url: String) -> String {
        Data(normalize(url: url).utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The address to keep when a profile form switches to `provider`: a
    /// saved server of another type is swapped for the most recent saved
    /// server of this type, or cleared. A typed address is kept as entered.
    func address(_ input: String, keptFor provider: MediaServerProvider) -> String {
        let normalized = normalizedUserAddress(input)
        guard let saved = entries.first(where: { $0.url == normalized }),
              MediaServerProvider.forServerID(saved.id) != provider
        else { return input }
        return sortedEntries.first { MediaServerProvider.forServerID($0.id) == provider }?.url ?? ""
    }

    /// Normalises an address the user typed or pasted. Schemes and host names
    /// are case-insensitive but sign-in checks and server IDs aren't, so
    /// `Https://Media.Example.com` is lowercased to avoid a separate server.
    /// The path keeps its case, since reverse proxies can treat it as
    /// case-sensitive. An address matching a saved server reuses that
    /// server's stored spelling, so its ID and saved accounts stay the same.
    func normalizedUserAddress(_ input: String) -> String {
        let trimmed = Self.normalize(url: input)
        guard var components = URLComponents(string: trimmed), components.host != nil else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        guard let lowered = components.string else { return trimmed }
        let candidate = Self.normalize(url: lowered)
        // Addresses are compared rather than IDs: Emby and Jellyfin IDs carry
        // a provider prefix that can't be turned back into an address.
        if let canonical = Self.canonicalComparisonURL(for: candidate),
           let saved = entries.first(where: { Self.canonicalComparisonURL(for: $0.url) == canonical }) {
            return saved.url
        }
        return candidate
    }

    /// Trimmed, with trailing slashes removed.
    static func normalize(url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    /// An http or https address with its scheme and host lowercased and a
    /// default port dropped, for comparing addresses.
    private static func canonicalComparisonURL(for url: String) -> String? {
        guard var components = URLComponents(string: normalize(url: url)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.string
    }

    // MARK: - Persistence

    /// Tries again what a locked Keychain stopped at launch: reading the
    /// Apple TV registry, then moving older profile selections.
    func retryInitialRegistryReadIfNeeded() throws {
        #if os(tvOS)
        if needsRegistryReadRetry {
            try loadTVRegistry()
            needsRegistryReadRetry = false
            needsProfileMigrationRetry = true
        }
        #endif
        if needsProfileMigrationRetry {
            try migrateLegacyProfileMappingsIfNeeded()
            needsProfileMigrationRetry = false
        }
    }

    #if os(tvOS)
    /// Reads the current Apple TV user's registry from their Keychain. Older
    /// installs move in from the per-user defaults, or from the registry once
    /// shared by every Apple TV user, taking only the servers this user's
    /// saved accounts use. A Keychain that can't be read throws, so nothing
    /// is erased or moved while it's locked.
    private func loadTVRegistry() throws {
        let currentKeychain = keychain.withAudience(.currentUser)
        let legacyKeychain = keychain.withAudience(.userIndependent)
        if let encoded = try currentKeychain.getChecked(Self.currentTVRegistryAccount),
           let data = encoded.data(using: .utf8),
           let state = try? JSONDecoder().decode(SharedRegistryState.self, from: data) {
            entries = state.entries
            activeServerId = defaults.string(forKey: SharedStorage.activeServerIdKey)
        } else if let data = defaults.data(forKey: Self.defaultsKey),
                  let legacy = try? JSONDecoder().decode(RegistryState.self, from: data) {
            entries = legacy.entries
            activeServerId = legacy.activeServerId
            persist()
        } else if let encoded = try legacyKeychain.getChecked(Self.sharedTVRegistryAccount),
                  let data = encoded.data(using: .utf8),
                  let state = try? JSONDecoder().decode(SharedRegistryState.self, from: data) {
            activeServerId = defaults.string(forKey: SharedStorage.activeServerIdKey)
            let owned = Self.ownedLegacyServerIDs(
                savedAccounts: defaults.data(forKey: "vivid.accounts.v1"),
                activeServerID: activeServerId
            )
            entries = state.entries.filter { owned.contains($0.id) }
            if !entries.isEmpty { persist() }
        }
        if activeServerId == nil || !entries.contains(where: { $0.id == activeServerId }) {
            activeServerId = entries.sorted { $0.lastUsedAt > $1.lastUsedAt }.first?.id
        }
        registerDiagnosticsSensitiveHosts(entries)
        mirrorActiveServer()
    }
    #endif

    private func load() {
        #if os(tvOS)
        do { try loadTVRegistry() }
        catch { needsRegistryReadRetry = true }
        #else
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            let state = try JSONDecoder().decode(RegistryState.self, from: data)
            entries = state.entries
            activeServerId = state.activeServerId
            registerDiagnosticsSensitiveHosts(state.entries)
        } catch {
            Self.logger.error("Registry decode failed: \(error.localizedDescription, privacy: .public). Starting empty.")
            return
        }
        // `SharedDefaults` reads fall back to the standard defaults, but Top
        // Shelf only sees the App Group suite, so the first launch after an
        // upgrade saves the registry there too.
        if defaults.suite.data(forKey: Self.defaultsKey) == nil {
            persist()
            if let activeServer {
                defaults.set(activeServer.url, forKey: SharedStorage.serverUrlKey)
            }
        }
        #endif
    }

    /// A registry change for diagnostics. An entry is an address, a name and
    /// an ID that is base64 of the address, so none of them are logged: only
    /// the change and its outcome.
    private func recordRegistryEvent(phase: String, outcome: String, reason: String) {
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(
            .essential,
            category: .lifecycle,
            tag: "Servers",
            message: "server registry changed",
            attrs: [
                "phase": .string(phase),
                "outcome": .string(outcome),
                "reason": .string(reason),
            ]
        )
        #endif
    }

    /// Every saved server's host, not just the active one's, is hashed in
    /// diagnostics lines.
    private func registerDiagnosticsSensitiveHosts(_ entries: [ServerEntry]) {
        #if os(iOS) || os(tvOS)
        for entry in entries {
            if let host = URL(string: entry.url)?.host {
                DiagLog.registerSensitiveHost(host)
            }
        }
        #endif
    }

    /// Saves the registry and reads it back. On Apple TV the list goes in the
    /// current user's Keychain and the active ID in their defaults, and the
    /// older defaults copy is removed.
    @discardableResult
    private func persist() -> Bool {
        if let persistenceOverride, !persistenceOverride(entries, activeServerId) {
            return false
        }
        #if os(tvOS)
        do {
            let data = try JSONEncoder().encode(SharedRegistryState(entries: entries))
            guard let encoded = String(data: data, encoding: .utf8) else { return false }
            let currentKeychain = keychain.withAudience(.currentUser)
            guard currentKeychain.set(encoded, for: Self.currentTVRegistryAccount),
                  currentKeychain.get(Self.currentTVRegistryAccount) == encoded else { return false }
            defaults.removeObject(forKey: Self.defaultsKey)
            if let activeServerId {
                defaults.set(activeServerId, forKey: SharedStorage.activeServerIdKey)
                return defaults.string(forKey: SharedStorage.activeServerIdKey) == activeServerId
            }
            defaults.removeObject(forKey: SharedStorage.activeServerIdKey)
            return defaults.string(forKey: SharedStorage.activeServerIdKey) == nil
        } catch {
            Self.logger.error("Registry encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #else
        do {
            let data = try JSONEncoder().encode(RegistryState(activeServerId: activeServerId, entries: entries))
            defaults.set(data, forKey: Self.defaultsKey)
            return defaults.data(forKey: Self.defaultsKey) == data
        } catch {
            Self.logger.error("Registry encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #endif
    }

    private func mirrorActiveServer() {
        guard let active = activeServer else {
            defaults.removeObject(forKey: SharedStorage.serverUrlKey)
            defaults.removeObject(forKey: SharedStorage.activeServerIdKey)
            return
        }
        defaults.set(active.url, forKey: SharedStorage.serverUrlKey)
        defaults.set(active.id, forKey: SharedStorage.activeServerIdKey)
    }

    /// Moves the older registry's profile ID into the current user's launch
    /// store. The old field stays saved until the new mapping and the account
    /// epoch can be read back, so an interrupted move tries again. A Keychain
    /// that can't be read throws and keeps the old field.
    private func migrateLegacyProfileMappingsIfNeeded() throws {
        let accountKeychain = keychain.withAudience(SharedStorage.accountCredentialAudience)
        let profileKeychain = keychain.withAudience(.currentUser)
        for index in entries.indices {
            guard let profileID = entries[index].legacyProfileId, !profileID.isEmpty else { continue }
            let serverID = entries[index].id
            let accessKey = TokenStore.accessTokenKey(for: serverID)
            let epochKey = TokenStore.accountEpochKey(for: serverID)

            guard try accountKeychain.getChecked(accessKey) != nil else {
                // A signed-out entry has no account to bind the profile to.
                entries[index].legacyProfileId = nil
                if !persist() { entries[index].legacyProfileId = profileID }
                continue
            }

            let accountEpoch: String
            if let existing = try accountKeychain.getChecked(epochKey), !existing.isEmpty {
                accountEpoch = existing
            } else {
                let generated = UUID().uuidString
                guard accountKeychain.set(generated, for: epochKey),
                      try accountKeychain.getChecked(epochKey) == generated else { continue }
                accountEpoch = generated
            }

            let requiresPIN = try profileKeychain.getChecked(TokenStore.profileTokenKey(for: serverID)) != nil
            guard launchPreferences.migrateLegacyProfile(
                profileID: profileID,
                requiresPIN: requiresPIN,
                accountEpoch: accountEpoch,
                for: serverID
            ) else { continue }
            entries[index].legacyProfileId = nil
            if !persist() { entries[index].legacyProfileId = profileID }
        }
    }
}
