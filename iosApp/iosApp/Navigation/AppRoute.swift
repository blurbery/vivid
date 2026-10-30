import Foundation

/// Every screen a navigation stack can push.
enum Route: Hashable {
    case serverSetup
    case login
    case serverNeedsSetup
    case home
    case search
    case browse(libraryId: Int?)
    case library(libraryId: Int, title: String?)
    case libraryCollection(libraryId: Int, collectionId: String, title: String?, kind: LibraryCollectionKind?)
    case itemDetail(contentId: String, tvSeed: TVItemDetailRouteSeed? = nil)
    case personDetail(personId: Int)
    case player(contentId: String, startFromBeginning: Bool, resumePosition: Double?, prefersLastUsedVersion: Bool = false)
    case playerWithFile(contentId: String, fileId: Int, audioTrackIndex: Int?, subtitleTrackIndex: Int?, startFromBeginning: Bool, resumePosition: Double?)
    case settings
    case serverList
    case downloads
    case requestsHub
    case requestDetail(mediaType: RequestMediaType, tmdbId: Int)
    case myRequests
    case offlinePlayer(downloadId: String, contentId: String, startFromBeginning: Bool, resumePosition: Double?)
    case offlineSeriesBrowse(seriesId: String)
    case offlineDownloadDetail(downloadId: String)
    case tvLibraryGrid(libraryId: Int, libraryName: String, libraryType: String, filter: TVLibraryFilterPayload, subtitle: String?)
    case studioNetwork(brandId: String)

    /// The case name, as diagnostics breadcrumbs report it.
    var diagnosticsName: String {
        switch self {
        case .serverSetup: "serverSetup"
        case .login: "login"
        case .serverNeedsSetup: "serverNeedsSetup"
        case .home: "home"
        case .search: "search"
        case .browse: "browse"
        case .library: "library"
        case .libraryCollection: "libraryCollection"
        case .itemDetail: "itemDetail"
        case .personDetail: "personDetail"
        case .player: "player"
        case .playerWithFile: "playerWithFile"
        case .settings: "settings"
        case .serverList: "serverList"
        case .downloads: "downloads"
        case .requestsHub: "requestsHub"
        case .requestDetail: "requestDetail"
        case .myRequests: "myRequests"
        case .offlinePlayer: "offlinePlayer"
        case .offlineSeriesBrowse: "offlineSeriesBrowse"
        case .offlineDownloadDetail: "offlineDownloadDetail"
        case .tvLibraryGrid: "tvLibraryGrid"
        case .studioNetwork: "studioNetwork"
        }
    }
}

extension Route {
    /// Item detail for a Home or For You card. On Apple TV the card's details
    /// paint the page before the item loads; a Continue Watching episode that
    /// opens its series paints the series instead.
    static func itemDetail(destinationContentId: String, sectionItem: SectionItem) -> Route {
        #if os(tvOS)
        .itemDetail(contentId: destinationContentId, tvSeed: TVItemDetailRouteSeed(sectionItem, opening: destinationContentId))
        #else
        .itemDetail(contentId: destinationContentId)
        #endif
    }

    static func itemDetail(browseItem: BrowseItem) -> Route {
        #if os(tvOS)
        .itemDetail(contentId: browseItem.contentId, tvSeed: TVItemDetailRouteSeed(browseItem))
        #else
        .itemDetail(contentId: browseItem.contentId)
        #endif
    }
}

/// What a card already knows about a title, so Apple TV can paint the
/// detail page's backdrop, logo and heading while the item loads. Display
/// only: no playback or personal state.
struct TVItemDetailRouteSeed: Hashable {
    let overlaySummary: OverlaySummary?
    let mediaType: String
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let contentRating: String?
    let genre: String?
    let logoUrl: String?
    let backdropUrl: String?
    let backdropThumbhash: String?

    init(_ item: SectionItem, opening destinationContentId: String) {
        let type = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isEpisode = type == "episode" || item.episodeNumber != nil
        let seriesId = item.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isEpisode, !seriesId.isEmpty, seriesId == destinationContentId, destinationContentId != item.contentId {
            let seriesTitle = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            overlaySummary = item.overlaySummary
            mediaType = "series"
            title = seriesTitle.isEmpty ? item.title : seriesTitle
            year = nil
            overview = nil
            runtime = nil
            contentRating = nil
            genre = nil
            logoUrl = item.logoUrl
            backdropUrl = nil
            backdropThumbhash = nil
        } else {
            overlaySummary = item.overlaySummary
            mediaType = item.type
            title = item.title
            year = item.year
            overview = item.overview
            runtime = item.runtime
            contentRating = item.contentRating
            genre = item.genres?.first
            logoUrl = item.logoUrl
            backdropUrl = item.backdropUrl
            backdropThumbhash = item.backdropThumbhash
        }
    }

    init(_ item: BrowseItem) {
        overlaySummary = item.overlaySummary
        mediaType = item.type
        title = item.title
        year = item.year
        overview = item.overview
        runtime = item.runtime
        contentRating = item.contentRating
        genre = item.genres?.first
        logoUrl = nil
        backdropUrl = item.backdropUrl
        backdropThumbhash = item.backdropThumbhash
    }
}

/// Kept for the Apple TV route switch; nothing builds this route any more.
struct TVLibraryFilterPayload: Hashable {
    func toFilterState() -> CatalogFilterState { CatalogFilterState() }
}

/// The app's top-level destinations.
enum AppTab: String {
    case home = "Home"
    case search = "Search"
    case libraries = "Libraries"
    case recommendations = "For You"
    case calendar = "Calendar"
    case downloads = "Downloads"
    case settings = "Settings"
    case switchProfile = "Profile"
    case switchServer = "Server"

    /// iPhone and iPad's tab bar; Downloads and Calendar are added by the
    /// shell when they're turned on.
    static var visibleCases: [AppTab] { [.home, .libraries, .recommendations] }

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .search: String(localized: "Search")
        case .libraries: String(localized: "Libraries")
        case .recommendations: String(localized: "For You")
        case .calendar: String(localized: "Calendar")
        case .downloads: String(localized: "Downloads")
        case .settings: String(localized: "Settings")
        case .switchProfile: String(localized: "Profile")
        case .switchServer: String(localized: "Server")
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .libraries: "rectangle.stack"
        case .recommendations: "sparkles"
        case .calendar: "calendar"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        case .switchProfile: "person.crop.circle"
        case .switchServer: "server.rack"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: "house.fill"
        case .libraries: "rectangle.stack.fill"
        case .downloads: "arrow.down.circle.fill"
        case .settings: "gearshape.fill"
        case .switchProfile: "person.crop.circle.fill"
        case .search, .recommendations, .calendar, .switchServer: icon
        }
    }
}
