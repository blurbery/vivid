import Foundation

/// Sort direction. Sent as the catalog `order` param. Named to avoid
/// colliding with Swift's stdlib `SortOrder`.
enum CatalogSortOrder: String, Codable, Hashable {
    case asc
    case desc

    var flipped: CatalogSortOrder { self == .asc ? .desc : .asc }
}

/// The media family of a library — selects the available sort/facet
/// vocabulary and the catalog `type` param.
enum BrowseMediaType: String, Codable, Hashable {
    case movie
    case series
    /// Movies + series in one library. Browses merged; the user narrows via
    /// the Type facet (`CatalogFacet.itemType`), not navigation.
    case mixed

    static func from(libraryType: String) -> BrowseMediaType {
        if VividMediaType.isMixedLibrary(libraryType) { return .mixed }
        if VividMediaType.isSeries(libraryType) { return .series }
        return .movie
    }

    /// The catalog `type` (media_scope) param. Mixed libraries omit it so
    /// movies and series come back merged; the Type facet supplies a grouped
    /// rule when the user narrows.
    var catalogTypeParam: String? {
        switch self {
        case .movie: return "movie"
        case .series: return "series"
        case .mixed: return nil
        }
    }
}

/// One sortable field. The raw value is the canonical server `sort` field
/// (silo-server `query_definition.go` `querySortDefs`). `defaultOrder`
/// mirrors the server's per-field default so the first selection lands the
/// natural direction and a flip is meaningful. This enum is the single
/// source of truth that eliminates the old `sort=added` phantom (the real
/// field is `added_at`).
enum CatalogSortKey: String, CaseIterable, Codable, Hashable {
    case title
    case addedAt = "added_at"
    case releaseDate = "release_date"
    case year
    case ratingImdb = "rating_imdb"
    case runtime
    case resolution

    /// Canonical server sort field.
    var field: String { rawValue }

    var defaultOrder: CatalogSortOrder {
        switch self {
        case .title:
            return .asc
        case .addedAt, .releaseDate, .year, .ratingImdb, .runtime, .resolution:
            return .desc
        }
    }

    var label: String {
        switch self {
        case .title: return String(localized: "Title")
        case .addedAt: return String(localized: "Date Added")
        case .releaseDate: return String(localized: "Release Date")
        case .year: return String(localized: "Year")
        case .ratingImdb: return String(localized: "Rating")
        case .runtime: return String(localized: "Runtime")
        case .resolution: return String(localized: "Resolution")
        }
    }

    /// Short hint for the active direction, shown next to the active key.
    func directionLabel(for order: CatalogSortOrder) -> String {
        switch self {
        case .title:
            return order == .asc ? String(localized: "A–Z") : String(localized: "Z–A")
        case .year, .addedAt, .releaseDate:
            return order == .asc ? String(localized: "Oldest") : String(localized: "Newest")
        case .runtime:
            return order == .asc ? String(localized: "Shortest") : String(localized: "Longest")
        case .ratingImdb, .resolution:
            return order == .asc ? String(localized: "Lowest") : String(localized: "Highest")
        }
    }

    /// Sort keys offered for a library media type, in display order.
    static func available(for mediaType: BrowseMediaType) -> [CatalogSortKey] {
        switch mediaType {
        case .movie, .series, .mixed:
            return [.title, .addedAt, .releaseDate, .year, .ratingImdb, .runtime, .resolution]
        }
    }
}
