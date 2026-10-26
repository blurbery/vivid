import XCTest
@testable import Vivid

@MainActor
final class HomeCollectionsStoreTests: XCTestCase {
    private func collection(_ id: String, _ name: String, count: Int? = 10, poster: String? = nil) -> LibraryCollection {
        LibraryCollection(id: id, name: name, itemCount: count, posterUrl: poster, kind: .regular)
    }

    func testAutomaticPicksPutTheLargestFirstWithTiesAToZ() {
        let picks = HomeCollectionsStore.automaticPicks([
            collection("a", "Alien", count: 4),
            collection("b", "Bond", count: 25),
            collection("c", "Avengers", count: 4),
            collection("d", "Harry Potter", count: 8),
        ])
        XCTAssertEqual(picks, ["b", "d", "a", "c"])
    }

    func testAutomaticPicksPutCollectionsWithoutACountLast() {
        let picks = HomeCollectionsStore.automaticPicks([
            collection("smart", "Recently Added", count: nil),
            collection("one", "Mad Max", count: 1),
        ])
        XCTAssertEqual(picks, ["one", "smart"])
    }

    func testAutomaticPicksStopAtTwenty() {
        let collections = (0..<30).map { (n: Int) in collection("\(n)", "Collection \(n)", count: n) }
        let picks = HomeCollectionsStore.automaticPicks(collections)
        XCTAssertEqual(picks.count, HomeCollectionsStore.maxPicks)
        XCTAssertEqual(picks.first, "29", "Most titles first")
    }

    func testAutomaticPicksLeaveOutTheProfilesOwnCollections() {
        let mine = LibraryCollection(personal: UserCollection(
            id: "mine", name: "Weekend Movies", collectionType: nil, createdAt: nil, description: nil, groupId: nil,
            sortOrder: nil, itemCount: 300, posterUrl: nil, posterThumbhash: nil, includeInServerCollections: nil
        ), profileID: "profile-1")
        XCTAssertEqual(mine.kind, .userCollections)
        XCTAssertEqual(mine.creatorProfileId, "profile-1")
        let available = [mine, collection("a", "Alien", count: 4)]
        XCTAssertEqual(HomeCollectionsStore.automaticPicks(available), ["a"])
        XCTAssertEqual(HomeCollectionsStore.picks(custom: ["mine", "a"], available: available), ["mine", "a"],
                       "A chosen personal collection still shows")
    }

    func testAPersonalListThatFailedKeepsItsEarlierEntries() {
        let personalID = HomeCollection.personalLibraryID
        let previous = [HomeCollection(collection: collection("1", "Alien"), libraryID: 1),
                        HomeCollection(collection: collection("mine", "Weekend Movies"), libraryID: personalID)]
        let fresh = [HomeCollection(collection: collection("1", "Alien"), libraryID: 1)]
        let partial = HomeCollectionsStore.merged(fresh, previous: previous, failedLibraries: [personalID])
        XCTAssertEqual(partial.map(\.id), ["1", "mine"])
    }

    func testOnlyANotFoundAnswerCountsAsNotFound() {
        XCTAssertTrue(VividAPI.isNotFound(HTTPError.http(statusCode: 404, body: nil)))
        XCTAssertTrue(VividAPI.isNotFound(APIError.httpError(statusCode: 404)))
        XCTAssertFalse(VividAPI.isNotFound(HTTPError.http(statusCode: 500, body: nil)))
        XCTAssertFalse(VividAPI.isNotFound(APIError.httpError(statusCode: 403)))
        XCTAssertFalse(VividAPI.isNotFound(URLError(.timedOut)))
    }

    func testChosenPicksKeepTheirOrderAndDropCollectionsNoLongerOnTheServer() {
        let available = [collection("a", "Alien"), collection("b", "Bond"), collection("c", "Cars")]
        let picks = HomeCollectionsStore.picks(custom: ["c", "gone", "a", "c"], available: available)
        XCTAssertEqual(picks, ["c", "a"])
    }

