import Foundation

/// One studio or network that can be pinned to Home.
struct StudioNetworkBrand: Identifiable, Equatable {
    enum Kind { case network, studio }

    let id: String
    let name: String
    let kind: Kind
    /// TMDb network ID for a network, company ID for a studio.
    let tmdbId: Int
    /// A studio's sister labels, whose films count too. Sony's big releases
    /// are credited to Columbia, not Sony Pictures. The logo stays `tmdbId`'s.
    var labelIds: [Int] = []
    /// TMDb watch providers for a network's films, any of which counts (a
    /// service with several plans lists each one). Read from the US lists,
    /// which are the most complete, unless the service only runs elsewhere.
    /// Titles only show when they're in the library, so the region never
    /// limits what can be watched.
    var watchProviderIds: [Int] = []
    var watchRegion = "US"
    /// Reads a network's series from its streaming list too, not just its
    /// films. TMDb credits BritBox with only a handful of its own series, so
    /// matching by network would leave it nearly empty.
    var listsSeriesByWatchProvider = false
    /// Keeps anime in the Popular rows, which leave it out for every other
    /// brand. Studio Ghibli makes little else.
    var keepsAnime = false
    /// For a logo printed on a solid block (Marvel's box, the Warner Bros.
    /// shield), which would otherwise draw as a plain white shape: its
    /// lettering is knocked out of the block instead.
    var knocksOutLogoText = false
    /// Lets a near-square logo use more of the tile's height, so it doesn't
    /// look smaller than the wide wordmarks beside it.
    var logoHeightScale: CGFloat = 1
    /// Redraws a one-line logo with its two words stacked beside the emblem,
    /// as Sony Pictures' long line was tiny on a tile.
    var stacksLogoWords = false
    /// Sets the name as a wordmark in the system typeface instead of using
    /// the TMDb logo. Apple TV's logo carries the Apple mark, which apps
    /// can't show.
    var usesWordmark = false
    /// The network or studio names servers tag titles with. TMDb's names for
    /// the brand's networks or companies, plus older names a server may still
    /// use. A tagged library title lands in All in Your Library however
    /// popular it is.
    var libraryNames: [String] = []
    /// Name beginnings that count too, for a brand whose every arm counts,
    /// such as Warner Bros. Animation, Television and its regional studios.
    var libraryNamePrefixes: [String] = []
}

