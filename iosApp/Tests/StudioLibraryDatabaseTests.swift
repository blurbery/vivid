import XCTest
@testable import Vivid

final class StudioLibraryDatabaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func item(_ id: String, _ title: String, year: Int?, type: String = "movie",
                      networks: [String]? = nil, poster: String? = nil) throws -> BrowseItem {
        var fields: [String: Any] = ["contentId": id, "type": type, "title": title]
        fields["year"] = year
        fields["networks"] = networks
        fields["posterUrl"] = poster
        return try JSONDecoder().decode(BrowseItem.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func entry(_ item: BrowseItem, tmdb: String? = nil) -> StudioLibraryDatabase.Entry {
        StudioLibraryDatabase.Entry(item: item, tmdbId: tmdb)
    }

    func testKeysGoToTheFirstTitleAndRepeatsAreSkipped() throws {
        let library = try StudioLibraryDatabase(url: folder.appendingPathComponent("a.sqlite"), writable: true)
        try library.add([
            entry(try item("1", "Dune", year: 2021), tmdb: "438631"),
            entry(try item("2", "Dune", year: 2021)),
            entry(try item("3", "Arrival", year: nil)),
        ], media: .movie, progress: .init(offset: 3, isDone: false))
        // A title added on the server shifts the next page, so one comes twice.
        try library.add([entry(try item("3", "Arrival", year: nil))], media: .movie, progress: .init(offset: 4, isDone: true))

        XCTAssertEqual(library.item(media: .movie, key: "438631")?.contentId, "1")
        let byTitle = try XCTUnwrap(library.lookup(media: .movie, key: StudiosNetworksStore.titleKey("Dune", year: 2021)))
        XCTAssertEqual(byTitle.item.contentId, "1", "The first title keeps its title and year key")
        XCTAssertEqual(byTitle.tmdbId, "438631")
        XCTAssertNil(library.item(media: .series, key: "438631"), "Movies and series keep separate keys")
        XCTAssertEqual(library.titleCount, 3)
        XCTAssertEqual(Set(library.searchTitles().map(\.contentId)), ["1", "2", "3"], "Search reads every title")
        XCTAssertEqual(library.progress(.movie), .init(offset: 4, isDone: true))
        XCTAssertNil(library.progress(.series))
    }

    func testItemsKeepTheOrderAskedForAndSkipMissingOnes() throws {
        let library = try StudioLibraryDatabase(url: folder.appendingPathComponent("b.sqlite"), writable: true)
        let titles = try (0..<1_200).map { try item("m\($0)", "Film \($0)", year: 2000) }
        try library.add(titles.map { entry($0) }, media: .movie, progress: .init(offset: 1_200, isDone: true))
        let wanted = ["m1199", "gone", "m0", "m600"]
        XCTAssertEqual(library.items(contentIds: wanted).map(\.contentId), ["m1199", "m0", "m600"])
        XCTAssertEqual(library.items(contentIds: titles.map(\.contentId)).count, 1_200, "Long lists are read in chunks")
    }

    func testTagsListMoviesThenSeriesInReadOrder() throws {
        let library = try StudioLibraryDatabase(url: folder.appendingPathComponent("c.sqlite"), writable: true)
        try library.add([entry(try item("s1", "B Show", year: 2020, type: "series", networks: ["Netflix"]))],
                        media: .series, progress: .init(offset: 1, isDone: true))
        try library.add([
            entry(try item("f1", "A Film", year: 2020, networks: ["Netflix"])),
            entry(try item("f2", "C Film", year: 2021)),
        ], media: .movie, progress: .init(offset: 2, isDone: true))
        XCTAssertEqual(library.taggedIDs(brand: "netflix"), ["f1", "s1"])
        XCTAssertEqual(library.taggedIDs(brand: "hbo"), [])
    }

    func testProgressAndTitlesSurviveReopeningAndReadOnlyOpens() throws {
        let url = folder.appendingPathComponent("d.sqlite")
        do {
            let library = try StudioLibraryDatabase(url: url, writable: true)
            try library.add([entry(try item("1", "Dune", year: 2021))], media: .movie, progress: .init(offset: 200, isDone: false))
            try library.setMeta("revision", value: "5")
        }
        let reopened = try StudioLibraryDatabase(url: url, writable: false)
        XCTAssertEqual(reopened.progress(.movie), .init(offset: 200, isDone: false))
        XCTAssertEqual(reopened.meta("revision"), "5")
        XCTAssertEqual(reopened.titleCount, 1)
    }

    func testEarliestPosterExpiryIgnoresUnsignedLinks() throws {
        let library = try StudioLibraryDatabase(url: folder.appendingPathComponent("e.sqlite"), writable: true)
        XCTAssertNil(library.earliestPosterExpiry())
        try library.add([
            entry(try item("1", "A", year: 2020, poster: "https://silo.example.com/api/v2/artwork/a.webp?exp=1791100000&sig=1")),
            entry(try item("2", "B", year: 2020, poster: "https://silo.example.com/api/v2/artwork/b.webp?exp=1791000000&sig=2")),
            entry(try item("3", "C", year: 2020, poster: "https://emby.example.com/Items/3/Images/Primary?tag=x")),
        ], media: .movie, progress: .init(offset: 3, isDone: true))
        XCTAssertEqual(library.earliestPosterExpiry(), Date(timeIntervalSince1970: 1_791_000_000))
    }
}
