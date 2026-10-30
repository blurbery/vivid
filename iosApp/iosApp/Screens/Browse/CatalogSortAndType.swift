import Foundation

/// Which way a catalogue sort runs.
enum CatalogSortOrder: String, Codable, Hashable {
    case asc
    case desc

    var flipped: CatalogSortOrder {
        self == .asc ? .desc : .asc
    }
}

/// What a library holds, as far as browsing it is concerned.
enum BrowseMediaType: String, Codable, Hashable {
    case movie
    case series
    case mixed

    static func from(libraryType: String) -> BrowseMediaType {
        if VividMediaType.isMixedLibrary(libraryType) { return .mixed }
        return VividMediaType.isSeries(libraryType) ? .series : .movie
    }

    /// The catalogue's `type` value; a mixed library asks for every type.
    var catalogTypeParam: String? {
        switch self {
        case .movie: "movie"
        case .series: "series"
        case .mixed: nil
        }
    }
}

/// The fields a catalogue can be sorted by. Raw values are the server's
/// field names and are stored in saved filters.
enum CatalogSortKey: String, CaseIterable, Codable, Hashable {
    case title
    case addedAt = "added_at"
    case releaseDate = "release_date"
    case year
    case ratingImdb = "rating_imdb"
    case runtime
    case resolution

    var field: String { rawValue }

    var defaultOrder: CatalogSortOrder {
        self == .title ? .asc : .desc
    }

    var label: String {
        switch self {
        case .title: String(localized: "Title")
        case .addedAt: String(localized: "Date Added")
        case .releaseDate: String(localized: "Release Date")
        case .year: String(localized: "Year")
        case .ratingImdb: String(localized: "Rating")
        case .runtime: String(localized: "Runtime")
        case .resolution: String(localized: "Resolution")
        }
    }

    func directionLabel(for order: CatalogSortOrder) -> String {
        let ascending = order == .asc
        switch self {
        case .title:
            return ascending ? String(localized: "A–Z") : String(localized: "Z–A")
        case .addedAt, .releaseDate, .year:
            return ascending ? String(localized: "Oldest") : String(localized: "Newest")
        case .runtime:
            return ascending ? String(localized: "Shortest") : String(localized: "Longest")
        case .ratingImdb, .resolution:
            return ascending ? String(localized: "Lowest") : String(localized: "Highest")
        }
    }

    static func available(for mediaType: BrowseMediaType) -> [CatalogSortKey] {
        allCases
    }
}
