import Foundation

/// The shared fetches behind launch, sign-in and the first screens: the
/// profile list, Home, the user's libraries and Browse's first page. Every
/// caller asking while one is running shares it. A reset that covers a fetch
/// makes its waiting callers throw `CancellationError`, even when the request
/// itself succeeds.
@MainActor
enum StartupContentPrefetcher {
    private static let profileFetches = SharedFetches<[UserProfile]>()
    private static let homeFetches = SharedFetches<SectionsResponse>()
    private static let libraryFetches = SharedFetches<LibrariesResponse>()
    private static let browseFetches = SharedFetches<CatalogResponse>()

    /// Bumped by each kind of reset. A caller compares them with the values
    /// it saw when it called.
    private struct Generations {
        var all = 0
        var profile = 0
        var home = 0
    }

    private static var generations = Generations()

    /// The resets that cut a fetch off.
    private enum ResetScope {
        case all
        case profile
        case home

        func cutsOff(from start: Generations, to now: Generations) -> Bool {
            switch self {
            case .all: now.all != start.all
            case .profile: now.profile != start.profile
            case .home: now.profile != start.profile || now.home != start.home
            }
        }
    }

    // MARK: Resets

    static func resetProfileScopedPrefetches() {
        generations.profile += 1
        homeFetches.cancelAll()
        libraryFetches.cancelAll()
        browseFetches.cancelAll()
        TVHomeMetadataCache.shared.deactivate()
    }

    static func resetAllPrefetches() {
        generations.all += 1
        profileFetches.cancelAll()
        resetProfileScopedPrefetches()
    }

    static func invalidateHomeSectionsInFlight() {
        generations.home += 1
        homeFetches.cancelAll()
    }

    /// Made before a playback or watched-state write and called after it.
    /// Does nothing once a profile-scoped reset has happened in between.
    static func homeRefreshAfterPlaybackWrite() -> @MainActor () -> Void {
        let profileGeneration = generations.profile
        return {
            guard generations.profile == profileGeneration else { return }
            invalidateHomeSectionsInFlight()
            ResponseCache.shared.remove(CacheKey.homeSections)
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        }
    }

    // MARK: Fetches

    static func fetchProfiles() async throws -> [UserProfile] {
        let profiles = try await joinFetch(profileFetches, scope: .all, phase: "profiles") {
            try await AuthService.shared.getProfiles()
        }
        ResponseCache.shared.set(profiles, for: CacheKey.profiles)
        await AuthService.shared.reconcileAvailableProfiles(profiles)
        warmAvatarArtwork(profiles)
        return profiles
    }

    static func fetchHomeSections() async throws -> SectionsResponse {
        let requestProfile = AuthService.shared.profileId
        let response: SectionsResponse
        do {
            response = try await joinFetch(homeFetches, scope: .home, phase: "home_sections") {
                try await VividAPI.shared.homeSections()
            }
        } catch {
            if let requestProfile {
                if indicatesInvalidProfile(error) {
                    await AuthService.shared.recoverFromInvalidProfile(expectedProfileID: requestProfile)
                } else if mayIndicateRemovedProfile(error) {
                    _ = try? await fetchProfiles()
                }
            }
            throw error
        }

        let capped = TVHomeMetadataCache.capped(response)
        ResponseCache.shared.set(capped, for: CacheKey.homeSections)
        TVHomeMetadataCache.shared.store(capped)
        let seriesRowItems = capped.sections
            .filter { HomeSeriesBackdrops.applies(toSectionType: $0.sectionType) }
            .flatMap(\.items)
        if !seriesRowItems.isEmpty {
            HomeSeriesBackdrops.shared.prepare(seriesRowItems)
        }
        warmHomeArtwork(HomeSectionPreferences.shared.arrangedSections(capped.sections))
        return capped
    }

    static func fetchUserLibraries() async throws -> LibrariesResponse {
        let response = try await joinFetch(libraryFetches, scope: .profile, phase: "user_libraries") {
            try await VividAPI.shared.libraries()
        }
        ResponseCache.shared.set(response, for: CacheKey.userLibraries)
        TVHomeMetadataCache.shared.storeLibraries(response)
        NotificationCenter.default.post(name: .userLibrariesDidRefresh, object: response)
        return response
    }

    /// Browse's first page, asked for exactly as the live Browse page asks,
    /// so both share one cache entry.
    static func fetchBrowseFirstPage(libraryId: Int?, state: CatalogFilterState = .none) async throws -> CatalogResponse {
        let key = CacheKey.browse(libraryId: libraryId, filterKey: state.cacheKeyFragment)
        let query = CatalogQueryBuilder.build(
            state, libraryId: libraryId, mediaType: .movie, offset: 0, limit: 60, includeType: false
        )
        let response = try await joinFetch(
            browseFetches, key: key, scope: .profile, phase: "browse_first_page", verbosity: .verbose
        ) {
            try await VividAPI.shared.catalog(query: query)
        }
        ResponseCache.shared.set(response, for: key)
        warmBrowseArtwork(response)
        return response
    }

