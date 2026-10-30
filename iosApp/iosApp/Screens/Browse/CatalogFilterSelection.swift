import Foundation

/// The ways a catalogue can be narrowed, in the order filter menus list them.
enum CatalogFacet: String, CaseIterable, Hashable {
    case itemType
    case genre
    case decade
    case watchStatus
    case contentRating
    case resolution
    case dynamicRange
    case studio
    case network
    case country
    case audioLanguage
    case subtitleLanguage
    case originalLanguage

    var title: String {
        switch self {
        case .itemType: String(localized: "Type")
        case .genre: String(localized: "Genre")
        case .decade: String(localized: "Decade")
        case .watchStatus: String(localized: "Watch Status")
        case .contentRating: String(localized: "Content Rating")
        case .resolution: String(localized: "Resolution")
        case .dynamicRange: String(localized: "Dynamic Range")
        case .studio: String(localized: "Studio")
        case .network: String(localized: "Network")
        case .country: String(localized: "Country")
        case .audioLanguage: String(localized: "Audio Language")
        case .subtitleLanguage: String(localized: "Subtitle Language")
        case .originalLanguage: String(localized: "Original Language")
        }
    }

    /// Emby and Jellyfin filter on the basics only; Silo also offers the
    /// technical and metadata facets. A mixed library starts with the item type.
    static func available(for mediaType: BrowseMediaType) -> [CatalogFacet] {
        var facets: [CatalogFacet] = [.genre, .decade, .watchStatus, .contentRating]
        if !MediaServerProvider.active.usesNativeUser {
            facets += [
                .resolution, .dynamicRange, .studio, .network, .country,
                .audioLanguage, .subtitleLanguage, .originalLanguage,
            ]
        }
        return mediaType == .mixed ? [.itemType] + facets : facets
    }
}

/// A catalogue's sort, filters and letter jump. Stored as JSON per library
/// and synced through iCloud, so the property names are the stored keys.
struct CatalogFilterState: Equatable, Codable, Hashable {
    enum WatchStatus: String, Codable, CaseIterable, Hashable {
        case unwatched
        case inProgress
        case watched
        case favorited
        case watchlist

        var label: String {
            switch self {
            case .unwatched: String(localized: "Unwatched")
            case .inProgress: String(localized: "In Progress")
            case .watched: String(localized: "Watched")
            case .favorited: String(localized: "Favorited")
            case .watchlist: String(localized: "Watchlist")
            }
        }
    }

    /// One selected filter value, shown as a removable chip.
    struct Chip: Identifiable, Hashable {
        let facet: CatalogFacet
        let value: String
        let label: String

        var id: String { facet.rawValue + "\n" + value }
    }

    var sort: CatalogSortKey = .title
    var order: CatalogSortOrder? = nil
    var matchAll: Bool = true
    var mediaScope: String? = nil
    var genres: Set<String> = []
    var contentRatings: Set<String> = []
    var studios: Set<String> = []
    var networks: Set<String> = []
    var countries: Set<String> = []
    var resolutions: Set<String> = []
    var audioLanguages: Set<String> = []
    var subtitleLanguages: Set<String> = []
    var originalLanguages: Set<String> = []
    var decades: Set<Int> = []
    var hdr: Bool = false
    var dolbyVision: Bool = false
    var watchStatus: WatchStatus? = nil
    var namePrefix: String? = nil

    init() {}

    static let none = CatalogFilterState()

    var effectiveOrder: CatalogSortOrder {
        order ?? sort.defaultOrder
    }

    var activeFacetCount: Int {
        let valueSets = [
            genres, contentRatings, studios, networks, countries,
            resolutions, audioLanguages, subtitleLanguages, originalLanguages,
        ]
        var count = valueSets.filter { !$0.isEmpty }.count
        if mediaScope != nil { count += 1 }
        if !decades.isEmpty { count += 1 }
        if hdr || dolbyVision { count += 1 }
        if watchStatus != nil { count += 1 }
        return count
    }

    var hasActiveFilters: Bool { activeFacetCount > 0 }

    var canResetFilters: Bool { hasActiveFilters || !matchAll }

    var isDefault: Bool {
        sort == .title && order == nil && matchAll && !hasActiveFilters && namePrefix == nil
    }

    func selectedValues(_ facet: CatalogFacet) -> Set<String> {
        switch facet {
        case .itemType: mediaScope.map { [$0] } ?? []
        case .genre: genres
        case .decade: Set(decades.map(String.init))
        case .watchStatus: watchStatus.map { [$0.rawValue] } ?? []
        case .contentRating: contentRatings
        case .resolution: resolutions
        case .dynamicRange: dynamicRangeValues
        case .studio: studios
        case .network: networks
        case .country: countries
        case .audioLanguage: audioLanguages
        case .subtitleLanguage: subtitleLanguages
        case .originalLanguage: originalLanguages
        }
    }

    func isSelected(_ facet: CatalogFacet, value: String) -> Bool {
        selectedValues(facet).contains(value)
    }

