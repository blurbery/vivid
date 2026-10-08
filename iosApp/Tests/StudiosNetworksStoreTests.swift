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
        XCTAssertEqual(rows.map(\.title), ["Popular Series", "Popular Movies"])
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
        XCTAssertEqual(picks, ["hbo", "disneyplus", "netflix", "appletv", "marvel", "pixar"])
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
        let refreshed = try XCTUnwrap(StudiosNetworksStore.replacingArtwork(in: ["pixar": result], with: fresh)["pixar"])
        XCTAssertEqual(refreshed.movies.map(\.contentId), ["a"])
        XCTAssertEqual(refreshed.all.map(\.contentId), ["a"])
        XCTAssertEqual(refreshed.movies.first?.posterUrl, fresh[0].posterUrl)
        XCTAssertEqual(refreshed.series.first?.posterUrl, fresh[1].posterUrl)
        XCTAssertEqual(refreshed.matchCount, 2)
        XCTAssertEqual(StudiosNetworksStore.artworkExpiry(of: refreshed.items), Date(timeIntervalSince1970: 1_791_100_000))
    }

    func testCatalogueIDsAreUniqueAndAppleTVUsesAWordmark() {
        let ids = StudiosNetworksStore.catalogue.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(StudiosNetworksStore.catalogue.first { $0.id == "appletv" }?.usesWordmark, true)
        XCTAssertTrue(StudiosNetworksStore.catalogue.filter { $0.kind == .network }.allSatisfy { !$0.watchProviderIds.isEmpty })
        XCTAssertEqual(StudiosNetworksStore.catalogue.first { $0.id == "stan" }?.watchRegion, "AU")
    }
}
