import XCTest
@testable import Vivid

/// Search ranks the library's titles on the device, so typos, spacing and
/// punctuation still find them. These cover each tier, the ranking, the forms
/// of a title with "&", and the titles that mustn't match.
final class LibrarySearchIndexTests: XCTestCase {
    private func item(_ id: String, _ title: String, type: String = "movie", year: Int? = nil) throws -> BrowseItem {
        var object: [String: Any] = ["contentId": id, "type": type, "title": title]
        if let year { object["year"] = year }
        let json = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(BrowseItem.self, from: json)
    }

    /// An index of movies with these titles, numbered from 1.
    private func index(_ titles: String...) throws -> LibrarySearchIndex {
        LibrarySearchIndex(items: try titles.enumerated().map { try item(String($0.offset + 1), $0.element) })
    }

    func testTiersRankExactThenPrefixWordStartContainsAndTypo() throws {
        let index = try index("Superman", "Spidermen", "Notspiderman", "The Amazing Spider-Man", "Spider-Man 2", "Spider-Man")
        let found = index.search("spiderman")

        XCTAssertEqual(found.map(\.item.title), ["Spider-Man", "Spider-Man 2", "The Amazing Spider-Man", "Notspiderman", "Spidermen"])
        XCTAssertEqual(found.map(\.tier), [.exact, .prefix, .wordStart, .contains, .typo])
        XCTAssertEqual(found.map(\.distance), [0, 0, 0, 0, 1])
    }

    func testWordStartAndContainsFindTheQueryInsideATitle() throws {
        let index = try index("X-Men", "Spider-Man")

        let men = index.search("men")
        XCTAssertEqual(men.map(\.item.title), ["X-Men"])
        XCTAssertEqual(men.map(\.tier), [.wordStart])

        let iderman = index.search("iderman")
        XCTAssertEqual(iderman.map(\.item.title), ["Spider-Man"])
        XCTAssertEqual(iderman.map(\.tier), [.contains])
    }

    func testAllWordsMatchInAnyOrderWithTyposInLongerWords() throws {
        let index = try index("Harry Potter and the Chamber of Secrets", "Harry Potter and the Goblet of Fire", "Harry and the Hendersons")

        let goblet = index.search("potter goblet")
        XCTAssertEqual(goblet.map(\.item.title), ["Harry Potter and the Goblet of Fire"])
        XCTAssertEqual(goblet.map(\.tier), [.allWords])

        // `poter` is 5 letters, so it allows a typo; the shorter title comes first.
        let poter = index.search("harry poter")
        XCTAssertEqual(poter.map(\.item.title), ["Harry Potter and the Goblet of Fire", "Harry Potter and the Chamber of Secrets"])
        XCTAssertEqual(poter.map(\.tier), [.allWords, .allWords])
    }

    func testTyposWithinTheQuerysAllowanceStillMatch() throws {
        let index = try index("Spider-Man", "Interstellar", "The Matrix", "The Matrix Reloaded")

        XCTAssertEqual(index.search("spidrman").map(\.item.title), ["Spider-Man"])
        XCTAssertEqual(index.search("interstelar").map(\.item.title), ["Interstellar"])

        // A swapped pair of letters is one edit.
        let matrix = index.search("teh matrix")
        XCTAssertEqual(matrix.map(\.item.title), ["The Matrix", "The Matrix Reloaded"])
        XCTAssertEqual(matrix.map(\.tier), [.typo, .typo])
        XCTAssertEqual(matrix.map(\.distance), [1, 1])
    }

    func testShortQueriesAndOtherTitlesDontMatchAsTypos() throws {
        XCTAssertTrue(try index("Bat").search("cat").isEmpty)
        XCTAssertTrue(try index("Spider-Man").search("superman").isEmpty)
    }

    func testShorterTitlesThenOlderOnesThenTitleOrderComeFirst() throws {
        XCTAssertEqual(try index("Spider-Man 2", "Spider-Man").search("spider").map(\.item.title), ["Spider-Man", "Spider-Man 2"])

        let dunes = LibrarySearchIndex(items: [
            try item("1", "Dune", year: 2021), try item("2", "Dune"), try item("3", "Dune", year: 1984),
        ])
        XCTAssertEqual(dunes.search("dune").map(\.item.contentId), ["3", "1", "2"])

        let spiders = LibrarySearchIndex(items: [try item("1", "Spider-Man", year: 2002), try item("2", "Spider Man", year: 2002)])
        XCTAssertEqual(spiders.search("spiderman").map(\.item.contentId), ["2", "1"])
    }