    mutating func toggle(_ facet: CatalogFacet, value: String) {
        switch facet {
        case .itemType:
            mediaScope = mediaScope == value ? nil : value
        case .genre:
            // One genre at a time.
            genres = genres == [value] ? [] : [value]
        case .decade:
            guard let decade = Int(value) else { return }
            if decades.remove(decade) == nil { decades.insert(decade) }
        case .watchStatus:
            let status = WatchStatus(rawValue: value)
            watchStatus = watchStatus == status ? nil : status
        case .dynamicRange:
            if value == Self.hdrValue {
                hdr.toggle()
            } else if value == Self.dolbyVisionValue {
                dolbyVision.toggle()
            }
        case .contentRating: Self.flip(value, in: &contentRatings)
        case .resolution: Self.flip(value, in: &resolutions)
        case .studio: Self.flip(value, in: &studios)
        case .network: Self.flip(value, in: &networks)
        case .country: Self.flip(value, in: &countries)
        case .audioLanguage: Self.flip(value, in: &audioLanguages)
        case .subtitleLanguage: Self.flip(value, in: &subtitleLanguages)
        case .originalLanguage: Self.flip(value, in: &originalLanguages)
        }
    }

    mutating func clear(_ facet: CatalogFacet) {
        switch facet {
        case .itemType: mediaScope = nil
        case .genre: genres = []
        case .decade: decades = []
        case .watchStatus: watchStatus = nil
        case .contentRating: contentRatings = []
        case .resolution: resolutions = []
        case .dynamicRange:
            hdr = false
            dolbyVision = false
        case .studio: studios = []
        case .network: networks = []
        case .country: countries = []
        case .audioLanguage: audioLanguages = []
        case .subtitleLanguage: subtitleLanguages = []
        case .originalLanguage: originalLanguages = []
        }
    }

    /// Clears every filter but keeps the sort and the letter jump.
    mutating func resetFilters() {
        var fresh = CatalogFilterState.none
        fresh.sort = sort
        fresh.order = order
        fresh.namePrefix = namePrefix
        self = fresh
    }

    /// Emby and Jellyfin can't filter on the Silo-only facets or match any
    /// filter, so those parts are dropped for them.
    func normalized(for provider: MediaServerProvider) -> CatalogFilterState {
        guard provider.usesNativeUser else { return self }
        var state = self
        state.matchAll = true
        state.studios = []
        state.networks = []
        state.countries = []
        state.resolutions = []
        state.audioLanguages = []
        state.subtitleLanguages = []
        state.originalLanguages = []
        state.hdr = false
        state.dolbyVision = false
        return state
    }

    /// Every selected value as a chip, facet by facet, values in order.
    var activeChips: [Chip] {
        CatalogFacet.allCases.flatMap { facet in
            selectedValues(facet).sorted().map { value in
                Chip(facet: facet, value: value, label: Self.chipLabel(facet, value: value))
            }
        }
    }

    /// A key that differs whenever the catalogue's results would.
    var cacheKeyFragment: String {
        var parts = [
            "s=\(sort.field)",
            "o=\(effectiveOrder.rawValue)",
            "m=\(matchAll ? "all" : "any")",
        ]
        if let namePrefix { parts.append("p=\(Self.encoded(namePrefix))") }
        if let mediaScope { parts.append("sc=\(Self.encoded(mediaScope))") }
        let valueSets: [(String, Set<String>)] = [
            ("g", genres), ("cr", contentRatings), ("st", studios), ("nw", networks),
            ("co", countries), ("res", resolutions), ("al", audioLanguages),
            ("sl", subtitleLanguages), ("ol", originalLanguages),
        ]
        for (name, values) in valueSets where !values.isEmpty {
            parts.append("\(name)=" + values.sorted().map(Self.encoded).joined(separator: ","))
        }
        if !decades.isEmpty {
            parts.append("dec=" + decades.sorted().map(String.init).joined(separator: ","))
        }
        if hdr { parts.append("hdr") }
        if dolbyVision { parts.append("dv") }
        if let watchStatus { parts.append("ws=\(Self.encoded(watchStatus.rawValue))") }
        return parts.joined(separator: "|")
    }

    static let hdrValue = "hdr"
    static let dolbyVisionValue = "dolby_vision"

    static func decadeLabel(_ year: String) -> String {
        String(localized: "\(year)s", comment: "Decade filter option, for example 1990s")
    }

    static func dynamicRangeLabel(_ value: String) -> String {
        value == dolbyVisionValue ? "Dolby Vision" : "HDR"
    }

    private var dynamicRangeValues: Set<String> {
        var values: Set<String> = []
        if hdr { values.insert(Self.hdrValue) }
        if dolbyVision { values.insert(Self.dolbyVisionValue) }
        return values
    }

    private static func chipLabel(_ facet: CatalogFacet, value: String) -> String {
        switch facet {
        case .itemType:
            return value == "series" ? String(localized: "Series") : String(localized: "Movies")
        case .decade:
            return Int(value).map { decadeLabel(String($0)) } ?? value
        case .dynamicRange:
            return dynamicRangeLabel(value)
        case .watchStatus:
            return WatchStatus(rawValue: value)?.label ?? value
        default:
            return value
        }
    }

    private static func flip(_ value: String, in values: inout Set<String>) {
        if values.remove(value) == nil { values.insert(value) }
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