    /// Gets the Home snapshot ready and starts the signed-in fetches. False
    /// when the task was cancelled or a profile-scoped reset happened while
    /// the snapshot was being prepared.
    static func prefetchAuthenticatedContent() async -> Bool {
        let start = generations
        await TVHomeMetadataCache.shared.prepare()
        guard !Task.isCancelled, !ResetScope.profile.cutsOff(from: start, to: generations) else { return false }
        TVHomeMetadataCache.shared.hydrate()
        Task(priority: .utility) { await StudiosNetworksStore.shared.loadIfNeeded() }
        Task(priority: .utility) { await HomeCollectionsStore.shared.loadIfNeeded() }
        Task { _ = try? await fetchHomeSections() }
        Task { _ = await OverlayPrefsStore.shared.hydrateIfNeeded() }
        return true
    }

    /// The work the first route needs before it shows. False when the task
    /// was cancelled.
    static func prefetchForInitialRoute(_ state: AppRouter.AuthState) async -> Bool {
        DiagTrace.breadcrumb(
            .essential, category: .lifecycle, tag: "Startup", message: "route prefetch started",
            attrs: ["phase": .string("prefetch"), "state": .string(state.diagnosticsState)]
        )
        switch state {
        case .authenticated:
            guard await prefetchAuthenticatedContent() else { return false }
            Task { _ = try? await fetchProfiles() }
        case .needsProfile:
            Task { _ = try? await fetchProfiles() }
        case .loading, .needsServerSetup, .needsLogin:
            break
        }
        return !Task.isCancelled
    }

    // MARK: Errors

    nonisolated static func indicatesInvalidProfile(_ error: Error) -> Bool {
        guard let code = (error as? HTTPError)?.serverErrorCode else { return false }
        return code == "profile_unverified" || code == "profile_not_found"
    }

    nonisolated static func mayIndicateRemovedProfile(_ error: Error) -> Bool {
        guard let httpError = error as? HTTPError else { return false }
        return httpError.statusCode == 404 && httpError.serverErrorCode == "not_found"
    }

    /// The `reason` a failed fetch reports.
    nonisolated static func failureReason(for error: Error) -> String {
        if isCancellation(error) { return "cancelled" }
        guard let httpError = error as? HTTPError else {
            return (error as NSError).domain == NSURLErrorDomain ? "network" : "other"
        }
        if indicatesInvalidProfile(httpError) { return "invalid_profile" }
        switch httpError {
        case .serverUrlNotConfigured:
            return "no_server"
        case .requestIdentityChanged:
            return "identity_changed"
        case .network(let underlying):
            return isCancellation(underlying) ? "cancelled" : "network"
        case .decodingFailed:
            return "decode_failed"
        case .http(let statusCode, _):
            if statusCode == 401 || statusCode == 403 { return "unauthorized" }
            if (500...599).contains(statusCode) { return "server_error" }
            return "http_\(statusCode / 100)xx"
        case .invalidURL, .invalidResponse, .encodingFailed:
            return "other"
        }
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: Sharing

    /// Joins the fetch in flight for `key` or starts it, then applies the
    /// reset rules. Only the caller that started the request records it.
    private static func joinFetch<Value>(
        _ fetches: SharedFetches<Value>,
        key: String = "",
        scope: ResetScope,
        phase: String,
        verbosity: DiagnosticsVerbosity = .essential,
        request: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let calledAt = DispatchTime.now()
        let start = generations
        let (task, started) = fetches.join(key, request: request)
        var result = await task.result
        if scope.cutsOff(from: start, to: generations) {
            result = .failure(CancellationError())
        }
        if started {
            recordFetch(phase: phase, verbosity: verbosity, since: calledAt, error: result.failure)
        }
        return try result.get()
    }

    private static func recordFetch(phase: String, verbosity: DiagnosticsVerbosity, since mark: DispatchTime, error: Error?) {
        let reason = error.map(failureReason(for:))
        let outcome = reason == nil ? "success" : reason == "cancelled" ? "cancelled" : "failure"
        var attrs: [String: DiagLogAttributeValue] = [
            "phase": .string(phase),
            "duration_ms": .int(LaunchTimeline.milliseconds(since: mark)),
            "outcome": .string(outcome),
        ]
        if let reason { attrs["reason"] = .string(reason) }
        DiagTrace.breadcrumb(
            verbosity, level: outcome == "failure" ? .warning : .info,
            category: .lifecycle, tag: "Startup", message: "prefetch finished", attrs: attrs
        )
    }
}

extension Notification.Name {
    static let userLibrariesDidRefresh = Notification.Name("userLibrariesDidRefresh")
}

/// One request per key at a time. A request stops being shared the moment it
/// ends, so the next caller starts a fresh one.
@MainActor
private final class SharedFetches<Value> {
    private var flights: [String: (id: UUID, task: Task<Value, Error>)] = [:]

    func join(_ key: String, request: @escaping @MainActor () async throws -> Value) -> (task: Task<Value, Error>, started: Bool) {
        if let flight = flights[key] { return (flight.task, false) }
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.finish(key, id: id) }
            return try await request()
        }
        flights[key] = (id, task)
        return (task, true)
    }

    func cancelAll() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    private func finish(_ key: String, id: UUID) {
        if flights[key]?.id == id { flights[key] = nil }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
