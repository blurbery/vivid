import XCTest
@testable import Vivid

/// The catalogue query each filter state produces, for Silo's grouped rules
/// and the flat Emby and Jellyfin keys, and the filter state's own rules.
final class CatalogQueryTests: XCTestCase {
    private func build(
        _ state: CatalogFilterState,
        libraryId: Int? = 1,
        mediaType: BrowseMediaType = .movie,
        includeType: Bool = false
    ) -> [String: String] {
        CatalogQueryBuilder.build(
            state,
            libraryId: libraryId,
            mediaType: mediaType,
            offset: 0,
            limit: 60,
            includeType: includeType,
            provider: .silo
        )
    }

    private func assertRule(
        _ query: [String: String],
        group: Int,
        rule: Int,
        field: String,
        op: String? = nil,
        value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prefix = "groups[\(group)][rules][\(rule)]"
        XCTAssertEqual(query["\(prefix)[field]"], field, file: file, line: line)
        if let op { XCTAssertEqual(query["\(prefix)[op]"], op, file: file, line: line) }
        XCTAssertEqual(query["\(prefix)[value]"], value, file: file, line: line)
    }

    func testEmbyDropsSiloOnlyFilters() throws {
        var state = CatalogFilterState()
        state.sort = .addedAt
        state.order = .asc
        state.namePrefix = "B"
        state.matchAll = false
        state.mediaScope = "series"
        state.genres = ["Drama"]
        state.contentRatings = ["PG"]
        state.decades = [1990]
        state.watchStatus = .watchlist
        state.studios = ["A24"]
        state.networks = ["HBO"]
        state.countries = ["AU"]
        state.resolutions = ["4K"]
        state.audioLanguages = ["eng"]
        state.subtitleLanguages = ["eng"]
        state.originalLanguages = ["eng"]
        state.hdr = true
        state.dolbyVision = true

        let decoded = try JSONDecoder().decode(CatalogFilterState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.normalized(for: .silo), state)

        let cleaned = decoded.normalized(for: .emby)
        XCTAssertTrue(cleaned.matchAll)
        XCTAssertEqual(cleaned.activeFacetCount, 5)
        XCTAssertEqual(
            Set(cleaned.activeChips.map(\.facet)),
            [.itemType, .genre, .contentRating, .decade, .watchStatus]
        )
        XCTAssertEqual(cleaned.sort, .addedAt)
        XCTAssertEqual(cleaned.order, .asc)
        XCTAssertEqual(cleaned.namePrefix, "B")
        XCTAssertEqual(cleaned.normalized(for: .emby), cleaned)

        let query = CatalogQueryBuilder.embyQuery(cleaned, base: [:])
        XCTAssertEqual(query["genre"], "Drama")
        XCTAssertEqual(query["content_rating"], "PG")
        XCTAssertEqual(query["source"], "watchlist")
        XCTAssertEqual(query["type"], "series")
        XCTAssertEqual(Set(query.keys), ["genre", "content_rating", "source", "type", "years"])
    }

    func testEmbyAndJellyfinFlattenTheGroups() {
        var state = CatalogFilterState()
        state.genres = ["Action", "Drama"]
        state.contentRatings = ["PG", "R"]
        state.decades = [1990]
        state.watchStatus = .inProgress
        let base = [
            "library_id": "12",
            "offset": "40",
            "limit": "20",
            "name_prefix": "B",
            "groups[0][match]": "any",
            "match": "any",
        ]

        let query = CatalogQueryBuilder.embyQuery(state, base: base)
        XCTAssertEqual(query["genre"], "Action|Drama")
        XCTAssertEqual(query["content_rating"], "PG|R")
        XCTAssertEqual(query["years"], (1990...1999).map(String.init).joined(separator: ","))
        XCTAssertEqual(query["emby_watch_status"], "inProgress")
        XCTAssertEqual(query["library_id"], "12")
        XCTAssertEqual(query["offset"], "40")
        XCTAssertEqual(query["name_prefix"], "B")
        XCTAssertNil(query["match"])
        XCTAssertFalse(query.keys.contains { $0.hasPrefix("groups[") })

        let jellyfin = CatalogQueryBuilder.jellyfinQuery(state, base: base)
        XCTAssertEqual(jellyfin["jellyfin_watch_status"], "inProgress")
        XCTAssertNil(jellyfin["emby_watch_status"])
    }

