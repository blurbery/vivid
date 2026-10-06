import Foundation

/// Device-local, per-server/profile Home row visibility and order. The server
/// remains authoritative for which rows exist and what they contain; this
/// projection only arranges the rows it returns. Unknown/new server rows append
/// in server order, subject to the shared Home visible-row limit. Only rows
/// this layout has never seen can be hidden by that limit; a row that has
/// already been shown stays visible until the user hides it.
@Observable
@MainActor
final class HomeSectionPreferences {
    static let shared = HomeSectionPreferences()

    // Seven Home slots, with one always reserved for Spotlight, even when hidden.
    static let maximumVisibleRows = 6
    @ObservationIgnored private var knownSections: [ResolvedSection] = []

    var visibleRowCount: Int {
        arrangedSections(knownSections, includingHidden: true).filter { isVisible($0.id) }.count
    }

    /// Hide newly appearing rows that would exceed the limit, keeping their
    /// definitions and order. Rows already seen are never hidden here, so a
    /// refresh that adds, removes or reorders rows cannot switch off rows that
    /// were showing. Spotlight reads its sources independently of this preference.
    func enforceVisibleRowLimit(in sections: [ResolvedSection]) {
        refresh()
        // Another device or Settings may have saved this layout since it was
        // loaded; build on that version so this save cannot overwrite it.
        reloadIfStoredLayoutChanged()
        knownSections = sections
        let arranged = arrangedSections(sections, includingHidden: true)
        let newRows = arranged.filter { !seenSectionIds.contains($0.id) }
        let seenVisibleCount = arranged.filter {
            seenSectionIds.contains($0.id) && isVisible($0.id)
        }.count
        let capacity = max(0, Self.maximumVisibleRows - seenVisibleCount)
        let overflow = newRows.filter { isVisible($0.id) }.dropFirst(capacity).map(\.id)
        let unseen = Set(arranged.map(\.id)).subtracting(seenSectionIds)
        guard !overflow.isEmpty || !unseen.isEmpty || needsMigrationSave else { return }
        seenSectionIds.formUnion(unseen)
        needsMigrationSave = false
        if !overflow.isEmpty {
            hiddenSectionIds.formUnion(overflow)
            layoutRevision &+= 1
        }
        persist()
    }

    /// Combining or separating Next Up changes which rows occupy slots, so this
    /// explicit setting change hides any enabled rows beyond the limit.
    private func hideRowsBeyondLimit() {
        let overflow = arrangedSections(knownSections, includingHidden: true)
            .filter { isVisible($0.id) }.dropFirst(Self.maximumVisibleRows)
        hiddenSectionIds.formUnion(overflow.map(\.id))
    }

    private(set) var orderedSectionIds: [String] = []
    private(set) var hiddenSectionIds = Set<String>()
    /// Rows this layout has already arranged. Only rows outside this set can be
    /// hidden automatically by the visible-row limit.
    @ObservationIgnored private var seenSectionIds = Set<String>()
    /// An old-format layout was reset in memory and still needs saving.
    @ObservationIgnored private var needsMigrationSave = false
    /// Changes only for explicit preference/layout transitions—not ordinary
    /// Home data refreshes—so Home can reset its row band and marquee once.
    private(set) var layoutRevision = 0
    private(set) var combineEmbyNextUp = false
    private(set) var combineJellyfinNextUp = false

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let storageKey: @MainActor () -> String?
    @ObservationIgnored private var loadedStorageKey: String?
    /// The stored bytes the in-memory layout was last loaded from or saved as.
    @ObservationIgnored private var loadedData: Data?

    private struct StoredLayout: Codable {
        var orderedSectionIds: [String]
        var hiddenSectionIds: Set<String>
        var combineEmbyNextUp: Bool? = nil
        var combineJellyfinNextUp: Bool? = nil
        /// Missing in layouts saved before rows were tracked. Those layouts
        /// may contain rows the old limit hid automatically, so their hidden
        /// rows are reset once and the limit is applied again.
        var seenSectionIds: Set<String>? = nil

        var effectiveHiddenSectionIds: Set<String> {
            seenSectionIds == nil ? [] : hiddenSectionIds
        }

        private enum CodingKeys: String, CodingKey {
            case orderedSectionIds, hiddenSectionIds, combineEmbyNextUp, combineJellyfinNextUp, seenSectionIds
        }