    func testAmpersandMatchesAsAndOrLeftOut() throws {
        let index = try index("Fast & Furious", "Law & Order")

        for query in ["fast furious", "fast and furious", "Fast & Furious"] {
            XCTAssertEqual(index.search(query).map(\.item.title), ["Fast & Furious"], query)
            XCTAssertEqual(index.search(query).map(\.tier), [.exact], query)
        }
        XCTAssertEqual(index.search("fast & f").map(\.tier), [.prefix])
        XCTAssertEqual(index.search("law order").map(\.item.title), ["Law & Order"])
    }

    func testTypesKeepOnlyThoseTypes() throws {
        let index = LibrarySearchIndex(items: [try item("1", "Dune"), try item("2", "Dune", type: "series")])

        XCTAssertEqual(index.search("dune").map(\.item.contentId), ["1", "2"])
        XCTAssertEqual(index.search("dune", types: ["series"]).map(\.item.contentId), ["2"])
        XCTAssertEqual(index.search("dune", types: ["movie", "series"]).count, 2)
        XCTAssertTrue(index.search("dune", types: []).isEmpty)
    }

    func testLimitKeepsTheBestMatches() throws {
        let index = try index("Star Wars", "Star", "Starman", "Stardust", "A Star Is Born")

        XCTAssertEqual(index.search("star", limit: 2).map(\.item.title), ["Star", "Starman"])
        XCTAssertTrue(index.search("star", limit: 0).isEmpty)
    }

    func testDuplicateContentIDsKeepTheFirst() throws {
        let index = LibrarySearchIndex(items: [try item("1", "Dune"), try item("1", "Arrival"), try item("2", "Arrival")])

        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.search("dune").map(\.item.contentId), ["1"])
        XCTAssertEqual(index.search("arrival").map(\.item.contentId), ["2"])
    }

    func testQueriesWithoutLettersOrDigitsFindNothing() throws {
        let index = try index("Dune", "?!", "Pride and Prejudice")

        // A lone "&" would otherwise read as "and".
        for query in ["", "   ", "?!", "-", "&"] {
            XCTAssertTrue(index.search(query).isEmpty, query)
        }
        XCTAssertEqual(index.count, 3)
    }

    func testStrongMatchesAreThoseTheQueryReadsAs() throws {
        let spider = try index("Spider-Man", "Spider-Man 2", "The Amazing Spider-Man", "Notspiderman", "Spidermen").search("spiderman")
        XCTAssertEqual(spider.map(\.tier), [.exact, .prefix, .wordStart, .contains, .typo])
        XCTAssertEqual(spider.map(\.isStrong), [true, true, true, false, false])

        let words = try index("Harry Potter and the Goblet of Fire").search("goblet potter")
        XCTAssertEqual(words.map(\.tier), [.allWords])
        XCTAssertEqual(words.map(\.isStrong), [true])
    }

    func testATypoFindsItsTitleFirstAmongTwentyThousand() throws {
        let words = [
            "Red", "Blue", "Night", "City", "River", "Storm", "Silent", "Golden", "Lost", "Hidden",
            "Last", "Dark", "Bright", "Winter", "Summer", "Ocean", "Mountain", "Shadow", "Iron", "Glass",
        ]
        var objects: [[String: Any]] = (0..<20_000).map { index -> [String: Any] in
            [
                "contentId": String(index),
                "type": index % 3 == 0 ? "series" : "movie",
                "title": "\(words[index % 20]) \(words[(index / 20) % 20]) \(index)",
                "year": 1950 + index % 75,
            ]
        }
        objects[12_345] = ["contentId": "12345", "type": "movie", "title": "Interstellar", "year": 2014]
        objects[777] = ["contentId": "777", "type": "movie", "title": "Interstate 60", "year": 2002]
        objects[15_000] = ["contentId": "15000", "type": "movie", "title": "Interstella 5555", "year": 2003]
        objects[19_999] = ["contentId": "19999", "type": "movie", "title": "Interstellar Wars", "year": 2016]
        let json = try JSONSerialization.data(withJSONObject: objects)
        let index = LibrarySearchIndex(items: try JSONDecoder().decode([BrowseItem].self, from: json))
        XCTAssertEqual(index.count, 20_000)

        let found = index.search("interstelar")
        XCTAssertEqual(found.map(\.item.title), ["Interstellar", "Interstellar Wars", "Interstella 5555"])
        XCTAssertEqual(found.map(\.distance), [1, 1, 2])
    }
}