    func testDefaultState() {
        let query = build(CatalogFilterState(), libraryId: 5)
        XCTAssertEqual(query["source"], "query")
        XCTAssertEqual(query["sort"], "title")
        XCTAssertEqual(query["order"], "asc")
        XCTAssertEqual(query["match"], "all")
        XCTAssertEqual(query["library_id"], "5")
        XCTAssertEqual(query["offset"], "0")
        XCTAssertEqual(query["limit"], "60")
        XCTAssertNil(query["type"])
        XCTAssertNil(query["groups[0][match]"])
    }

    func testSortAddedDefaultsToDescending() {
        var state = CatalogFilterState()
        state.sort = .addedAt
        let query = build(state)
        XCTAssertEqual(query["sort"], "added_at")
        XCTAssertEqual(query["order"], "desc")
    }

    func testExplicitOrder() {
        var state = CatalogFilterState()
        state.order = .desc
        XCTAssertEqual(build(state)["order"], "desc")
    }

    func testEverySortOrderAndTypeIsDistinct() {
        var keys: [String] = []
        for mediaType in [BrowseMediaType.movie, .series] {
            for sort in CatalogSortKey.available(for: mediaType) {
                for order in [CatalogSortOrder.asc, .desc] {
                    var state = CatalogFilterState()
                    state.sort = sort
                    state.order = order
                    let query = build(state, mediaType: mediaType, includeType: true)
                    XCTAssertEqual(query["sort"], sort.rawValue)
                    XCTAssertEqual(query["order"], order.rawValue)
                    XCTAssertEqual(query["type"], mediaType.rawValue)
                    keys.append("type=\(mediaType.rawValue)|\(state.cacheKeyFragment)")
                }
            }
        }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testSnapshotIsPassedThrough() {
        let query = CatalogQueryBuilder.build(
            CatalogFilterState(),
            libraryId: 5,
            mediaType: .series,
            offset: 100,
            limit: 100,
            snapshot: "2026-09-05T10:00:00Z",
            provider: .silo
        )
        XCTAssertEqual(query["snapshot"], "2026-09-05T10:00:00Z")
        XCTAssertNil(query["snapshot_at"])
        XCTAssertEqual(query["offset"], "100")
    }

    func testTypeOnlyWhenAsked() {
        XCTAssertEqual(build(CatalogFilterState(), mediaType: .series, includeType: true)["type"], "series")
        XCTAssertNil(build(CatalogFilterState(), mediaType: .series, includeType: false)["type"])
    }

    func testMixedLibraryUsesTheScopeRule() {
        XCTAssertNil(build(CatalogFilterState(), mediaType: .mixed, includeType: true)["type"])

        var state = CatalogFilterState()
        state.mediaScope = "series"
        let query = build(state, mediaType: .mixed)
        XCTAssertNil(query["type"])
        XCTAssertEqual(query["groups[0][match]"], "all")
        assertRule(query, group: 0, rule: 0, field: "type", op: "is", value: "series")
        XCTAssertNil(build(state, mediaType: .mixed, includeType: true)["type"])
    }

    func testMatchAnyWithScopeAndGenre() {
        var state = CatalogFilterState()
        state.matchAll = false
        state.mediaScope = "movie"
        state.genres = ["Drama"]
        let query = build(state, mediaType: .mixed)
        XCTAssertEqual(query["match"], "any")
        XCTAssertNil(query["type"])
        assertRule(query, group: 0, rule: 0, field: "type", value: "movie")
        assertRule(query, group: 1, rule: 0, field: "genre", value: "Drama")
    }

    func testGenreIsSingleSelect() {
        var state = CatalogFilterState()
        state.toggle(.genre, value: "Horror")
        XCTAssertEqual(state.genres, ["Horror"])
        state.toggle(.genre, value: "Comedy")
        XCTAssertEqual(state.genres, ["Comedy"])
        state.toggle(.genre, value: "Comedy")
        XCTAssertTrue(state.genres.isEmpty)
    }

    func testGenresAreSortedRules() {
        var state = CatalogFilterState()
        state.genres = ["Drama", "Action"]
        let query = build(state)
        XCTAssertEqual(query["groups[0][match]"], "any")
        assertRule(query, group: 0, rule: 0, field: "genre", op: "contains", value: "Action")
        assertRule(query, group: 0, rule: 1, field: "genre", op: "contains", value: "Drama")
    }

    func testDecadeIsAYearRange() {
        var state = CatalogFilterState()
        state.decades = [2010]
        let query = build(state)
        XCTAssertEqual(query["groups[0][rules][0][field]"], "year")
        XCTAssertEqual(query["groups[0][rules][0][op]"], "between")
        XCTAssertEqual(query["groups[0][rules][0][value][0]"], "2010")
        XCTAssertEqual(query["groups[0][rules][0][value][1]"], "2019")
    }

    func testUnwatched() {
        var state = CatalogFilterState()
        state.watchStatus = .unwatched
        assertRule(build(state), group: 0, rule: 0, field: "watched", op: "is", value: "false")
    }

    func testHDR() {
        var state = CatalogFilterState()
        state.hdr = true
        assertRule(build(state), group: 0, rule: 0, field: "hdr", op: "is", value: "true")
    }

    func testHDRAndDolbyVisionShareAGroup() {
        var state = CatalogFilterState()
        state.hdr = true
        state.dolbyVision = true
        let query = build(state)
        XCTAssertEqual(query["groups[0][match]"], "any")
        assertRule(query, group: 0, rule: 0, field: "hdr", op: "is", value: "true")
        assertRule(query, group: 0, rule: 1, field: "dolby_vision", op: "is", value: "true")
        XCTAssertNil(query["groups[1][match]"])
    }

    func testMatchAny() {
        var state = CatalogFilterState()
        state.matchAll = false
        XCTAssertEqual(build(state)["match"], "any")
    }

    func testIncludeTotalFalse() {
        let query = CatalogQueryBuilder.build(
            CatalogFilterState(),
            libraryId: 1,
            mediaType: .movie,
            offset: 0,
            limit: 1,
            includeTotal: false,
            includeType: false,
            provider: .silo
        )
        XCTAssertEqual(query["include_total"], "false")
    }

    func testFragmentIgnoresSetOrder() {
        var first = CatalogFilterState()
        first.genres = ["Drama", "Action"]
        first.decades = [2010]
        var second = CatalogFilterState()
        second.genres = ["Action", "Drama"]
        second.decades = [2010]
        XCTAssertEqual(first.cacheKeyFragment, second.cacheKeyFragment)
    }

    func testFragmentEscapesSeparators() {
        var joined = CatalogFilterState()
        joined.genres = ["A,B"]
        var split = CatalogFilterState()
        split.genres = ["A", "B"]
        XCTAssertNotEqual(joined.cacheKeyFragment, split.cacheKeyFragment)

        var prefixWithBar = CatalogFilterState()
        prefixWithBar.namePrefix = "A|B"
        var prefixAndGenre = CatalogFilterState()
        prefixAndGenre.namePrefix = "A"
        prefixAndGenre.genres = ["B"]
        XCTAssertNotEqual(prefixWithBar.cacheKeyFragment, prefixAndGenre.cacheKeyFragment)
    }

    func testResetKeepsSortAndPrefix() {
        var state = CatalogFilterState()
        state.sort = .addedAt
        state.order = .asc
        state.namePrefix = "M"
        state.genres = ["Drama"]
        state.hdr = true
        state.matchAll = false
        state.resetFilters()
        XCTAssertEqual(state.sort, .addedAt)
        XCTAssertEqual(state.order, .asc)
        XCTAssertEqual(state.namePrefix, "M")
        XCTAssertTrue(state.genres.isEmpty)
        XCTAssertFalse(state.hdr)
        XCTAssertTrue(state.matchAll)
    }
}
