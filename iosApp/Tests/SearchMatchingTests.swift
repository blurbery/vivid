import XCTest
@testable import Vivid

/// Search finds titles whatever their spacing and punctuation, so `spiderman`
/// finds Spider-Man. These cover the pieces Search asks the server for and
/// which of their results it adds.
final class SearchMatchingTests: XCTestCase {
    private func item(_ id: String, _ title: String, type: String = "movie") throws -> BrowseItem {
        let json = try JSONSerialization.data(withJSONObject: ["contentId": id, "type": type, "title": title])
        return try JSONDecoder().decode(BrowseItem.self, from: json)
    }

    func testKeyKeepsOnlyLettersAndDigitsWithoutCaseOrAccents() {
        XCTAssertEqual(SearchMatching.key("Spider-Man: No Way Home"), "spidermannowayhome")
        XCTAssertEqual(SearchMatching.key("Ocean's Eleven"), "oceanseleven")
        XCTAssertEqual(SearchMatching.key("WALL·E"), "walle")
        XCTAssertEqual(SearchMatching.key("Amélie"), "amelie")
        XCTAssertEqual(SearchMatching.key("Se7en"), "se7en")
    }

    func testPiecesStartTheLongestWordAndKeepItWhole() {
        // The start of a single word finds the title that splits it.
        XCTAssertEqual(SearchMatching.pieces(of: "spiderman"), ["spide"])
        XCTAssertEqual(SearchMatching.pieces(of: "antman"), ["ant"])
        XCTAssertEqual(SearchMatching.pieces(of: "walle"), ["wal"])
        XCTAssertEqual(SearchMatching.pieces(of: "Schitts"), ["schi"])
        // Several words add the longest on its own as well.
        XCTAssertEqual(SearchMatching.pieces(of: "mission impossible"), ["impossible", "impos"])
        XCTAssertEqual(SearchMatching.pieces(of: "oceans eleven"), ["oceans", "oce"])
        XCTAssertEqual(SearchMatching.pieces(of: "spider-man"), ["spider", "spi"])
        XCTAssertEqual(SearchMatching.pieces(of: "Amélie"), ["ame"])
    }

    func testShortQueriesAddNoPieces() {
        XCTAssertEqual(SearchMatching.pieces(of: "it"), [])
        XCTAssertEqual(SearchMatching.pieces(of: "her"), [])
        XCTAssertEqual(SearchMatching.pieces(of: "dune"), [])
        XCTAssertEqual(SearchMatching.pieces(of: "x men"), [])
        XCTAssertEqual(SearchMatching.pieces(of: "  "), [])
        XCTAssertEqual(SearchMatching.pieces(of: "?!"), [])
    }

    func testSplitsHyphenateTheLongestWordBeforeThePiecesStart() {
        XCTAssertEqual(SearchMatching.splits(of: "xmen"), ["x-men", "xm-en"])
        XCTAssertEqual(SearchMatching.splits(of: "heman"), ["h-eman", "he-man"])
        XCTAssertEqual(SearchMatching.splits(of: "toystory"), ["t-oystory", "to-ystory", "toy-story"])
        XCTAssertEqual(SearchMatching.splits(of: "HarryPotter"),
                       ["h-arrypotter", "ha-rrypotter", "har-rypotter", "harr-ypotter", "harry-potter"])
        // A long word stops at five, so its first title word can be up to five letters.
        XCTAssertEqual(SearchMatching.splits(of: "supercalifragilistic").count, 5)
        // Splits from the second half on are already the pieces' to find.
        XCTAssertEqual(SearchMatching.splits(of: "spiderman"), ["s-piderman", "sp-iderman", "spi-derman", "spid-erman"])
        XCTAssertEqual(SearchMatching.splits(of: "her"), [])
        XCTAssertEqual(SearchMatching.splits(of: "x men"), [])
    }

    func testHasMatchLooksForTheQueryInEachTitle() throws {
        let xMen = try item("1", "X-Men: First Class")
        let xanadu = try item("2", "Xanadu")
        XCTAssertTrue(SearchMatching.hasMatch(in: [xanadu, xMen], query: "xmen"))
        XCTAssertFalse(SearchMatching.hasMatch(in: [xanadu], query: "xmen"))
        XCTAssertFalse(SearchMatching.hasMatch(in: [], query: "xmen"))
        XCTAssertFalse(SearchMatching.hasMatch(in: [xMen], query: "--"))
    }

    func testMatchesKeepTitlesHoldingTheQueryWhateverTheirPunctuation() throws {
        let amazing = try item("1", "The Amazing Spider-Man")
        let spiderMan = try item("2", "Spider-Man")
        let spiders = try item("3", "Spiders")
        let superman = try item("4", "Superman")
        let series = try item("5", "Spider-Man: The Animated Series", type: "series")

        let found = SearchMatching.matches(in: [[amazing, spiders, spiderMan], [superman, spiderMan, series]], query: "spiderman")

        // Those that start with the query come first, then the server's order, each once.
        XCTAssertEqual(found.map(\.contentId), ["2", "5", "1"])
    }

    func testMatchesFollowTheQueryAcrossApostrophesAndAccents() throws {
        let oceans = try item("1", "Ocean's Eleven")
        let amelie = try item("2", "Amélie")
        XCTAssertEqual(SearchMatching.matches(in: [[oceans]], query: "oceans eleven").map(\.contentId), ["1"])
        XCTAssertEqual(SearchMatching.matches(in: [[amelie]], query: "amelie").map(\.contentId), ["2"])
        XCTAssertEqual(SearchMatching.matches(in: [[oceans, amelie]], query: "--").map(\.contentId), [])
    }
}
