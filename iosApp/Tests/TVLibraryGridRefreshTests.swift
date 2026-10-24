#if os(tvOS)
import XCTest
@testable import VividTV

/// A grid opened again paints its cached page 1, then fetches it once more
/// so titles added since show up, without disturbing a grid that has paged.
@MainActor
final class TVLibraryGridRefreshTests: XCTestCase {
    private var libraryIds: [Int] = []

    override func tearDown() {
        for id in libraryIds {
            ResponseCache.shared.removeAll(withPrefix: "tvlibrary:\(id):")
            BrowsePrefsStore.shared.clearState(libraryId: id, mediaScope: "movie")
        }
        libraryIds = []
        super.tearDown()
    }

    private func library(_ id: Int) -> Int {
        libraryIds.append(id)
        return id
    }

    private func page(_ ids: [String], snapshot: String = "s", hasMore: Bool = false) throws -> CatalogResponse {
        let items = ids.map { #"{"content_id":"\#($0)","type":"movie","title":"\#($0)"}"# }
        let json = #"{"items":[\#(items.joined(separator: ","))],"has_more":\#(hasMore),"snapshot":"\#(snapshot)"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CatalogResponse.self, from: Data(json.utf8))
    }

    /// Opens the library once so its page 1 is in the response cache.
    private func seedCache(libraryId: Int, _ response: CatalogResponse) async {
        let first = TVLibraryGridViewModel(libraryId: libraryId, libraryType: "movies") { _ in response }
        await first.loadInitial()
        XCTAssertEqual(first.items.map(\.contentId), response.items.map(\.contentId))
        XCTAssertTrue(first.hasRequestedFirstPage)
    }

    func testReopenedGridShowsNewTitlesAndPagesFromTheFreshSnapshot() async throws {
        let id = library(990_101)
        await seedCache(libraryId: id, try page(["a", "b"], snapshot: "old", hasMore: true))
        let fresh = try page(["new", "a", "b"], snapshot: "fresh", hasMore: true)
        let next = try page(["c"], snapshot: "fresh")
        var queries: [[String: String]] = []
        let model = TVLibraryGridViewModel(libraryId: id, libraryType: "movies") { query in
            queries.append(query)
            return query["offset"] == "0" ? fresh : next
        }

        // Reopening paints the cached page without asking the server.
        XCTAssertEqual(model.items.map(\.contentId), ["a", "b"])
        XCTAssertFalse(model.hasRequestedFirstPage)
        XCTAssertTrue(queries.isEmpty)

        await model.refreshFirstPage()
        XCTAssertEqual(model.items.map(\.contentId), ["new", "a", "b"])
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first?["offset"], "0")
        XCTAssertNil(queries.first?["snapshot"])
        XCTAssertTrue(model.hasRequestedFirstPage)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.isLoading)

        // Later pages are fenced to the new snapshot, not the cached one.
        await model.loadMoreIfNeeded()
        XCTAssertEqual(queries.last?["snapshot"], "fresh")
        XCTAssertEqual(queries.last?["offset"], "3")
        XCTAssertEqual(model.items.map(\.contentId), ["new", "a", "b", "c"])

        // The next visit paints the refreshed page.
        let reopened = TVLibraryGridViewModel(libraryId: id, libraryType: "movies") { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(reopened.items.map(\.contentId), ["new", "a", "b"])
    }

    func testFailedOrCancelledRefetchKeepsTheCachedPageAndCountsAsTried() async throws {
        let failures: [Error] = [URLError(.notConnectedToInternet), CancellationError()]
        for (offset, failure) in failures.enumerated() {
            let id = library(990_201 + offset)
            await seedCache(libraryId: id, try page(["a", "b"]))
            let model = TVLibraryGridViewModel(libraryId: id, libraryType: "movies") { _ in throw failure }

            await model.refreshFirstPage()
            XCTAssertEqual(model.items.map(\.contentId), ["a", "b"], "\(failure)")
            XCTAssertNil(model.error, "\(failure)")
            // Set, so returning from a title doesn't try again and shift the grid.
            XCTAssertTrue(model.hasRequestedFirstPage, "\(failure)")
            XCTAssertFalse(model.isRefreshing, "\(failure)")
            XCTAssertFalse(model.isLoading, "\(failure)")
        }
    }

    func testRefetchLeavesAGridThatHasPagedAlone() async throws {
        let id = library(990_301)
        let first = try page(["a", "b"], hasMore: true)
        let second = try page(["c"])
        var requests = 0
        let model = TVLibraryGridViewModel(libraryId: id, libraryType: "movies") { query in
            requests += 1
            return query["offset"] == "0" ? first : second
        }
        await model.loadInitial()
        await model.loadMoreIfNeeded()
        XCTAssertEqual(requests, 2)

        await model.refreshFirstPage()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.items.map(\.contentId), ["a", "b", "c"])
    }

    func testSortChangeDuringRefetchWins() async throws {
        let id = library(990_401)
        await seedCache(libraryId: id, try page(["a", "b"]))
        let sorted = try page(["sorted"])
        let started = expectation(description: "Refetch started")
        var pending: CheckedContinuation<CatalogResponse, Error>?
        var requests = 0
        let model = TVLibraryGridViewModel(libraryId: id, libraryType: "movies") { _ in
            requests += 1
            if requests > 1 { return sorted }
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }

        let refetch = Task { await model.refreshFirstPage() }
        await fulfillment(of: [started], timeout: 2)
        await model.setSort(model.filter.sort == .title ? .year : .title)
        XCTAssertEqual(model.items.map(\.contentId), ["sorted"])

        // The superseded refetch lands late and must not replace the new order.
        pending?.resume(returning: try page(["stale"]))
        await refetch.value
        XCTAssertEqual(model.items.map(\.contentId), ["sorted"])
        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.isLoading)
    }
}
#endif
