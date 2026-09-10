import XCTest
@testable import Vivid

@MainActor
final class PersonDetailRequestTests: XCTestCase {
    private let personID = 987654321
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func person(_ name: String) throws -> Person {
        try decoder.decode(Person.self, from: Data("""
        {"id":987654321,"name":"\(name)","bio":"Biography","birth_date":"1980-01-01","photo_url":"https://example.com/person.jpg"}
        """.utf8))
    }

    private func catalogue(_ id: String) throws -> CatalogResponse {
        try decoder.decode(CatalogResponse.self, from: Data("""
        {"items":[{"content_id":"\(id)","type":"movie","title":"Film"}],"has_more":false}
        """.utf8))
    }

    func testFilterStartsReplacementAndOldCompletionCannotClearItsLoadingState() async throws {
        let metadata = try person("Current")
        let oldResponse = try catalogue("old")
        let newResponse = try catalogue("new")
        let firstStarted = expectation(description: "Initial catalogue request")
        let secondStarted = expectation(description: "Replacement catalogue request")
        var requests: [CheckedContinuation<CatalogResponse, Error>] = []
        let model = PersonDetailViewModel(personId: personID, requestPerson: { _ in metadata }, requestCatalog: { _, _, _, limit, _ in
            if limit == 1 { return oldResponse }
            return try await withCheckedThrowingContinuation { continuation in
                requests.append(continuation)
                if requests.count == 1 { firstStarted.fulfill() }
                if requests.count == 2 { secondStarted.fulfill() }
            }
        })
        defer { ResponseCache.shared.remove(CacheKey.person(personID)) }
        let initial = Task { await model.reload() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let replacement = Task { await model.applyFilter(.movies) }
        await fulfillment(of: [secondStarted], timeout: 2)
        guard requests.count == 2 else {
            initial.cancel(); replacement.cancel()
            requests.forEach { $0.resume(throwing: CancellationError()) }
            return
        }
        requests[0].resume(returning: oldResponse)
        await initial.value
        XCTAssertTrue(model.isLoadingItems)
        XCTAssertTrue(model.items.isEmpty)
        requests[1].resume(returning: newResponse)
        await replacement.value
        XCTAssertFalse(model.isLoadingItems)
        XCTAssertEqual(model.items.map(\.contentId), ["new"])
        XCTAssertEqual(model.person?.name, "Current")
    }

    func testOlderReloadCannotReplaceNewerPersonOrCache() async throws {
        let oldPerson = try person("Old")
        let newPerson = try person("New")
        let response = try catalogue("film")
        let firstStarted = expectation(description: "Initial metadata request")
        let secondStarted = expectation(description: "Replacement metadata request")
        var requests: [CheckedContinuation<Person, Error>] = []
        let model = PersonDetailViewModel(personId: personID, requestPerson: { _ in
            try await withCheckedThrowingContinuation { continuation in
                requests.append(continuation)
                if requests.count == 1 { firstStarted.fulfill() }
                if requests.count == 2 { secondStarted.fulfill() }
            }
        }, requestCatalog: { _, _, _, _, _ in response })
        defer { ResponseCache.shared.remove(CacheKey.person(personID)) }
        let initial = Task { await model.reload() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let replacement = Task { await model.reload() }
        await fulfillment(of: [secondStarted], timeout: 2)
        guard requests.count == 2 else {
            initial.cancel(); replacement.cancel()
            requests.forEach { $0.resume(throwing: CancellationError()) }
            return
        }
        requests[1].resume(returning: newPerson)
        await replacement.value
        requests[0].resume(returning: oldPerson)
        await initial.value
        XCTAssertEqual(model.person?.name, "New")
        let cached: Person? = ResponseCache.shared.get(CacheKey.person(personID))
        XCTAssertEqual(cached?.name, "New")
        XCTAssertFalse(model.isLoadingPerson)
        XCTAssertFalse(model.isLoadingItems)
    }
}
