import Foundation

/// The values a library offers for each filter facet.
struct CatalogFacets {
    private let genres: [String]
    private let studios: [String]
    private let networks: [String]
    private let countries: [String]
    private let contentRatings: [String]
    private let resolutions: [String]
    private let audioLanguages: [String]
    private let subtitleLanguages: [String]
    private let originalLanguages: [String]

    init() {
        genres = []
        studios = []
        networks = []
        countries = []
        contentRatings = []
        resolutions = []
        audioLanguages = []
        subtitleLanguages = []
        originalLanguages = []
    }

    init(filters: CatalogFilters) {
        genres = filters.genres
        studios = filters.studios
        networks = filters.networks
        countries = filters.countries
        contentRatings = filters.contentRatings
        resolutions = filters.resolutions ?? []
        audioLanguages = filters.audioLanguages ?? []
        subtitleLanguages = filters.subtitleLanguages ?? []
        originalLanguages = filters.originalLanguages ?? []
    }

    private static let decadeStarts = [2020, 2010, 2000, 1990, 1980, 1970, 1960]

    /// The choices a filter menu shows for `facet`. Watch status needs a
    /// profile to mean anything, so it offers nothing without one.
    func optionPairs(for facet: CatalogFacet, hasProfile: Bool) -> [(value: String, label: String)] {
        switch facet {
        case .itemType:
            return [("movie", String(localized: "Movies")), ("series", String(localized: "Series"))]
        case .decade:
            return Self.decadeStarts.map { start in
                let year = String(start)
                return (year, CatalogFilterState.decadeLabel(year))
            }
        case .dynamicRange:
            return [CatalogFilterState.hdrValue, CatalogFilterState.dolbyVisionValue].map {
                ($0, CatalogFilterState.dynamicRangeLabel($0))
            }
        case .watchStatus:
            guard hasProfile else { return [] }
            return CatalogFilterState.WatchStatus.allCases.map { ($0.rawValue, $0.label) }
        case .genre: return Self.pairs(genres)
        case .contentRating: return Self.pairs(contentRatings)
        case .studio: return Self.pairs(studios)
        case .network: return Self.pairs(networks)
        case .country: return Self.pairs(countries)
        case .resolution: return Self.pairs(resolutions)
        case .audioLanguage: return Self.pairs(audioLanguages)
        case .subtitleLanguage: return Self.pairs(subtitleLanguages)
        case .originalLanguage: return Self.pairs(originalLanguages)
        }
    }

    private static func pairs(_ values: [String]) -> [(value: String, label: String)] {
        values.map { ($0, $0) }
    }
}

/// Loads each library's filter values once and shares requests already
/// on their way.
@MainActor
final class FacetLoader {
    static let shared = FacetLoader()

    private var inFlight: [String: Task<CatalogFilters, Error>] = [:]

    func cachedFacets(libraryId: Int?, includeTechnical: Bool = true) -> CatalogFacets? {
        let key = CacheKey.catalogFilters(libraryId: libraryId, includeTechnical: includeTechnical)
        return ResponseCache.shared.get(key, as: CatalogFilters.self).map(CatalogFacets.init(filters:))
    }

    func facets(libraryId: Int?, includeTechnical: Bool = true) async throws -> CatalogFacets {
        if let cached = cachedFacets(libraryId: libraryId, includeTechnical: includeTechnical) {
            return cached
        }
        let key = CacheKey.catalogFilters(libraryId: libraryId, includeTechnical: includeTechnical)
        let request = inFlight[key] ?? Task {
            try await VividAPI.shared.catalogFilters(libraryId: libraryId, includeTechnical: includeTechnical)
        }
        inFlight[key] = request
        defer { if inFlight[key] == request { inFlight[key] = nil } }
        let filters = try await request.value
        ResponseCache.shared.set(filters, for: key)
        return CatalogFacets(filters: filters)
    }
}