    func testAnEmptyChoiceStaysEmptyRatherThanFallingBackToAutomatic() {
        let picks = HomeCollectionsStore.picks(custom: [], available: [collection("a", "Alien")])
        XCTAssertEqual(picks, [])
    }

    func testAnEditWhileALibraryFailedKeepsItsChoices() {
        let kept = HomeCollectionsStore.keepingUnloadedPicks(
            ["b", "c"], previous: ["a", "x", "b"], loaded: ["a", "b", "c"], listIsComplete: false)
        XCTAssertEqual(kept, ["b", "c", "x"], "x is from the library that failed, so it stays after the edit")
    }

    func testAnEditWithACompleteListDropsChoicesNoLongerOnTheServer() {
        let kept = HomeCollectionsStore.keepingUnloadedPicks(
            ["b", "c"], previous: ["a", "x", "b"], loaded: ["a", "b", "c"], listIsComplete: true)
        XCTAssertEqual(kept, ["b", "c"])
    }

    func testAPartialListKeepsEarlierEntriesOnlyFromLibrariesThatFailed() {
        let previous = [HomeCollection(collection: collection("1", "Alien"), libraryID: 1),
                        HomeCollection(collection: collection("2", "Bond"), libraryID: 2),
                        HomeCollection(collection: collection("3", "Cars"), libraryID: 1)]
        // Library 1 answered without Cars (deleted); library 2 failed.
        let fresh = [HomeCollection(collection: collection("1", "Alien", count: 4), libraryID: 1)]
        let partial = HomeCollectionsStore.merged(fresh, previous: previous, failedLibraries: [2])
        XCTAssertEqual(partial.map(\.id), ["1", "2"])
        XCTAssertEqual(partial.first?.collection.itemCount, 4)
        XCTAssertEqual(HomeCollectionsStore.merged(fresh, previous: previous, failedLibraries: []).map(\.id), ["1"])
    }

    func testCollectionsSortAToZWithNumbersInOrder() {
        let sorted = HomeCollectionsStore.sorted([
            HomeCollection(collection: collection("1", "Toy Story"), libraryID: 1),
            HomeCollection(collection: collection("2", "Alien"), libraryID: 1),
            HomeCollection(collection: collection("3", "Collection 10"), libraryID: 2),
            HomeCollection(collection: collection("4", "Collection 9"), libraryID: 2),
        ])
        XCTAssertEqual(sorted.map(\.collection.name), ["Alien", "Collection 9", "Collection 10", "Toy Story"])
    }

    func testCarouselsHoldTwentyEach() {
        let entries = (0..<45).map { HomeCollection(collection: collection("\($0)", "C\($0)"), libraryID: 0) }
        let carousels = HomeCollectionsStore.carousels(entries)
        XCTAssertEqual(carousels.map(\.count), [20, 20, 5])
        XCTAssertEqual(carousels.flatMap { $0 }.map(\.id), entries.map(\.id))
    }

    func testArtworkExpiryIsTheEarliestSignedPoster() {
        let later = "https://silo.example.com/api/v2/artwork/posters/a.webp?exp=1791000000&sig=0f1e2d"
        let earlier = "https://silo.example.com/api/v2/artwork/posters/b.webp?exp=1790000000&sig=0f1e2d"
        let unsigned = "https://emby.example.com/Items/42/Images/Primary?tag=abc"
        let entries = [later, unsigned, earlier].enumerated().map {
            HomeCollection(collection: collection("\($0.offset)", "C", poster: $0.element), libraryID: 0)
        }
        XCTAssertEqual(HomeCollectionsStore.artworkExpiry(of: entries), Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(HomeCollectionsStore.artworkExpiry(of: [entries[1]]))
    }

    func testCachedEntriesRoundTrip() throws {
        let entry = HomeCollection(collection: collection("7", "Bond", count: 25, poster: "https://example.com/p.jpg"), libraryID: 3)
        let decoded = try JSONDecoder().decode(HomeCollection.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
    }
}
