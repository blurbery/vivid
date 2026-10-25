import XCTest
@testable import Vivid

@MainActor
final class StudiosNetworksStoreTests: XCTestCase {
    private func item(_ id: String, _ title: String, year: Int, type: String = "movie", poster: String? = nil) throws -> BrowseItem {
        let posterField = poster.map { #","posterUrl":"\#($0)""# } ?? ""
        let json = #"{"contentId":"\#(id)","type":"\#(type)","title":"\#(title)","year":\#(year)\#(posterField)}"#
        return try JSONDecoder().decode(BrowseItem.self, from: Data(json.utf8))
    }

    private let siloPoster = "https://silo.example.com/api/v2/artwork/posters/a.webp?exp=1791000000&sig=0f1e2d"
    private let s3Poster = "https://bucket.s3.example.com/posters/a.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256"
        + "&X-Amz-Credential=key%2F20261007%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20261007T120000Z"
        + "&X-Amz-Expires=14400&X-Amz-SignedHeaders=host&X-Amz-Signature=abc123"
    private let embyPoster = "https://emby.example.com/Items/42/Images/Primary?tag=abc&maxWidth=780&quality=90"

    private func discover(id: Int, title: String? = nil, name: String? = nil, date: String) throws -> TVTMDbStore.DiscoverPage.Result {
        var fields = [#""id":\#(id)"#]
        if let title { fields.append(#""title":"\#(title)","release_date":"\#(date)""#) }
        if let name { fields.append(#""name":"\#(name)","first_air_date":"\#(date)""#) }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(TVTMDbStore.DiscoverPage.Result.self, from: Data(json.utf8))
    }

    func testTitleKeyIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(
            StudiosNetworksStore.titleKey("Amélie", year: 2001),
            StudiosNetworksStore.titleKey("AMELIE", year: 2001)
        )
        XCTAssertEqual(
            StudiosNetworksStore.titleKey("Spider-Man: No Way Home", year: 2021),
            StudiosNetworksStore.titleKey("Spider Man No Way Home", year: 2021)
        )
        XCTAssertNotEqual(
            StudiosNetworksStore.titleKey("Dune", year: 1984),
            StudiosNetworksStore.titleKey("Dune", year: 2021)
        )
    }

    func testLookupPrefersTMDbIDThenExactTitleAndYear() throws {
        let byID = try item("a", "Something Else", year: 1999)
        let byTitle = try item("b", "Inside Out", year: 2015)
        let index = [
            "550": byID,
            StudiosNetworksStore.titleKey("Inside Out", year: 2015): byTitle,
        ]
        XCTAssertEqual(StudiosNetworksStore.lookup(try discover(id: 550, title: "Fight Club", date: "1999-10-15"), in: index)?.contentId, "a")
        XCTAssertEqual(StudiosNetworksStore.lookup(try discover(id: 1, title: "Inside Out", date: "2015-06-19"), in: index)?.contentId, "b")
        XCTAssertEqual(StudiosNetworksStore.lookup(try discover(id: 2, name: "Inside Out", date: "2015-01-01"), in: index)?.contentId, "b")
    }

    func testLookupRejectsAYearEitherSide() throws {
        let index = [StudiosNetworksStore.titleKey("The Scandal", year: 2026): try item("s", "The Scandal", year: 2026)]
        XCTAssertNil(StudiosNetworksStore.lookup(try discover(id: 9, name: "The Scandal", date: "2025-03-01"), in: index))
        XCTAssertNil(StudiosNetworksStore.lookup(try discover(id: 9, name: "The Scandal", date: "2027-03-01"), in: index))
    }

    func testNetworkPagesUseRecentTitlesSeriesFirst() throws {
        let brand = StudiosNetworksStore.catalogue.first { $0.id == "netflix" }
        var result = StudioNetworkResult()
        result.series = try (0..<8).map { try item("old\($0)", "Old \($0)", year: 2010, type: "series") }
        result.recentSeries = try (0..<7).map { try item("new\($0)", "New \($0)", year: 2026, type: "series") }
        result.recentMovies = try (0..<6).map { try item("m\($0)", "Movie \($0)", year: 2026) }
        let rows = StudiosNetworksStore.pageRows(for: brand, result: result)
        XCTAssertEqual(rows.map(\.title), ["Popular TV Shows", "Popular Movies"])
        XCTAssertEqual(rows.first?.items.first?.contentId, "new0")
    }

    func testStudioPagesUseAllTimeTitlesMoviesFirst() throws {
        let brand = StudiosNetworksStore.catalogue.first { $0.id == "pixar" }
        var result = StudioNetworkResult()
        result.movies = try (0..<25).map { try item("m\($0)", "Movie \($0)", year: 2000 + $0) }
        result.recentMovies = try (0..<2).map { try item("r\($0)", "Recent \($0)", year: 2026) }
        let rows = StudiosNetworksStore.pageRows(for: brand, result: result)
        XCTAssertEqual(rows.map(\.title), ["Popular Movies"])
        XCTAssertEqual(rows.first?.items.count, StudiosNetworksStore.rowLimit)
        XCTAssertEqual(rows.first?.items.first?.contentId, "m0")
    }

    func testNetworkRowsFallBackToAllTimeWhenTheYearIsThin() throws {
        let brand = StudiosNetworksStore.catalogue.first { $0.id == "appletv" }
        var result = StudioNetworkResult()
        result.recentMovies = try (0..<5).map { try item("r\($0)", "Recent \($0)", year: 2026) }
        result.movies = try (0..<12).map { try item("a\($0)", "All \($0)", year: 2020) }
        let rows = StudiosNetworksStore.pageRows(for: brand, result: result)
        XCTAssertEqual(rows.map(\.title), ["Popular Movies"])
        XCTAssertEqual(rows.first?.items.first?.contentId, "a0")
    }

    func testRowsBelowTheMinimumAreHidden() throws {
        let brand = StudiosNetworksStore.catalogue.first { $0.id == "hbo" }
        var result = StudioNetworkResult()
        result.recentSeries = try (0..<(StudiosNetworksStore.minimumCount - 1)).map {
            try item("s\($0)", "Show \($0)", year: 2026, type: "series")
        }
        XCTAssertTrue(StudiosNetworksStore.pageRows(for: brand, result: result).isEmpty)
    }

    func testAutomaticPicksRankByUncappedMatchCount() {
        let picks = StudiosNetworksStore.automaticPicks(counts: [
            "netflix": 163, "hbo": 165, "disneyplus": 164, "marvel": 115, "appletv": 150, "pixar": 68, "ghibli": 20,
        ])
        XCTAssertEqual(picks, ["hbo", "disneyplus", "netflix", "appletv", "marvel", "pixar", "ghibli"])
    }

    func testAutomaticPicksStopAtTwenty() {
        let counts = Dictionary(uniqueKeysWithValues: StudiosNetworksStore.catalogue.enumerated().map { ($1.id, 100 + $0) })
        XCTAssertGreaterThan(StudiosNetworksStore.catalogue.count, StudiosNetworksStore.maxPicks)
        let picks = StudiosNetworksStore.automaticPicks(counts: counts)
        XCTAssertEqual(picks.count, 20)
        XCTAssertEqual(picks.first, StudiosNetworksStore.catalogue.last?.id, "Most matches first")
    }

    func testAutomaticPicksKeepCatalogueOrderForTiesAndSkipSmallBrands() {
        let picks = StudiosNetworksStore.automaticPicks(counts: ["pixar": 40, "netflix": 40, "a24": 40, "hulu": 3])
        XCTAssertEqual(picks, ["netflix", "pixar", "a24"])
    }

    func testFilledTopsUpOlderChoicesToSixKeepingTheirOrder() {
        let counts = ["netflix": 163, "hbo": 165, "disneyplus": 164, "marvel": 115, "appletv": 150, "pixar": 68, "ghibli": 20]
        XCTAssertEqual(StudiosNetworksStore.filled(["marvel", "netflix", "ghibli"], counts: counts),
                       ["marvel", "netflix", "ghibli", "hbo", "disneyplus", "appletv"])
        // Ineligible brands drop out before topping up.
        XCTAssertEqual(StudiosNetworksStore.filled(["hulu", "pixar"], counts: counts),
                       ["pixar", "hbo", "disneyplus", "netflix", "appletv", "marvel"])
    }

    func testFilledKeepsSixToTwentyChoicesExactly() {
        let ids = StudiosNetworksStore.catalogue.map(\.id)
        let counts = Dictionary(uniqueKeysWithValues: ids.map { ($0, 50) })
        let eight = Array(ids.suffix(8).reversed())
        XCTAssertEqual(StudiosNetworksStore.filled(eight, counts: counts), eight, "No top-up past six")
        XCTAssertEqual(StudiosNetworksStore.filled(Array(ids.prefix(6)), counts: counts), Array(ids.prefix(6)))
        XCTAssertEqual(StudiosNetworksStore.filled(ids, counts: counts), Array(ids.prefix(20)), "At most 20")
    }

    func testResultCountIsTheUncappedMatchCount() {
        var result = StudioNetworkResult()
        result.matchCount = 150
        XCTAssertEqual(result.count, 150)
    }

    func testArtworkExpiryReadsEverySignedSiloArtworkURL() {
        XCTAssertEqual(SiloAPICompatibility.artworkExpiry(siloPoster), Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(
            SiloAPICompatibility.artworkExpiry("/api/v2/artwork/posters/a.webp?exp=1791000000&sig=0f1e2d"),
            Date(timeIntervalSince1970: 1_791_000_000)
        )
        // Signed at 12:00 UTC for four hours.
        XCTAssertEqual(SiloAPICompatibility.artworkExpiry(s3Poster), Date(timeIntervalSince1970: 1_791_388_800))
        // Issued at 12:00 UTC, with Silo's default three-hour token.
        XCTAssertEqual(
            SiloAPICompatibility.artworkExpiry("https://cdn.example.com/posters/a.webp?verify=1791374400-q1w2e3%2Br4%3D"),
            Date(timeIntervalSince1970: 1_791_385_200)
        )
    }

    func testArtworkExpiryIgnoresUnsignedURLs() {
        XCTAssertNil(SiloAPICompatibility.artworkExpiry(embyPoster))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://cdn.example.com/posters/a.webp"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://cdn.example.com/a.webp?exp=1791000000"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://cdn.example.com/a.jpg?X-Amz-Date=20261007T120000Z&X-Amz-Expires=14400"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://silo.example.com/a.webp?exp=soon&sig=0f1e2d"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://silo.example.com/a.webp?exp=nan&sig=0f1e2d"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://silo.example.com/a.webp?exp=inf&sig=0f1e2d"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry(s3Poster.replacingOccurrences(of: "X-Amz-Expires=14400", with: "X-Amz-Expires=nan")))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://cdn.example.com/a.webp?verify=nan-q1w2e3"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://cdn.example.com/a.webp?verify=1791374400"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry("https://cdn.example.com/a.webp?verify=1791374400-"))
        XCTAssertNil(SiloAPICompatibility.artworkExpiry(""))
    }

    func testRootRelativeSiloArtworkKeepsItsExpiry() throws {
        let server = try XCTUnwrap(URL(string: "https://silo.example.com"))
        let url = try XCTUnwrap(SiloAPICompatibility.artworkURL("/api/v2/artwork/posters/a.webp?exp=1791000000&sig=0f1e2d", relativeTo: server))
        XCTAssertEqual(SiloAPICompatibility.artworkExpiry(url.absoluteString), Date(timeIntervalSince1970: 1_791_000_000))
    }

    func testResultsArtworkExpiryIsTheEarliestSignedPoster() throws {
        let items = [
            try item("a", "A", year: 2020, poster: siloPoster),
            try item("b", "B", year: 2020, poster: s3Poster),
            try item("c", "C", year: 2020, poster: embyPoster),
            try item("d", "D", year: 2020),
        ]
        XCTAssertEqual(StudiosNetworksStore.artworkExpiry(of: items), Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertNil(StudiosNetworksStore.artworkExpiry(of: Array(items.suffix(2))))
    }

    func testReplacingArtworkSwapsTitlesByIDAndDropsRemovedOnesFromTheCount() throws {
        var result = StudioNetworkResult()
        result.movies = [try item("a", "A", year: 2020, poster: siloPoster), try item("gone", "Gone", year: 2020, poster: siloPoster)]
        result.all = result.movies
        result.series = [try item("s", "S", year: 2021, type: "series", poster: siloPoster)]
        result.matchCount = 3
        let fresh = [
            try item("a", "A", year: 2020, poster: "https://silo.example.com/api/v2/artwork/a.webp?exp=1791100000&sig=1"),
            try item("s", "S", year: 2021, type: "series", poster: "https://silo.example.com/api/v2/artwork/s.webp?exp=1791100000&sig=2"),
        ]
        let refreshed = try XCTUnwrap(StudiosNetworksStore.replacingArtwork(in: ["pixar": result], with: fresh, tagged: [:])["pixar"])
        XCTAssertEqual(refreshed.movies.map(\.contentId), ["a"])
        XCTAssertEqual(refreshed.all.map(\.contentId), ["a", "s"])
        XCTAssertEqual(refreshed.movies.first?.posterUrl, fresh[0].posterUrl)
        XCTAssertEqual(refreshed.series.first?.posterUrl, fresh[1].posterUrl)
        XCTAssertEqual(refreshed.matchCount, 2)
        XCTAssertEqual(StudiosNetworksStore.artworkExpiry(of: refreshed.items), Date(timeIntervalSince1970: 1_791_100_000))
    }

    func testReplacingArtworkAddsTitlesTheServerNowTags() throws {
        var result = StudioNetworkResult()
        result.series = [try item("s", "S", year: 2021, type: "series")]
        result.all = result.series
        result.matchCount = 1
        let added = try item("new", "New", year: 2026, type: "series")
        let refreshed = try XCTUnwrap(StudiosNetworksStore.replacingArtwork(
            in: ["netflix": result], with: result.series + [added], tagged: ["netflix": [added]]
        )["netflix"])
        XCTAssertEqual(refreshed.all.map(\.contentId), ["new", "s"])
        XCTAssertEqual(refreshed.matchCount, 2)
    }

    private func tagged(_ id: String, type: String = "series", networks: [String]? = nil, studios: [String]? = nil,
                        genres: [String]? = nil, addedAt: String? = nil, releaseDate: String? = nil,
                        title: String? = nil) throws -> BrowseItem {
        var fields: [String: Any] = ["contentId": id, "type": type, "title": title ?? id]
        fields["networks"] = networks
        fields["studios"] = studios
        fields["genres"] = genres
        fields["addedAt"] = addedAt
        fields["releaseDate"] = releaseDate
        return try JSONDecoder().decode(BrowseItem.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testServerTagsMatchWholeNamesIgnoringCaseAndSpaces() throws {
        let matcher = StudiosNetworksStore.tagMatcher
        XCTAssertEqual(matcher.brandIDs(for: try tagged("a", networks: [" netflix "])), ["netflix"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("b", networks: ["Disney Channel", "Disney XD"])), [])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("c", networks: ["Apple TV+"])), ["appletv"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("d", networks: ["Paramount+ with Showtime"])), ["paramountplus"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("e", networks: ["Stanley"])), [])
    }

    func testBritBoxCountsBBCAndITVSeries() throws {
        let matcher = StudiosNetworksStore.tagMatcher
        XCTAssertEqual(matcher.brandIDs(for: try tagged("a", networks: ["BBC One"])), ["britbox"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("b", networks: ["ITV1"])), ["britbox"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("c", networks: ["BBC America"])), [], "A US channel, not BritBox")
    }

    func testNetworksReadStudiosTooAsEmbyKeepsThemThere() throws {
        let matcher = StudiosNetworksStore.tagMatcher
        XCTAssertEqual(matcher.brandIDs(for: try tagged("a", studios: ["Netflix"])), ["netflix"])
        XCTAssertEqual(Set(matcher.brandIDs(for: try tagged("b", type: "movie", studios: ["Columbia Pictures", "Marvel Studios"]))),
                       ["sony", "marvel"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("c", type: "movie", networks: ["Pixar"])), [],
                       "Studios only count a title's studios")
    }

    func testLibraryTitlesPutTaggedFirstAndCountEachOnce() throws {
        let a = try item("a", "A", year: 2020, type: "series")
        let b = try item("b", "B", year: 2021)
        let c = try item("c", "C", year: 2022)
        XCTAssertEqual(StudiosNetworksStore.libraryTitles(tagged: [a, b], matched: [c, a]).map(\.contentId), ["a", "b", "c"])
    }

    func testOnlyNetworksReadTenPagesOfFilms() throws {
        let netflix = try XCTUnwrap(StudiosNetworksStore.catalogue.first { $0.id == "netflix" })
        let pixar = try XCTUnwrap(StudiosNetworksStore.catalogue.first { $0.id == "pixar" })
        XCTAssertEqual(StudiosNetworksStore.moviePages(for: netflix), 10)
        XCTAssertEqual(StudiosNetworksStore.moviePages(for: pixar), StudiosNetworksStore.pagesPerList)
        XCTAssertTrue(StudiosNetworksStore.catalogue.allSatisfy { !($0.libraryNames + $0.libraryNamePrefixes).isEmpty })
    }

    func testBrandsCountTheirOtherNamesAndArms() throws {
        let matcher = StudiosNetworksStore.tagMatcher
        XCTAssertEqual(matcher.brandIDs(for: try tagged("a", networks: ["HBO Max"])), ["hbo"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("b", networks: ["Max"])), ["hbo"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("c", networks: ["Cinemax"])), [])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("d", networks: ["FXX"])), ["fx"])
        XCTAssertEqual(matcher.brandIDs(for: try tagged("e", type: "movie", studios: ["DreamWorks Pictures"])), ["dreamworks"])
        for name in ["Warner Bros. Pictures", "Warner Bros. Animation", "Warner Bros. Television", "Warner Bros. Japan"] {
            XCTAssertEqual(matcher.brandIDs(for: try tagged(name, type: "movie", studios: [name])), ["warnerbros"], name)
        }
        XCTAssertEqual(matcher.brandIDs(for: try tagged("f", type: "movie", networks: ["Warner Bros. Television"])), [],
                       "Studios only count a title's studios")
    }

    func testLibraryFilterSortsNewestAddedFirstWithUndatedLast() throws {
        let items = [
            try tagged("old", addedAt: "2024-01-01T00:00:00Z"),
            try tagged("none"),
            try tagged("new", addedAt: "2026-10-01T00:00:00Z"),
        ]
        XCTAssertEqual(StudioNetworkLibraryFilter().apply(to: items).map(\.contentId), ["new", "old", "none"])
    }

    func testLibraryFilterSortsByReleaseDateAcrossServerFormats() throws {
        let items = [
            try tagged("emby", releaseDate: "2010-07-15T00:00:00.0000000Z"),
            try tagged("silo", releaseDate: "2012-05-04"),
            try tagged("zebra", title: "Zebra"),
            try tagged("apple", title: "Apple"),
        ]
        var filter = StudioNetworkLibraryFilter()
        filter.choose(.releaseDate)
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["silo", "emby", "apple", "zebra"])
        filter.choose(.title)
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["apple", "emby", "silo", "zebra"])
    }

    func testChoosingTheSortAgainFlipsItsOrderKeepingBlanksLast() throws {
        let items = [
            try tagged("old", releaseDate: "2001-01-01"),
            try tagged("none"),
            try tagged("new", releaseDate: "2020-01-01"),
        ]
        var filter = StudioNetworkLibraryFilter()
        filter.choose(.releaseDate)
        XCTAssertEqual(filter.order, .desc)
        filter.choose(.releaseDate)
        XCTAssertEqual(filter.order, .asc)
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["old", "new", "none"])
        filter.choose(.title)
        XCTAssertEqual(filter.order, .asc, "A new key starts in its natural order")
        filter.choose(.title)
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["old", "none", "new"])
    }

    func testResolutionBadgesSortAsHeights() {
        XCTAssertEqual(StudioNetworkLibraryFilter.resolutionHeight("2160p"), 2160)
        XCTAssertEqual(StudioNetworkLibraryFilter.resolutionHeight("4K"), 2160)
        XCTAssertEqual(StudioNetworkLibraryFilter.resolutionHeight("1080p"), 1080)
        XCTAssertEqual(StudioNetworkLibraryFilter.resolutionHeight("SD"), 480)
        XCTAssertNil(StudioNetworkLibraryFilter.resolutionHeight(nil))
    }

    func testLibraryFilterNarrowsByTypeAndGenre() throws {
        let items = [
            try tagged("drama", type: "series", genres: ["Drama"]),
            try tagged("comedy", type: "series", genres: ["Comedy"]),
            try tagged("film", type: "movie", genres: ["Comedy"]),
        ]
        var filter = StudioNetworkLibraryFilter()
        XCTAssertTrue(StudioNetworkLibraryFilter.offersShow(in: items))
        XCTAssertFalse(StudioNetworkLibraryFilter.offersShow(in: Array(items.prefix(2))))
        filter.choose(.title)
        filter.setShow(.series, in: items)
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["comedy", "drama"])
        XCTAssertEqual(filter.genres(in: items), ["Comedy", "Drama"])
        filter.genre = "Drama"
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["drama"])
        XCTAssertTrue(filter.isNarrowed)
        // Movies have no Drama, so the genre is dropped rather than emptying the grid.
        filter.setShow(.movies, in: items)
        XCTAssertNil(filter.genre)
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["film"])
    }

    func testCatalogueIDsAreUniqueAndAppleTVUsesAWordmark() {
        let ids = StudiosNetworksStore.catalogue.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(StudiosNetworksStore.catalogue.first { $0.id == "appletv" }?.usesWordmark, true)
        XCTAssertTrue(StudiosNetworksStore.catalogue.filter { $0.kind == .network }.allSatisfy { !$0.watchProviderIds.isEmpty })
        XCTAssertEqual(StudiosNetworksStore.catalogue.first { $0.id == "stan" }?.watchRegion, "AU")
    }

    func testBritBoxReadsItsSeriesFromItsStreamingList() throws {
        let britbox = try XCTUnwrap(StudiosNetworksStore.catalogue.first { $0.id == "britbox" })
        let (series, movies) = StudiosNetworksStore.discoverQueries(for: britbox)
        XCTAssertNil(series["with_networks"], "TMDb credits BritBox with only a handful of its own series")
        XCTAssertEqual(series["with_watch_providers"], "151|197|1852")
        XCTAssertEqual(series["watch_region"], "US")
        XCTAssertEqual(movies, series)

        let netflix = try XCTUnwrap(StudiosNetworksStore.catalogue.first { $0.id == "netflix" })
        XCTAssertEqual(StudiosNetworksStore.discoverQueries(for: netflix).series, ["with_networks": "213"])

        let fox = try XCTUnwrap(StudiosNetworksStore.catalogue.first { $0.id == "20thcentury" })
        let studio = StudiosNetworksStore.discoverQueries(for: fox)
        XCTAssertEqual(studio.series, ["with_companies": "127928|25"], "20th Century Fox's films count too")
        XCTAssertEqual(studio.movies, studio.series)
    }

    func testMatchesKeepTMDbOrderAndCountEachTitleOnce() throws {
        let fight = try item("a", "Fight Club", year: 1999)
        let index = ["550": fight, StudiosNetworksStore.titleKey("Fight Club", year: 1999): fight]
        let results = [
            try discover(id: 1, title: "Not In Library", date: "2001-01-01"),
            try discover(id: 550, title: "Fight Club", date: "1999-10-15"),
            // The same title again, found by title and year this time.
            try discover(id: 9, title: "Fight Club", date: "1999-10-15"),
        ]
        let found = StudiosNetworksStore.matches(results, index)
        XCTAssertEqual(found.map(\.item.contentId), ["a"])
        XCTAssertTrue(StudiosNetworksStore.matches([], index).isEmpty)
    }

    func testRequestGateNeverRunsMoreThanItsLimit() async throws {
        actor Counter {
            var running = 0, peak = 0, done = 0
            func start() { running += 1; peak = max(peak, running) }
            func finish() { running -= 1; done += 1 }
        }
        let gate = RequestGate(limit: 3)
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.run {
                        await counter.start()
                        try await Task.sleep(for: .milliseconds(5))
                        await counter.finish()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        let done = await counter.done
        XCTAssertEqual(done, 20)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "requests should still overlap")
    }

    func testRequestGateFreesItsSlotWhenARequestFails() async throws {
        struct Failed: Error {}
        let gate = RequestGate(limit: 1)
        do {
            _ = try await gate.run { () async throws -> Int in throw Failed() }
            XCTFail("The failure should come through")
        } catch is Failed {}
        // With the only slot leaked, this would wait forever.
        let value = try await gate.run { 7 }
        XCTAssertEqual(value, 7)
    }
}
