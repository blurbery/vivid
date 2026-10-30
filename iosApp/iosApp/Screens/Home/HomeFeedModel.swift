import Foundation
import Observation

/// Home's rows and their loading, refreshing and error state, plus the
/// card actions that change them.
@Observable @MainActor
final class HomeViewModel {
    var sections: [ResolvedSection] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?
    private(set) var actionError: ErrorState?
    private(set) var lastRefreshFailed = false

    private let dismissContinueWatchingRequest: (_ contentId: String, _ progressUpdatedAt: String) async throws -> Void
    private let dismissNextUpRequest: (_ contentId: String, _ seriesId: String) async throws -> Void
    private let setWatchedRequest: (_ contentId: String, _ played: Bool) async throws -> Void
    private let fetchHomeSections: () async throws -> SectionsResponse

    @ObservationIgnored private var dismissalsInFlight = Set<String>()
    @ObservationIgnored private var watchedUpdatesInFlight = Set<String>()
    @ObservationIgnored private var refreshPending = false
    /// Moves on whenever a running fetch's answer has gone stale.
    @ObservationIgnored private var fetchGeneration = 0
    @ObservationIgnored private var hasEnteredHome = false

    init(
        dismissContinueWatching: @escaping (_ contentId: String, _ progressUpdatedAt: String) async throws -> Void = {
            try await VividAPI.shared.dismissContinueWatchingItem(contentId: $0, progressUpdatedAt: $1)
        },
        dismissNextUp: @escaping (_ contentId: String, _ seriesId: String) async throws -> Void = {
            try await VividAPI.shared.dismissNextUpItem(contentId: $0, seriesId: $1)
        },
        setWatched: @escaping (_ contentId: String, _ played: Bool) async throws -> Void = {
            try await VividAPI.shared.setWatched(contentId: $0, played: $1)
        },
        fetchHomeSections: @escaping () async throws -> SectionsResponse = {
            try await StartupContentPrefetcher.fetchHomeSections()
        }
    ) {
        dismissContinueWatchingRequest = dismissContinueWatching
        dismissNextUpRequest = dismissNextUp
        setWatchedRequest = setWatched
        self.fetchHomeSections = fetchHomeSections

        TVHomeMetadataCache.shared.hydrate()
        if let cached = ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self) {
            HomeSectionPreferences.shared.enforceVisibleRowLimit(in: cached.sections)
            sections = cached.sections.filter { !$0.items.isEmpty }
        }
    }

    var regularSections: [ResolvedSection] {
        sections.filter { !$0.items.isEmpty }
    }

    var isShowingActionError: Bool {
        get { actionError != nil }
        set { if !newValue { actionError = nil } }
    }

    // MARK: Refreshing

    /// Apple TV's rule on coming back to Home: Jellyfin always reloads;
    /// otherwise only the first entry, a return after a minute or more away,
    /// a queued refresh or a showing error does.
    func refreshForHomeEntry(sinceLastHidden hiddenAt: Date?, now: Date = Date(), provider: MediaServerProvider = .active) async {
        let returnIsStale = hiddenAt.map { now.timeIntervalSince($0) >= 60 } ?? false
        guard provider == .jellyfin || !hasEnteredHome || returnIsStale || refreshPending || error != nil else { return }
        await loadSections()
        if !Task.isCancelled, error == nil {
            hasEnteredHome = true
        }
    }

    static func televisionRefreshInterval(provider: MediaServerProvider) -> Duration? {
        switch provider {
        case .jellyfin: .seconds(10)
        case .silo: .seconds(1_800)
        case .emby: nil
        }
    }

    func refreshPlaybackSections(refreshImmediately: Bool = true) async {
        fetchGeneration &+= 1
        refreshPending = true
        if refreshImmediately {
            await loadSections()
        }
    }

    func loadSections() async {
        guard !isLoading, !isRefreshing else { return }
        repeat {
            refreshPending = false
            await loadOnce()
        } while refreshPending
    }

    private func loadOnce() async {
        guard !isLoading, !isRefreshing else { return }
        if sections.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }
        error = nil

        do {
            try await fetchAndApply()
        } catch {
            lastRefreshFailed = true
            guard sections.isEmpty else { return }
            let failure = ErrorState(error)
            guard failure.isTransient else {
                self.error = failure
                return
            }
            do {
                try await Task.sleep(for: .seconds(0.75))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try await fetchAndApply()
            } catch {
                self.error = ErrorState(error)
            }
        }
    }

    private func fetchAndApply() async throws {
        let generation = fetchGeneration
        let response = try await fetchHomeSections()
        lastRefreshFailed = false
        // A playback refresh, dismissal or watched change while this was in
        // flight makes the answer stale.
        guard generation == fetchGeneration else { return }
        HomeSectionPreferences.shared.enforceVisibleRowLimit(in: response.sections)
        let rows = response.sections.filter { !$0.items.isEmpty }
        if rows != sections {
            sections = rows
        }
        error = nil
    }

    // MARK: Card actions

    func dismissContinueWatchingItem(_ item: SectionItem) async {
        let contentId = item.contentId
        let send: () async throws -> Void
        let change: (String, [ResolvedSection]) -> [ResolvedSection]
        if let stamp = item.progressUpdatedAt {
            send = { [dismissContinueWatchingRequest] in try await dismissContinueWatchingRequest(contentId, stamp) }
            change = HomeSectionsMutation.removingContinueWatchingItem(contentId:from:)
        } else if let seriesId = item.seriesId, !seriesId.isEmpty {
            send = { [dismissNextUpRequest] in try await dismissNextUpRequest(contentId, seriesId) }
            change = HomeSectionsMutation.removingNextUpItem(contentId:from:)
        } else {
            return
        }
        guard dismissalsInFlight.insert(contentId).inserted else { return }
        defer { dismissalsInFlight.remove(contentId) }

        actionError = nil
        do {
            try await send()
        } catch {
            actionError = ErrorState(error)
            return
        }
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        fetchGeneration &+= 1
        sections = change(contentId, sections)
        updateCachedSections { change(contentId, $0) }
        TVHomeMetadataCache.shared.store(SectionsResponse(sections: sections))
    }

    @discardableResult
    func setWatched(_ item: SectionItem, played: Bool) async -> Bool {
        let contentId = item.contentId
        guard watchedUpdatesInFlight.insert(contentId).inserted else { return false }
        defer { watchedUpdatesInFlight.remove(contentId) }

        actionError = nil
        do {
            try await setWatchedRequest(contentId, played)
        } catch {
            actionError = ErrorState(error)
            return false
        }
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        fetchGeneration &+= 1
        if played {
            sections = HomeSectionsMutation.removingCompletedItem(contentId: contentId, from: sections)
            updateCachedSections { HomeSectionsMutation.removingCompletedItem(contentId: contentId, from: $0) }
        }
        TVHomeMetadataCache.shared.store(SectionsResponse(sections: sections))
        await refreshPlaybackSections()
        return true
    }

    private func updateCachedSections(_ change: ([ResolvedSection]) -> [ResolvedSection]) {
        ResponseCache.shared.update(CacheKey.homeSections, as: SectionsResponse.self) { response in
            response = SectionsResponse(sections: change(response.sections))
        }
    }
}

