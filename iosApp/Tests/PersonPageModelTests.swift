import XCTest
@testable import Vivid

/// A person page's late answers must never overwrite newer ones.
@MainActor
final class PersonDetailRequestTests: XCTestCase {
    private let personID = 987654321

    func testFilterChangeIgnoresTheReloadsLateFirstPage() async throws {
        addTeardownBlock { @MainActor [personID] in ResponseCache.shared.remove(CacheKey.person(personID)) }
        let pages = HeldRequests<CatalogResponse>()
        let firstHeld = expectation(description: "reload's first page requested")
        let secondHeld = expectation(description: "filter's first page requested")
        pages.holdExpectations = [firstHeld, secondHeld]
        let current = try Self.person(named: "Current")
        let probePage = try Self.page(contentID: "old")
        let model = PersonPageModel(
            personId: personID,
            fetchPerson: { _ in current },
            fetchCatalog: { _, _, _, limit, _ in
                // The Movies and Series probes ask for one title.
                if limit == 1 { return probePage }
                return try await pages.hold()
            }
        )

        let reload = Task { await model.reload() }
        await fulfillment(of: [firstHeld], timeout: 2)
        let filter = Task { await model.applyFilter(.movies) }
        await fulfillment(of: [secondHeld], timeout: 2)
        guard pages.count == 2 else {
            reload.cancel()
            filter.cancel()
            pages.failAll(CancellationError())
            return
        }

        pages.answer(0, with: try Self.page(contentID: "old"))
        await reload.value
        XCTAssertTrue(model.isLoadingFilmography)
        XCTAssertTrue(model.items.isEmpty)

        pages.answer(1, with: try Self.page(contentID: "new"))
        await filter.value
        XCTAssertFalse(model.isLoadingFilmography)
        XCTAssertEqual(model.items.map(\.contentId), ["new"])
        XCTAssertEqual(model.person?.name, "Current")
    }

    func testOlderReloadFinishingLastKeepsTheNewerPerson() async throws {
        addTeardownBlock { @MainActor [personID] in ResponseCache.shared.remove(CacheKey.person(personID)) }
        let people = HeldRequests<Person>()
        let firstHeld = expectation(description: "first reload's person requested")
        let secondHeld = expectation(description: "second reload's person requested")
        people.holdExpectations = [firstHeld, secondHeld]
        let film = try Self.page(contentID: "film")
        let model = PersonPageModel(
            personId: personID,
            fetchPerson: { _ in try await people.hold() },
            fetchCatalog: { _, _, _, _, _ in film }
        )

        let older = Task { await model.reload() }
        await fulfillment(of: [firstHeld], timeout: 2)
        let newer = Task { await model.reload() }
        await fulfillment(of: [secondHeld], timeout: 2)
        guard people.count == 2 else {
            older.cancel()
            newer.cancel()
            people.failAll(CancellationError())
            return
        }

        people.answer(1, with: try Self.person(named: "New"))
        await newer.value
        people.answer(0, with: try Self.person(named: "Old"))
        await older.value

        XCTAssertEqual(model.person?.name, "New")
        XCTAssertEqual(ResponseCache.shared.get(CacheKey.person(personID), as: Person.self)?.name, "New")
        XCTAssertFalse(model.isLoadingPerson)
        XCTAssertFalse(model.isLoadingFilmography)
    }

    // MARK: Fixtures

    /// A complete person, so no metadata polling starts.
    private static func person(named name: String) throws -> Person {
        try decode("""
        {"id": 987654321, "name": "\(name)", "bio": "Biography", "birth_date": "1980-01-01",
         "photo_url": "https://example.com/person.jpg"}
        """)
    }

    private static func page(contentID: String) throws -> CatalogResponse {
        try decode("""
        {"items": [{"content_id": "\(contentID)", "type": "movie", "title": "Film"}], "has_more": false}
        """)
    }

    private static func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }
}

/// Requests that stay open until the test answers them, in arrival order.
@MainActor
private final class HeldRequests<Value> {
    var holdExpectations: [XCTestExpectation] = []
    private var waiting: [CheckedContinuation<Value, Error>] = []

    var count: Int { waiting.count }

    func hold() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            let index = waiting.count - 1
            if index < holdExpectations.count { holdExpectations[index].fulfill() }
        }
    }

    func answer(_ index: Int, with value: Value) {
        waiting[index].resume(returning: value)
    }

    func failAll(_ error: Error) {
        waiting.forEach { $0.resume(throwing: error) }
    }
}
