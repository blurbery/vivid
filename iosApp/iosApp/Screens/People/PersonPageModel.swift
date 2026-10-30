import Foundation
import Observation

/// Which of a person's titles the filmography shows.
enum PersonMediaFilter: CaseIterable, Hashable {
    case all
    case movies
    case series

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        }
    }

    /// The catalogue `type` sent with the filmography request.
    var catalogType: String? {
        switch self {
        case .all: nil
        case .movies: "movie"
        case .series: "series"
        }
    }
}

/// A person page's data: the person, their filmography 60 titles at a time,
/// and a background refresh while the server is still filling in their
/// details. Generations keep a late answer from an older load from landing.
@MainActor @Observable
final class PersonPageModel {
    typealias PersonFetch = (Int) async throws -> Person
    /// Person id, catalogue type, offset, limit and snapshot.
    typealias CatalogFetch = (Int, String?, Int, Int, String?) async throws -> CatalogResponse

    let personId: Int

    private(set) var person: Person?
    private(set) var items: [BrowseItem] = []
    private(set) var isLoadingPerson = false
    private(set) var error: ErrorState?
    private(set) var hasMore = true
    private(set) var selectedFilter: PersonMediaFilter = .all
    private(set) var offeredFilters = PersonMediaFilter.allCases
    private(set) var total: Int?
    private(set) var isRefreshingMetadata = false

    /// True while a filmography page for the current generation is on its way.
    var isLoadingFilmography: Bool { pageRequestGeneration == filmographyGeneration }

    private let fetchPerson: PersonFetch
    private let fetchCatalog: CatalogFetch
    private var nextOffset = 0
    private var snapshot: String?
    private var filmographyGeneration = 0
    private var pageRequestGeneration: Int?
    private var metadataGeneration = 0
    private var metadataPoll: Task<Void, Never>?
    private var refreshRequestedFor: Int?
    private var pollingExhaustedFor: Int?
    private var prefetchedPosters: Set<URL> = []

    private static let pageSize = 60
    private static let pollInterval: Duration = .seconds(3)
    private static let pollLimit: Duration = .seconds(120)
    private static let unchangedPollsBeforeGivingUp = 5

    init(
        personId: Int,
        fetchPerson: @escaping PersonFetch = { try await VividAPI.shared.person(id: $0) },
        fetchCatalog: @escaping CatalogFetch = { id, type, offset, limit, snapshot in
            try await VividAPI.shared.personCatalogItems(
                personId: id, type: type, offset: offset, limit: limit, snapshot: snapshot
            )
        }
    ) {
        self.personId = personId
        self.fetchPerson = fetchPerson
        self.fetchCatalog = fetchCatalog
    }

    // MARK: Loading

    /// The first load. A return to the page keeps what's already there.
    func loadIfNeeded() async {
        guard person == nil, items.isEmpty, !isLoadingPerson, !isLoadingFilmography else { return }
        await reload()
    }

    func reload() async {
        stopMetadataRefresh()
        let personGeneration = metadataGeneration
        filmographyGeneration += 1
        let generation = filmographyGeneration
        resetFilmography()
        error = nil
        if person == nil {
            person = ResponseCache.shared.get(CacheKey.person(personId), as: Person.self)
        }

        async let loadedPerson: Void = loadPerson(generation: personGeneration)
        async let filters: Void = refreshOfferedFilters()
        async let firstPage: Void = fetchPage(generation: generation)
        _ = await (loadedPerson, filters, firstPage)
    }

    func applyFilter(_ filter: PersonMediaFilter) async {
        guard filter != selectedFilter else { return }
        selectedFilter = filter
        filmographyGeneration += 1
        resetFilmography()
        error = nil
        await fetchPage(generation: filmographyGeneration)
    }

    func loadMore() async {
        guard hasMore, !isLoadingFilmography else { return }
        await fetchPage(generation: filmographyGeneration)
    }

    private func loadPerson(generation: Int) async {
        guard !Task.isCancelled, generation == metadataGeneration else { return }
        isLoadingPerson = true
        defer { if generation == metadataGeneration { isLoadingPerson = false } }
        do {
            let loaded = try await fetchPerson(personId)
            guard generation == metadataGeneration, !Task.isCancelled else { return }
            person = loaded
            ResponseCache.shared.set(loaded, for: CacheKey.person(personId))
            resumeMetadataRefresh()
        } catch {
            guard generation == metadataGeneration, !Task.isCancelled, person == nil else { return }
            self.error = ErrorState(error)
        }
    }

    private func fetchPage(generation: Int) async {
        guard !Task.isCancelled, generation == filmographyGeneration, hasMore, !isLoadingFilmography else { return }
        pageRequestGeneration = generation
        defer { if pageRequestGeneration == generation { pageRequestGeneration = nil } }

        let replacesItems = nextOffset == 0
        do {
            let page = try await fetchCatalog(
                personId, selectedFilter.catalogType, nextOffset, Self.pageSize, snapshot
            )
            guard generation == filmographyGeneration, !Task.isCancelled else { return }
            if replacesItems { items = page.items } else { items += page.items }
            total = page.total
            hasMore = page.hasMore ?? false
            nextOffset += page.items.count
            if snapshot == nil { snapshot = page.snapshot }
        } catch {
            guard generation == filmographyGeneration, !Task.isCancelled else { return }
            self.error = ErrorState(error)
        }
    }