        /// Sets are written sorted so an unchanged layout always encodes to the
        /// same bytes. Otherwise every save looks like a new value to iCloud
        /// preference sync, which then refreshes Home on the user's other devices.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(orderedSectionIds, forKey: .orderedSectionIds)
            try container.encode(hiddenSectionIds.sorted(), forKey: .hiddenSectionIds)
            try container.encodeIfPresent(combineEmbyNextUp, forKey: .combineEmbyNextUp)
            try container.encodeIfPresent(combineJellyfinNextUp, forKey: .combineJellyfinNextUp)
            try container.encodeIfPresent(seenSectionIds?.sorted(), forKey: .seenSectionIds)
        }
    }

    init(
        defaults: SharedDefaults = .shared,
        storageKey: @escaping @MainActor () -> String? = HomeSectionPreferences.activeStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        refresh()
    }

    func refresh(force: Bool = false) {
        let key = storageKey()
        guard force || key != loadedStorageKey else { return }
        loadedStorageKey = key
        knownSections = []
        applyStoredLayout(key.flatMap { defaults.data(forKey: $0) })
    }

    private func reloadIfStoredLayoutChanged() {
        guard let key = loadedStorageKey else { return }
        let data = defaults.data(forKey: key)
        guard data != loadedData else { return }
        let previous = (orderedSectionIds, hiddenSectionIds, seenSectionIds, combineEmbyNextUp, combineJellyfinNextUp)
        let revision = layoutRevision
        applyStoredLayout(data)
        // Only a real layout change resets Home's row band.
        if previous == (orderedSectionIds, hiddenSectionIds, seenSectionIds, combineEmbyNextUp, combineJellyfinNextUp) {
            layoutRevision = revision
        }
    }

    private func applyStoredLayout(_ data: Data?) {
        loadedData = data
        guard let data,
              let stored = try? JSONDecoder().decode(StoredLayout.self, from: data) else {
            combineEmbyNextUp = false
            combineJellyfinNextUp = false
            orderedSectionIds = []
            hiddenSectionIds = []
            seenSectionIds = []
            needsMigrationSave = false
            layoutRevision &+= 1
            return
        }

        combineEmbyNextUp = stored.combineEmbyNextUp ?? false
        combineJellyfinNextUp = stored.combineJellyfinNextUp ?? false
        orderedSectionIds = Self.unique(stored.orderedSectionIds)
        hiddenSectionIds = stored.effectiveHiddenSectionIds
        seenSectionIds = stored.seenSectionIds ?? []
        needsMigrationSave = stored.seenSectionIds == nil
        layoutRevision &+= 1
    }

    func isVisible(_ sectionId: String) -> Bool {
        !hiddenSectionIds.contains(sectionId)
    }

    func setVisible(_ visible: Bool, sectionId: String) {
        if visible && !isVisible(sectionId) && visibleRowCount >= Self.maximumVisibleRows { return }
        let wasVisible = isVisible(sectionId)
        guard wasVisible != visible else { return }
        if visible {
            hiddenSectionIds.remove(sectionId)
        } else {
            hiddenSectionIds.insert(sectionId)
        }
        layoutRevision &+= 1
        persist()
        #if os(tvOS) || os(iOS)
        if !visible { TVHomeMetadataCache.shared.clear(sectionId) }
        TVHomeMetadataCache.shared.reconcilePreferences()
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        #endif
    }

    /// Replace the order of currently-known rows while retaining remembered
    /// identities that are temporarily absent (for example an empty Continue
    /// Watching row). If they return later, they recover their saved position.
    func setOrder(_ sectionIds: [String]) {
        let currentOrder = Self.unique(sectionIds)
        let currentSet = Set(currentOrder)
        let updatedOrder = currentOrder + orderedSectionIds.filter {
            !currentSet.contains($0)
        }
        guard updatedOrder != orderedSectionIds else { return }
        orderedSectionIds = updatedOrder
        layoutRevision &+= 1
        persist()
    }

    /// Home omits hidden and empty rows. Settings also retains hidden row
    /// definitions whose item requests were skipped, so they can be enabled again.
    func arrangedSections(
        _ sections: [ResolvedSection],
        includingHidden: Bool = false
    ) -> [ResolvedSection] {
        let projected = Self.combinedSections(sections, enabled: MediaServerProvider.active == .jellyfin ? combineJellyfinNextUp : combineEmbyNextUp, provider: MediaServerProvider.active)
        let nonEmpty = projected.filter {
            (includingHidden || !$0.items.isEmpty) && (MediaServerProvider.active != .emby || !EmbyAdapter.excludesHomeRow(id:$0.id,type:$0.sectionType,title:$0.title))
        }
        let rank = Dictionary(
            uniqueKeysWithValues: orderedSectionIds.enumerated().map { ($0.element, $0.offset) }
        )

        let arranged = nonEmpty.enumerated().sorted { lhs, rhs in
            let lhsRank = rank[lhs.element.id]
            let rhsRank = rank[rhs.element.id]
            switch (lhsRank, rhsRank) {
            case let (.some(left), .some(right)):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)

        guard !includingHidden else { return arranged }
        let visible = arranged.filter { !hiddenSectionIds.contains($0.id) }
        return Array(visible.prefix(Self.maximumVisibleRows))
    }

    func setCombineEmbyNextUp(_ enabled: Bool) {
        guard MediaServerProvider.active == .emby else { return }
        refresh()
        guard combineEmbyNextUp != enabled else { return }
        combineEmbyNextUp = enabled
        enforceVisibleRowLimit(in: knownSections)
        hideRowsBeyondLimit()
        layoutRevision &+= 1
        persist()
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }

    func setCombineJellyfinNextUp(_ enabled: Bool) {
        guard MediaServerProvider.active == .jellyfin else { return }
        refresh()
        guard combineJellyfinNextUp != enabled else { return }
        combineJellyfinNextUp = enabled
        enforceVisibleRowLimit(in: knownSections)
        hideRowsBeyondLimit()
        layoutRevision &+= 1
        persist()
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }

    static func hiddenSections(server: String, profile: String) -> Set<String> {
        let key = "\(platformStoragePrefix).\(server).\(profile)"
        guard let data = SharedDefaults.shared.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredLayout.self, from: data) else { return [] }
        return stored.effectiveHiddenSectionIds
    }

    static func combinesEmbyNextUp(server: String, profile: String) -> Bool {
        let key = "\(platformStoragePrefix).\(server).\(profile)"
        guard let data = SharedDefaults.shared.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredLayout.self, from: data) else { return false }
        return stored.combineEmbyNextUp ?? false
    }

    nonisolated static func combinedSections(
        _ sections: [ResolvedSection], enabled: Bool, provider: MediaServerProvider
    ) -> [ResolvedSection] {
        guard enabled, provider == .emby || provider == .jellyfin else { return sections }
        let resume = sections.filter { $0.sectionType == "continue_watching" }
        let next = sections.filter { $0.sectionType == "next_up" }
        guard let anchor = resume.first ?? next.first else { return sections }
        var seen = Set<String>()
        let items = (resume + next).flatMap(\.items).filter { seen.insert($0.contentId).inserted }
        let combined = ResolvedSection(
            id: resume.first?.id ?? "continue_watching", sectionType: "continue_watching",
            title: "Continue Watching", featured: false, itemLimit: nil,
            totalCount: items.count, isCustom: anchor.isCustom, customized: anchor.customized, items: items
        )
        return sections.compactMap { section in
            if section.id == anchor.id { return combined }
            if section.sectionType == "continue_watching" || section.sectionType == "next_up" { return nil }
            return section
        }
    }

    private func persist() {
        guard let key = storageKey() else { return }
        loadedStorageKey = key
        let stored = StoredLayout(
            orderedSectionIds: orderedSectionIds,
            hiddenSectionIds: hiddenSectionIds,
            combineEmbyNextUp: combineEmbyNextUp,
            combineJellyfinNextUp: combineJellyfinNextUp,
            seenSectionIds: seenSectionIds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        needsMigrationSave = false
        loadedData = data
        // Rewriting identical bytes would still notify iCloud preference sync.
        guard data != defaults.data(forKey: key) else { return }
        defaults.set(data, forKey: key)
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func activeStorageKey() -> String? {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else {
            return nil
        }
        let serverId = ServerRegistry.shared.activeServerId ?? "default"
        return "\(platformStoragePrefix).\(serverId).\(profileId)"
    }

    private static var platformStoragePrefix: String {
        #if os(tvOS) || os(iOS)
        "tvos.homeSections.v1"
        #elseif os(iOS)
        "ios.homeSections.v1"
        #elseif os(macOS)
        "mac.homeSections.v1"
        #else
        "apple.homeSections.v1"
        #endif
    }
}

@Observable
@MainActor
class HomeViewModel {
    typealias DismissContinueWatching = (
        _ contentId: String,
        _ progressUpdatedAt: String
    ) async throws -> Void
    typealias DismissNextUp = (_ contentId: String, _ seriesId: String) async throws -> Void
    typealias SetWatched = (_ contentId: String, _ played: Bool) async throws -> Void
    typealias FetchHomeSections = () async throws -> SectionsResponse

    var sections: [ResolvedSection] = []
    /// True only on the very first load when no cached data exists.
    /// Returning visits paint cached sections instantly and use
    /// `isRefreshing` for the silent background fetch.
    var isLoading = false
    /// In-flight refresh signal — drives the inline indicator while
    /// painted content stays on screen.
    var isRefreshing = false
    var error: ErrorState?
    private(set) var actionError: ErrorState?
    private var pendingContinueWatchingDismissals = Set<String>()
    private var pendingWatchedUpdates = Set<String>()
    private let dismissContinueWatching: DismissContinueWatching
    private let dismissNextUp: DismissNextUp
    private let updateWatchedState: SetWatched
    private let fetchHomeSections: FetchHomeSections
    private var needsSectionsRefresh = false
    /// True when the last refresh failed, including while older rows stayed
    /// on screen, so Home can retry without a fixed timer.
    private(set) var lastRefreshFailed = false
    private var sectionsRevision = 0

    private var hasEnteredHome = false

    /// Keep the hydrated snapshot for immediate entry, then refresh existing
    /// rows on first entry, a stale return, or a queued playback change.
    func refreshForHomeEntry(sinceLastHidden hiddenAt: Date?, now: Date = Date(),
                             provider: MediaServerProvider = .active) async {
        let isStaleReturn = hiddenAt.map { now.timeIntervalSince($0) >= 60 } ?? false
        guard provider == .jellyfin || !hasEnteredHome || isStaleReturn || needsSectionsRefresh || error != nil else { return }
        await loadSections()
        if !Task.isCancelled, error == nil { hasEnteredHome = true }
    }

    static func televisionRefreshInterval(provider: MediaServerProvider) -> Duration? {
        switch provider {
        case .jellyfin: .seconds(10)
        case .silo: .seconds(30 * 60)
        default: nil
        }
    }

    func refreshPlaybackSections(refreshImmediately: Bool = true) async {
        sectionsRevision &+= 1
        needsSectionsRefresh = true
        if refreshImmediately { await loadSections() }
    }

    var isShowingActionError: Bool {
        get { actionError != nil }
        set {
            if !newValue {
                actionError = nil
            }
        }
    }

    /// Sections for Home in server order, filtered to non-empty rows.
    /// `featured` sections render as ordinary rows in their server position —
    /// Apple Home has no separate hero surface.
    var regularSections: [ResolvedSection] {
        sections.filter { !$0.items.isEmpty }
    }

    init(
        dismissContinueWatching: @escaping DismissContinueWatching = { contentId, progressUpdatedAt in
            try await VividAPI.shared.dismissContinueWatchingItem(
                contentId: contentId,
                progressUpdatedAt: progressUpdatedAt
            )
        },
        dismissNextUp: @escaping DismissNextUp = { contentId, seriesId in
            try await VividAPI.shared.dismissNextUpItem(
                contentId: contentId,
                seriesId: seriesId
            )
        },
        setWatched: @escaping SetWatched = { contentId, played in
            try await VividAPI.shared.setWatched(contentId: contentId, played: played)
        },
        fetchHomeSections: @escaping FetchHomeSections = {
            try await StartupContentPrefetcher.fetchHomeSections()
        }
    ) {
        self.dismissContinueWatching = dismissContinueWatching
        self.dismissNextUp = dismissNextUp
        self.updateWatchedState = setWatched
        self.fetchHomeSections = fetchHomeSections

        #if os(tvOS) || os(iOS)
        TVHomeMetadataCache.shared.hydrate()
        #endif

        // Hydrate from the shared cache so the first render after a
        // navigation paints last-known data without any network wait.
        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
            HomeSectionPreferences.shared.enforceVisibleRowLimit(in: cached.sections)
            sections = cached.sections.filter { !$0.items.isEmpty }
        }
    }

    func loadSections() async {
        guard !isLoading, !isRefreshing else { return }
        repeat {
            needsSectionsRefresh = false
            await loadSectionsOnce()
        } while needsSectionsRefresh
    }

    private func loadSectionsOnce() async {
        guard !isLoading, !isRefreshing else { return }
        if sections.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil

        do {
            try await fetchAndApplySections()
            lastRefreshFailed = false
        } catch let err {
            lastRefreshFailed = true
            // Don't blow away painted content on a transient failure —
            // surface the error only when there's nothing to show.
            if sections.isEmpty {
                let state = ErrorState(err)
                if state.isTransient {
                    await retryTransientInitialLoad()
                } else {
                    self.error = state
                }
            }
        }

        isLoading = false
        isRefreshing = false
    }

    /// The Continue Watching row mixes two kinds of cards, and the server keys
    /// their dismissals differently. In-progress items are dismissed against
    /// their exact `progress_updated_at`, so resuming playback re-surfaces
    /// them. Next Up episodes have no progress row; they are dismissed on the
    /// `next_up` surface keyed by series. Sending a fabricated timestamp for
    /// a Next Up card is accepted by the server but never matches anything,
    /// so the card returns on the next fresh fetch.
    func dismissContinueWatchingItem(_ item: SectionItem) async {
        let removal: (
            request: () async throws -> Void,
            mutate: (_ sections: [ResolvedSection]) -> [ResolvedSection]
        )
        if let progressUpdatedAt = item.progressUpdatedAt {
            removal = (
                request: { [dismissContinueWatching] in
                    try await dismissContinueWatching(item.contentId, progressUpdatedAt)
                },
                mutate: { sections in
                    HomeSectionsMutation.removingContinueWatchingItem(
                        contentId: item.contentId,
                        from: sections
                    )
                }
            )
        } else if let seriesId = item.seriesId, !seriesId.isEmpty {
            removal = (
                request: { [dismissNextUp] in
                    try await dismissNextUp(item.contentId, seriesId)
                },
                mutate: { sections in
                    HomeSectionsMutation.removingNextUpItem(
                        contentId: item.contentId,
                        from: sections
                    )
                }
            )
        } else {
            // Neither surface can represent this card. Leave it in place rather
            // than hide it locally and have it reappear after relaunch.
            return
        }

        guard pendingContinueWatchingDismissals.insert(item.contentId).inserted else {
            return
        }
        defer { pendingContinueWatchingDismissals.remove(item.contentId) }

        actionError = nil

        do {
            try await removal.request()

            // A Home request that started before the dismissal can contain the
            // removed item. Invalidate that generation before committing the
            // authoritative local/cache update so a late response cannot put it
            // back on screen.
            StartupContentPrefetcher.invalidateHomeSectionsInFlight()
            sectionsRevision &+= 1
            sections = removal.mutate(sections)
            ResponseCache.shared.update(CacheKey.homeSections, as: SectionsResponse.self) { response in
                response = SectionsResponse(sections: removal.mutate(response.sections))
            }
            #if os(tvOS) || os(iOS)
            TVHomeMetadataCache.shared.store(SectionsResponse(sections: sections))
            #endif
        } catch {
            actionError = ErrorState(error)
        }
    }

    /// Updates playback state through the server, then immediately removes a
    /// completed item from membership-driven Home rows. A fresh Home fetch
    /// reconciles replacement Next Up episodes and watched state elsewhere.
    @discardableResult
    func setWatched(_ item: SectionItem, played: Bool) async -> Bool {
        guard pendingWatchedUpdates.insert(item.contentId).inserted else {
            return false
        }
        defer { pendingWatchedUpdates.remove(item.contentId) }

        actionError = nil

        do {
            try await updateWatchedState(item.contentId, played)

            // Never join or apply a Home request that began before this
            // mutation. It can carry the old Next Up membership.
            StartupContentPrefetcher.invalidateHomeSectionsInFlight()
            sectionsRevision &+= 1

            if played {
                sections = HomeSectionsMutation.removingCompletedItem(
                    contentId: item.contentId,
                    from: sections
                )
                ResponseCache.shared.update(CacheKey.homeSections, as: SectionsResponse.self) { response in
                    response = SectionsResponse(
                        sections: HomeSectionsMutation.removingCompletedItem(
                            contentId: item.contentId,
                            from: response.sections
                        )
                    )
                }
            }
            #if os(tvOS) || os(iOS)
            TVHomeMetadataCache.shared.store(SectionsResponse(sections: sections))
            #endif

            // The server may advance a series to its following episode. Keep
            // the local removal if this reconciliation cannot be fetched.
            await refreshPlaybackSections()
            return true
        } catch {
            actionError = ErrorState(error)
            return false
        }
    }

    private func fetchAndApplySections() async throws {
        let revision = sectionsRevision
        let response = try await fetchHomeSections()
        guard revision == sectionsRevision else { return }
        HomeSectionPreferences.shared.enforceVisibleRowLimit(in: response.sections)
        let updated = response.sections.filter { !$0.items.isEmpty }
        if sections != updated { sections = updated }
        error = nil
    }

    private func retryTransientInitialLoad() async {
        try? await Task.sleep(nanoseconds: 750_000_000)
        guard !Task.isCancelled else { return }

        do {
            try await fetchAndApplySections()
        } catch {
            self.error = ErrorState(error)
        }
    }
}
