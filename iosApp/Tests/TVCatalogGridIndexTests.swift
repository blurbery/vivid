#if os(tvOS)
import XCTest
@testable import VividTV

final class TVCatalogGridIndexTests: XCTestCase {
    private func items(_ ids: [String]) throws -> [BrowseItem] {
        let json = ids.map { #"{"contentId":"\#($0)","type":"movie","title":"\#($0)"}"# }
        return try JSONDecoder().decode([BrowseItem].self, from: Data("[\(json.joined(separator: ","))]".utf8))
    }

    func testLookupMatchesFirstIndex() throws {
        let list = try items(["a", "b", "c", "b"])
        var index = TVCatalogItemIndex()
        index.rebuild(list)
        for id in ["a", "b", "c", "missing"] {
            XCTAssertEqual(index.index(of: id, in: list), list.firstIndex { $0.contentId == id }, id)
        }
    }

    func testStaleMapFallsBackToCurrentItems() throws {
        var index = TVCatalogItemIndex()
        index.rebuild(try items(["a", "b", "c"]))
        // A page arrives or the list is replaced before the map is rebuilt.
        let appended = try items(["a", "b", "c", "d", "e"])
        XCTAssertEqual(index.index(of: "e", in: appended), 4)
        let replaced = try items(["c", "x"])
        XCTAssertEqual(index.index(of: "c", in: replaced), 0)
        XCTAssertNil(index.index(of: "a", in: replaced))
    }

    func testSignatureTracksAppendsAndReplacements() throws {
        let base = TVCatalogItemIndex.Signature(try items(["a", "b"]))
        XCTAssertEqual(base, TVCatalogItemIndex.Signature(try items(["a", "b"])))
        XCTAssertNotEqual(base, TVCatalogItemIndex.Signature(try items(["a", "b", "c"])))
        XCTAssertNotEqual(base, TVCatalogItemIndex.Signature(try items(["b", "a"])))
    }

    func testArtworkRangePrefersVisibleRowOverFocus() {
        XCTAssertEqual(TVPosterArtworkWindow.range(firstVisible: 70, focusedIndex: 7, itemCount: 300, columns: 7), 56..<126)
        XCTAssertEqual(TVPosterArtworkWindow.range(firstVisible: nil, focusedIndex: 70, itemCount: 300, columns: 7), 56..<126)
    }
}
#endif
