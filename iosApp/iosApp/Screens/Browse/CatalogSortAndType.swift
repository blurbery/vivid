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
    /// Series by when their newest episode aired. Silo and Emby only.
    case lastEpisodeReleased = "last_air_date"
    /// Series by when their newest episode joined the server.
    case lastEpisodeAdded = "latest_episode_added"
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
        case .lastEpisodeReleased: String(localized: "Date Last Episode Released")
        case .lastEpisodeAdded: String(localized: "Date Last Episode Added")
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
        case .addedAt, .releaseDate, .lastEpisodeReleased, .lastEpisodeAdded, .year:
            return ascending ? String(localized: "Oldest") : String(localized: "Newest")
        case .runtime:
            return ascending ? String(localized: "Shortest") : String(localized: "Longest")
        case .ratingImdb, .resolution:
            return ascending ? String(localized: "Lowest") : String(localized: "Highest")
        }
    }

    /// Whether this key sorts only series, so it's offered in TV Shows
    /// libraries alone.
    var isSeriesOnly: Bool {
        self == .lastEpisodeReleased || self == .lastEpisodeAdded
    }

    /// Jellyfin has no sort by the newest episode's air date.
    func isSupported(by provider: MediaServerProvider) -> Bool {
        !(self == .lastEpisodeReleased && provider == .jellyfin)
    }

    static func available(
        for mediaType: BrowseMediaType,
        provider: MediaServerProvider = .active
    ) -> [CatalogSortKey] {
        allCases.filter { key in
            key.isSupported(by: provider) && (!key.isSeriesOnly || mediaType == .series)
        }
    }
}