extension StudiosNetworksStore {
    nonisolated static let catalogue: [StudioNetworkBrand] = [
        .init(id: "netflix", name: "Netflix", kind: .network, tmdbId: 213, watchProviderIds: [8], libraryNames: ["Netflix"]),
        .init(id: "hbo", name: "HBO", kind: .network, tmdbId: 49, watchProviderIds: [1899], libraryNames: ["HBO", "HBO Max", "Max"]),
        .init(id: "appletv", name: "Apple TV", kind: .network, tmdbId: 2552, watchProviderIds: [350], usesWordmark: true,
              libraryNames: ["Apple TV", "Apple TV+"]),
        .init(id: "disneyplus", name: "Disney+", kind: .network, tmdbId: 2739, watchProviderIds: [337], libraryNames: ["Disney+"]),
        .init(id: "prime", name: "Prime Video", kind: .network, tmdbId: 1024, watchProviderIds: [9],
              libraryNames: ["Prime Video", "Amazon Prime Video", "Amazon"]),
        .init(id: "hulu", name: "Hulu", kind: .network, tmdbId: 453, watchProviderIds: [15], libraryNames: ["Hulu"]),
        .init(id: "peacock", name: "Peacock", kind: .network, tmdbId: 3353, watchProviderIds: [386, 387], libraryNames: ["Peacock"]),
        .init(id: "paramountplus", name: "Paramount+", kind: .network, tmdbId: 4330, watchProviderIds: [2303, 2616],
              libraryNames: ["Paramount+", "Paramount+ with Showtime"]),
        .init(id: "stan", name: "Stan", kind: .network, tmdbId: 1255, watchProviderIds: [21], watchRegion: "AU", libraryNames: ["Stan"]),
        // Servers tag BritBox's BBC and ITV series with the channel that
        // first showed them.
        .init(id: "britbox", name: "BritBox", kind: .network, tmdbId: 4025, watchProviderIds: [151, 197, 1852],
              listsSeriesByWatchProvider: true,
              libraryNames: ["BritBox", "BBC", "BBC One", "BBC Two", "BBC Three", "BBC Four", "BBC Choice", "BBC Scotland",
                             "BBC Alba", "BBC iPlayer", "CBBC", "CBeebies", "ITV", "ITV1", "ITV2", "ITV3", "ITV4", "ITVBe",
                             "ITVX", "ITV Encore"]),
        .init(id: "amc", name: "AMC", kind: .network, tmdbId: 174, watchProviderIds: [80, 526, 528, 635, 1854], libraryNames: ["AMC", "AMC+"]),
        .init(id: "fx", name: "FX", kind: .network, tmdbId: 88, watchProviderIds: [123], libraryNames: ["FX", "FXX"]),
        .init(id: "pixar", name: "Pixar", kind: .studio, tmdbId: 3, libraryNames: ["Pixar", "Pixar Animation Studios"]),
        .init(id: "marvel", name: "Marvel Studios", kind: .studio, tmdbId: 420, knocksOutLogoText: true, libraryNames: ["Marvel Studios"]),
        .init(id: "a24", name: "A24", kind: .studio, tmdbId: 41077, libraryNames: ["A24"]),
        .init(id: "lucasfilm", name: "Lucasfilm", kind: .studio, tmdbId: 1, libraryNames: ["Lucasfilm", "Lucasfilm Ltd.", "Lucasfilm Animation"]),
        .init(id: "dreamworks", name: "DreamWorks", kind: .studio, tmdbId: 521, labelIds: [7],
              libraryNames: ["DreamWorks", "DreamWorks Animation", "DreamWorks Animation Television", "DreamWorks Pictures",
                             "DreamWorks Television"]),
        .init(id: "ghibli", name: "Studio Ghibli", kind: .studio, tmdbId: 10342, keepsAnime: true, libraryNames: ["Studio Ghibli"]),
        .init(id: "sony", name: "Sony Pictures", kind: .studio, tmdbId: 34, labelIds: [5, 2251, 559], stacksLogoWords: true,
              libraryNames: ["Sony Pictures", "Columbia Pictures", "Sony Pictures Animation", "TriStar Pictures"]),
        .init(id: "warnerbros", name: "Warner Bros.", kind: .studio, tmdbId: 174, labelIds: [2785, 1957], knocksOutLogoText: true,
              logoHeightScale: 1.35, libraryNamePrefixes: ["Warner Bros", "Warner Brothers"]),
        .init(id: "universal", name: "Universal", kind: .studio, tmdbId: 33, libraryNames: ["Universal Pictures"]),
        .init(id: "disney", name: "Walt Disney Pictures", kind: .studio, tmdbId: 2, labelIds: [6125],
              libraryNames: ["Walt Disney Pictures", "Walt Disney Animation Studios"]),
        .init(id: "dc", name: "DC", kind: .studio, tmdbId: 429, labelIds: [128064, 9993], knocksOutLogoText: true, logoHeightScale: 1.35,
              libraryNames: ["DC", "DC Comics", "DC Entertainment", "DC Films", "DC Studios"]),
        .init(id: "20thcentury", name: "20th Century Studios", kind: .studio, tmdbId: 127928, labelIds: [25], logoHeightScale: 1.35,
              libraryNames: ["20th Century Studios", "20th Century Fox"]),
    ]

    nonisolated static let tagMatcher = StudioNetworkTagMatcher(catalogue)
}

/// Finds the brands a title's server tags put it under. A network counts a
/// title's networks and its studios, as Emby and Jellyfin keep a series'
/// network with its studios; a studio counts studios only. Names match whole,
/// ignoring case, accents and surrounding spaces, so Disney Channel is never
/// Disney+, unless the brand counts every name with a given beginning.
struct StudioNetworkTagMatcher: Sendable {
    private typealias Prefix = (prefix: String, id: String)

    private var networks: [String: [String]] = [:]
    private var studios: [String: [String]] = [:]
    private var networkPrefixes: [Prefix] = []
    private var studioPrefixes: [Prefix] = []

    init(_ brands: [StudioNetworkBrand]) {
        for brand in brands {
            let names = Set(brand.libraryNames.map(Self.key))
            let prefixes = brand.libraryNamePrefixes.map { (prefix: Self.key($0), id: brand.id) }
            switch brand.kind {
            case .network:
                for name in names { networks[name, default: []].append(brand.id) }
                networkPrefixes += prefixes
            case .studio:
                for name in names { studios[name, default: []].append(brand.id) }
                studioPrefixes += prefixes
            }
        }
    }

    /// Each brand once, in the order its names were found.
    func brandIDs(for item: BrowseItem) -> [String] {
        let studioNames = Set((item.studios ?? []).map(Self.key))
        let networkNames = studioNames.union((item.networks ?? []).map(Self.key))
        let found = Self.ids(for: networkNames, exact: networks, prefixes: networkPrefixes)
            + Self.ids(for: studioNames, exact: studios, prefixes: studioPrefixes)
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func ids(for names: Set<String>, exact: [String: [String]], prefixes: [Prefix]) -> [String] {
        names.flatMap { name in
            (exact[name] ?? []) + prefixes.filter { name.hasPrefix($0.prefix) }.map(\.id)
        }
    }
}
