import XCTest
@testable import Vivid

final class MetadataSingleFlightTests: XCTestCase {
    func testCallersOverlappingOnOneKeyShareASingleRequest() async throws {
        let pool = MetadataSingleFlight<String, String>()
        let server = CountingServer()

        async let left = pool.value(for: "shared") { try await server.answer("shared", after: .milliseconds(100)) }
        async let right = pool.value(for: "shared") { try await server.answer("shared", after: .milliseconds(100)) }
        let answers = try await [left, right]

        XCTAssertEqual(answers, ["shared", "shared"])
        let requests = await server.requests("shared")
        XCTAssertEqual(requests, 1)
    }

    func testDifferentKeysNeverShare() async throws {
        let pool = MetadataSingleFlight<String, String>()
        let server = CountingServer()

        async let movie = pool.value(for: "movie") { try await server.answer("movie", after: .milliseconds(20)) }
        async let series = pool.value(for: "series") { try await server.answer("series", after: .milliseconds(20)) }
        _ = try await [movie, series]

        let movieRequests = await server.requests("movie")
        let seriesRequests = await server.requests("series")
        XCTAssertEqual(movieRequests, 1)
        XCTAssertEqual(seriesRequests, 1)
    }

    func testAFinishedRequestIsNotReused() async throws {
        let pool = MetadataSingleFlight<String, String>()
        let server = CountingServer()

        for _ in 0..<2 {
            _ = try await pool.value(for: "again") { await server.answerNow("again") }
        }

        let requests = await server.requests("again")
        XCTAssertEqual(requests, 2)
    }

    func testCancellingTheOnlyCallerStopsTheRequest() async throws {
        let pool = MetadataSingleFlight<String, String>()
        let server = CountingServer()

        let caller = Task { try await pool.value(for: "slow") { try await server.answer("slow", after: .seconds(30)) } }
        while await server.requests("slow") == 0 { await Task.yield() }
        caller.cancel()

        do {
            _ = try await caller.value
            XCTFail("A cancelled caller should not get a value")
        } catch is CancellationError {}
        while await server.cancellations("slow") == 0 { await Task.yield() }
        let cancellations = await server.cancellations("slow")
        XCTAssertEqual(cancellations, 1)
    }
}

private actor CountingServer {
    private var started: [String: Int] = [:]
    private var cancelled: [String: Int] = [:]

    func answer(_ key: String, after delay: Duration) async throws -> String {
        started[key, default: 0] += 1
        do {
            try await Task.sleep(for: delay)
        } catch {
            cancelled[key, default: 0] += 1
            throw error
        }
        return key
    }

    func answerNow(_ key: String) -> String {
        started[key, default: 0] += 1
        return key
    }

    func requests(_ key: String) -> Int { started[key, default: 0] }

    func cancellations(_ key: String) -> Int { cancelled[key, default: 0] }
}