/// Removes an item from the rows it no longer belongs in, leaving every
/// other row as it was.
enum HomeSectionsMutation {
    static func removingContinueWatchingItem(contentId: String, from sections: [ResolvedSection]) -> [ResolvedSection] {
        removing(contentId, from: sections, inTypes: ["continue_watching", "in_progress"])
    }

    static func removingNextUpItem(contentId: String, from sections: [ResolvedSection]) -> [ResolvedSection] {
        removing(contentId, from: sections, inTypes: ["continue_watching", "in_progress", "next_up"])
    }

    static func removingCompletedItem(contentId: String, from sections: [ResolvedSection]) -> [ResolvedSection] {
        removing(contentId, from: sections, inTypes: ["continue_watching", "in_progress", "next_up"])
    }

    private static func removing(_ contentId: String, from sections: [ResolvedSection], inTypes types: Set<String>) -> [ResolvedSection] {
        sections.map { section in
            guard types.contains(section.sectionType.lowercased()) else { return section }
            let remaining = section.items.filter { $0.contentId != contentId }
            let removed = section.items.count - remaining.count
            guard removed > 0 else { return section }
            return ResolvedSection(
                id: section.id,
                sectionType: section.sectionType,
                title: section.title,
                featured: section.featured,
                itemLimit: section.itemLimit,
                totalCount: section.totalCount.map { max(0, $0 - removed) },
                isCustom: section.isCustom,
                customized: section.customized,
                items: remaining
            )
        }
    }
}