    /// Offers Movies and Series only when the person has some. A failed probe
    /// keeps its filter offered.
    private func refreshOfferedFilters() async {
        let generation = filmographyGeneration
        async let movies = hasTitles(ofType: "movie")
        async let series = hasTitles(ofType: "series")
        let (hasMovies, hasSeries) = await (movies, series)
        guard generation == filmographyGeneration else { return }
        var offered: [PersonMediaFilter] = [.all]
        if hasMovies != false { offered.append(.movies) }
        if hasSeries != false { offered.append(.series) }
        offeredFilters = offered
    }

    private func hasTitles(ofType type: String) async -> Bool? {
        guard let page = try? await fetchCatalog(personId, type, 0, 1, nil) else { return nil }
        return !page.items.isEmpty || (page.total ?? 0) > 0
    }

    private func resetFilmography() {
        #if os(tvOS)
        PosterImageCache.stopPrefetchingCardArtwork(Array(prefetchedPosters))
        #endif
        prefetchedPosters = []
        items = []
        total = nil
        nextOffset = 0
        snapshot = nil
        hasMore = true
    }

    // MARK: Poster prefetch (Apple TV)

    /// The grid is close to its end at `index`: load more, then warm the
    /// posters just ahead.
    func nearEnd(at index: Int) async {
        await loadMore()
        #if os(tvOS)
        guard index < items.count else { return }
        let upcoming = items[index...min(items.count - 1, index + 48)]
        let urls = upcoming.compactMap { $0.posterUrl.flatMap(URL.init(string:)) }
            .filter { !prefetchedPosters.contains($0) }
        guard !urls.isEmpty else { return }
        prefetchedPosters.formUnion(urls)
        PosterImageCache.prefetchCardArtwork(urls)
        #endif
    }

    // MARK: Metadata refresh

    /// Polls for the person's details while the server fetches them. Silo and
    /// Emby only; Jellyfin fills them in on its own schedule.
    func resumeMetadataRefresh() {
        guard MediaServerProvider.active != .jellyfin, let person else { return }
        guard Self.isIncomplete(person) else {
            metadataPoll?.cancel()
            metadataPoll = nil
            isRefreshingMetadata = false
            return
        }
        guard metadataPoll == nil, pollingExhaustedFor != personId else { return }
        isRefreshingMetadata = true
        let asksServer = refreshRequestedFor != personId
        refreshRequestedFor = personId
        let generation = metadataGeneration
        metadataPoll = Task { [weak self] in
            await self?.pollMetadata(generation: generation, asksServer: asksServer)
        }
    }

    func stopMetadataRefresh() {
        metadataGeneration += 1
        isLoadingPerson = false
        metadataPoll?.cancel()
        metadataPoll = nil
        isRefreshingMetadata = false
    }

    private func pollMetadata(generation: Int, asksServer: Bool) async {
        if asksServer, let token = await VividAPI.shared.currentAccessToken(), !token.isEmpty {
            _ = try? await VividAPI.shared.refreshPerson(id: personId)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.pollLimit)
        var wasCancelled = false
        var unchangedPolls = 0
        while clock.now < deadline {
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                wasCancelled = true
                break
            }
            guard let fetched = try? await fetchPerson(personId) else {
                if Task.isCancelled { wasCancelled = true; break }
                continue
            }
            if Task.isCancelled { wasCancelled = true; break }
            guard generation == metadataGeneration, fetched.id == personId else { break }
            ResponseCache.shared.set(fetched, for: CacheKey.person(personId))
            if fetched == person {
                unchangedPolls += 1
                if unchangedPolls >= Self.unchangedPollsBeforeGivingUp { break }
            } else {
                unchangedPolls = 0
                person = fetched
                if !Self.isIncomplete(fetched) {
                    isRefreshingMetadata = false
                    break
                }
            }
        }

        guard generation == metadataGeneration else { return }
        metadataPoll = nil
        isRefreshingMetadata = false
        if !wasCancelled, let person, Self.isIncomplete(person) {
            pollingExhaustedFor = personId
        }
    }

    /// The server hasn't finished fetching a person until they have a bio,
    /// a photo and a birth date.
    static func isIncomplete(_ person: Person) -> Bool {
        [person.bio, person.photoUrl, person.birthDate].contains { value in
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - Dates

/// Server dates for people: a calendar day, optionally with a time, shown
/// as the day written, never shifted through a time zone.
enum PersonDates {
    private static let pattern = #/\d{4}-\d{2}-\d{2}(T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)?)?/#

    private static var utcGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = utcGregorian
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.wholeMatch(of: pattern) != nil else { return nil }
        let day = String(value.prefix(10))
        guard let date = dayParser.date(from: day), dayParser.string(from: date) == day else { return nil }
        return date
    }

    static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.calendar = utcGregorian
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Whole years from `birth` to now, or nil if that would be negative.
    static func age(from birth: Date) -> Int? {
        guard let years = utcGregorian.dateComponents([.year], from: birth, to: Date()).year, years >= 0 else {
            return nil
        }
        return years
    }
}
