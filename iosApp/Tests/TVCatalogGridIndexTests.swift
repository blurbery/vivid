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

    func testLookupPerformanceOnLargeCatalogue() throws {
        let list = try items((0..<5_000).map { "item-\($0)" })
        let paged = try items((0..<5_100).map { "item-\($0)" })
        let targets = stride(from: 0, to: 5_100, by: 7).map { "item-\($0)" } + ["missing"]
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var found = 0
        measure(metrics: [XCTClockMetric()], options: options) {
            var index = TVCatalogItemIndex()
            index.rebuild(list)
            // Current map hits, then a page appended before the rebuild.
            found = targets.reduce(0) { $0 + (index.index(of: $1, in: list) == nil ? 0 : 1) }
            found += targets.reduce(0) { $0 + (index.index(of: $1, in: paged) == nil ? 0 : 1) }
        }
        XCTAssertEqual(found, 715 + 729)
    }

    func testArtworkRangePrefersVisibleRowOverFocus() {
        XCTAssertEqual(TVPosterArtworkWindow.range(firstVisible: 70, focusedIndex: 7, itemCount: 300, columns: 7), 56..<126)
        XCTAssertEqual(TVPosterArtworkWindow.range(firstVisible: nil, focusedIndex: 70, itemCount: 300, columns: 7), 56..<126)
    }
}
#endif
