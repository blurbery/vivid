import SwiftUI

/// The For You Watchlist, Favourites and Collections filter. For the lists,
/// Show, Original Language and A–Z are sent to the server; Anime is resolved
/// on the device because no server can exclude a library from a personal
/// list. Collections only use Source, matched on the device.
struct PersonalListFilter: Hashable {
    /// The choices a Filter menu offers, apart from A–Z.
    struct Choices: OptionSet, Hashable {
        let rawValue: Int
        static let show = Choices(rawValue: 1 << 0)
        static let originalLanguage = Choices(rawValue: 1 << 1)
        static let anime = Choices(rawValue: 1 << 2)
        static let source = Choices(rawValue: 1 << 3)
        /// Watchlist and Favourites.
        static let lists: Choices = [.show, .originalLanguage, .anime]
        /// Only Silo has collections other than the server's own.
        static var collections: Choices { MediaServerProvider.active.usesNativeUser ? [] : [.source] }
    }

    /// Who a collection comes from.
    enum Source: String, CaseIterable, Identifiable {
        case all = "All"
        /// A collection set up on the server.
        case server = "Server"
        /// A personal collection another profile shares into the library.
        case shared = "Shared"
        /// This profile's own personal collections.
        case mine = "Mine"

        var id: Self { self }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .server: String(localized: "Server")
            case .shared: String(localized: "Shared")
            case .mine: String(localized: "Mine")
            }
        }
    }

    enum Show: String, CaseIterable, Identifiable {
        case all = "All"
        case movies = "Movies"
        case series = "Series"

        var id: Self { self }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .movies: String(localized: "Movies")
            case .series: String(localized: "Series")
            }
        }

        var typeParam: String? {
            switch self {
            case .all: return nil
            case .movies: return "movie"
            case .series: return "series"
            }
        }
    }

    enum Anime: String, CaseIterable, Identifiable {
        case any = "Show everything"
        case only = "Only anime"
        case hide = "Hide anime"

        var id: Self { self }

        var title: String {
            switch self {
            case .any: String(localized: "Show everything")
            case .only: String(localized: "Only anime")
            case .hide: String(localized: "Hide anime")
            }
        }
    }

    var show: Show = .all
    /// TMDb ISO 639-1 code, matching Silo's stored original language.
    var originalLanguage: String?
    var anime: Anime = .any
    /// iPhone and iPad keep A–Z inside this menu; Apple TV has its own A–Z menu.
    var namePrefix: String?
    var source: Source = .all

    var activeCount: Int {
        (show == .all ? 0 : 1)
            + (originalLanguage == nil ? 0 : 1)
            + (anime == .any ? 0 : 1)
            + (namePrefix == nil ? 0 : 1)
            + (source == .all ? 0 : 1)
    }

    var isActive: Bool { activeCount > 0 }

    var cacheKey: String {
        "show=\(show.rawValue):lang=\(originalLanguage ?? "any"):anime=\(anime.rawValue):prefix=\(namePrefix ?? "all"):source=\(source.rawValue)"
    }

    /// Only Silo reports each title's original language.
    static var supportsOriginalLanguage: Bool { MediaServerProvider.active == .silo }

    static let languages: [(code: String, name: String)] = [
        ("ar", "Arabic"), ("cn", "Cantonese"), ("zh", "Chinese"), ("da", "Danish"),
        ("nl", "Dutch"), ("en", "English"), ("fi", "Finnish"), ("fr", "French"),
        ("de", "German"), ("el", "Greek"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("is", "Icelandic"), ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"),
        ("ko", "Korean"), ("ml", "Malayalam"), ("no", "Norwegian"), ("fa", "Persian"),
        ("pl", "Polish"), ("pt", "Portuguese"), ("ru", "Russian"), ("es", "Spanish"),
        ("sv", "Swedish"), ("tl", "Tagalog"), ("ta", "Tamil"), ("te", "Telugu"),
        ("th", "Thai"), ("tr", "Turkish"), ("uk", "Ukrainian"), ("vi", "Vietnamese"),
    ]

    /// The language's name in the app language. The codes stay the filter
    /// values; the English names are the fallback when the device has none.
    static func languageName(_ code: String) -> String {
        // TMDb's "cn" (Cantonese) isn't an ISO 639 code.
        let displayCode = code == "cn" ? "yue" : code
        if let name = Locale.current.localizedString(forLanguageCode: displayCode), !name.isEmpty {
            return name.prefix(1).uppercased(with: Locale.current) + name.dropFirst()
        }
        return languages.first { $0.code == code }?.name ?? code.uppercased()
    }

    /// The menu's languages, named and sorted in the app language.
    static var languagesByName: [(code: String, name: String)] {
        languages.map { ($0.code, languageName($0.code)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds Show, Original Language and A–Z to a personal-source catalogue
    /// query. Sort is only sent with A–Z so the list keeps its saved order.
    func apply(to query: inout [String: String]) {
        if let type = show.typeParam { query["type"] = type }
        if let originalLanguage, Self.supportsOriginalLanguage {
            query["groups[0][match]"] = "all"
            query["groups[0][rules][0][field]"] = "original_language"
            query["groups[0][rules][0][op]"] = "is"
            query["groups[0][rules][0][value]"] = originalLanguage
        }
        if let namePrefix {
            query["name_prefix"] = namePrefix
            query["sort"] = CatalogSortKey.title.field
            query["order"] = CatalogSortOrder.asc.rawValue
        }
    }

    /// This filter without the choices a menu doesn't offer, so one left
    /// over from another list or server never filters or adds to the badge.
    func limited(to choices: Choices) -> PersonalListFilter {
        var limited = self
        if !choices.contains(.show) { limited.show = .all }
        if !choices.contains(.originalLanguage) { limited.originalLanguage = nil }
        if !choices.contains(.anime) { limited.anime = .any }
        if !choices.contains(.source) { limited.source = .all }
        return limited
    }

    /// Whether a library collection matches Source. A user collection is
    /// Mine when `activeProfileID` made it and Shared otherwise.
    func matchesCollection(kind: LibraryCollectionKind, creatorProfileID: String?, activeProfileID: String?) -> Bool {
        let isMine = creatorProfileID != nil && creatorProfileID == activeProfileID
        switch source {
        case .all: return true
        case .server: return kind == .regular
        case .shared: return kind == .userCollections && !isMine
        case .mine: return kind == .userCollections && isMine
        }
    }
}

/// Loads a filtered Watchlist or Favourites list for For You.
@MainActor
enum PersonalListLoader {
    private static let pageSize = 200

    /// Every title on `source` ("watchlist" or "favorites") that matches the
    /// filter. Anime is decided on the device, so the whole list is fetched.
    static func loadAll(source: String, filter: PersonalListFilter) async throws -> [BrowseItem] {
        var query = ["source": source]
        filter.apply(to: &query)
        let items = try await allPages(query)
        guard filter.anime != .any else { return items }
        let animeIDs = try await animeLibraryItemIDs(source: source)
        return items.filter { item in
            let isAnime = animeIDs.contains(item.contentId) || isTaggedAnime(item)
            return filter.anime == .only ? isAnime : !isAnime
        }
    }

    /// Titles tagged as anime by metadata. Japanese animation counts when the
    /// server reports the original language (Silo).
    static func isTaggedAnime(_ item: BrowseItem) -> Bool {
        let genres = item.genres ?? []
        if genres.contains(where: { $0.localizedCaseInsensitiveCompare("Anime") == .orderedSame }) {
            return true
        }
        return item.originalLanguage?.lowercased() == "ja"
            && genres.contains { $0.localizedCaseInsensitiveCompare("Animation") == .orderedSame }
    }

    /// A library whose name includes "Anime", such as "Movies Anime".
    static func isAnimeLibrary(_ library: Library) -> Bool {
        library.name.localizedCaseInsensitiveContains("anime")
    }

    private static func animeLibraryItemIDs(source: String) async throws -> Set<String> {
        let animeLibraries = try await libraries().filter(isAnimeLibrary)
        var ids = Set<String>()
        for library in animeLibraries {
            let items = try await allPages(["source": source, "library_id": String(library.id)])
            ids.formUnion(items.map(\.contentId))
        }
        return ids
    }

    private static func libraries() async throws -> [Library] {
        if let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            return cached.libraries
        }
        return try await VividAPI.shared.libraries().libraries
    }

    private static func allPages(_ base: [String: String]) async throws -> [BrowseItem] {
        var items: [BrowseItem] = []
        var seen = Set<String>()
        var offset = 0
        // Pages until the server says there are no more. A page with nothing
        // new also stops it, so a server that keeps saying "more" can't loop.
        while true {
            try Task.checkCancellation()
            var query = base
            query["offset"] = String(offset)
            query["limit"] = String(pageSize)
            query["include_total"] = "false"
            let response = try await VividAPI.shared.catalog(query: query)
            let fresh = response.items.filter { seen.insert($0.contentId).inserted }
            items.append(contentsOf: fresh)
            offset += response.items.count
            let hasMore = response.hasMore ?? (response.total.map { offset < $0 } ?? false)
            if !hasMore || fresh.isEmpty { break }
        }
        return items
    }
}

/// Menu items shared by the Apple TV and iPhone/iPad Filter buttons. Each
/// choice is single-select and shows a checkmark, like the Sort menu.
struct PersonalListFilterMenuContent: View {
    @Binding var filter: PersonalListFilter
    let showsAlphabet: Bool
    var choices: PersonalListFilter.Choices = .lists

    private let letters = ["#"] + (65...90).compactMap { UnicodeScalar($0).map(String.init) }

    var body: some View {
        if choices.contains(.source) {
            Section("Source") {
                ForEach(PersonalListFilter.Source.allCases) { source in
                    Button { filter.source = source } label: { item(source.title, selected: filter.source == source) }
                }
            }
        }
        if choices.contains(.show) {
            Section("Show") {
                ForEach(PersonalListFilter.Show.allCases) { show in
                    Button { filter.show = show } label: { item(show.title, selected: filter.show == show) }
                }
            }
        }
        Section {
            if choices.contains(.originalLanguage), PersonalListFilter.supportsOriginalLanguage {
                Menu {
                    Button { filter.originalLanguage = nil } label: { item(String(localized: "Any"), selected: filter.originalLanguage == nil) }
                    ForEach(PersonalListFilter.languagesByName, id: \.code) { language in
                        Button { filter.originalLanguage = language.code } label: {
                            item(language.name, selected: filter.originalLanguage == language.code)
                        }
                    }
                } label: {
                    Text("Original Language")
                    if let code = filter.originalLanguage { Text(PersonalListFilter.languageName(code)) }
                }
            }
            if choices.contains(.anime) {
                Menu {
                    ForEach(PersonalListFilter.Anime.allCases) { anime in
                        Button { filter.anime = anime } label: { item(anime.title, selected: filter.anime == anime) }
                    }
                } label: {
                    Text("Anime")
                    if filter.anime != .any { Text(filter.anime.title) }
                }
            }
            if showsAlphabet {
                Menu {
                    Button { filter.namePrefix = nil } label: { item(String(localized: "All"), selected: filter.namePrefix == nil) }
                    ForEach(letters, id: \.self) { letter in
                        Button { filter.namePrefix = letter } label: { item(letter, selected: filter.namePrefix == letter) }
                    }
                } label: {
                    Text("A–Z")
                    if let prefix = filter.namePrefix { Text(prefix) }
                }
            }
        }
        Section {
            Button("Clear filters") { filter = PersonalListFilter() }
                .disabled(!filter.isActive)
        }
    }

    @ViewBuilder
    private func item(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
