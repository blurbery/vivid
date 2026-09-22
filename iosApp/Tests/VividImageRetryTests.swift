import XCTest
@testable import Vivid

final class VividImageRetryTests: XCTestCase {
    func testCacheOwnershipSeparatesServerAccountAndProfile() {
        let owner = VividCacheScope.key(serverID: "s", accountID: "a", profileID: "p")
        XCTAssertEqual(owner, VividCacheScope.key(serverID: "s", accountID: "a", profileID: "p"))
        for other in [
            VividCacheScope.key(serverID: "other", accountID: "a", profileID: "p"),
            VividCacheScope.key(serverID: "s", accountID: "other", profileID: "p"),
            VividCacheScope.key(serverID: "s", accountID: "a", profileID: "other")
        ] { XCTAssertNotEqual(owner, other) }
        let url = URL(string: "https://artwork.example/avatar")!
        let first = VividImageRequest(url: url, cacheScope: owner)
        let second = VividImageRequest(url: url, cacheScope: "another-account")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.key, second.key)
        let cache = VividImageCache(costLimit: 1024, countLimit: 2, diskCapacity: 0)
        XCTAssertFalse(cache.responses(for: owner) === cache.responses(for: second.cacheScope))
    }

    func testSameURLDoesNotShareInFlightBytesAcrossAccounts() async throws {
        let flights = VividEmbyImageDataFlights()
        let url = URL(string: "https://artwork.example/avatar")!
        let started = expectation(description: "First account request started")
        let outgoing = Task {
            try await flights.load(url, scope: "first") {
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
                return Data([1])
            }
        }
        await fulfillment(of: [started], timeout: 2)
        defer { outgoing.cancel() }
        let other = try await flights.load(url, scope: "second") { Data([2]) }
        XCTAssertEqual(other, Data([2]))
        await flights.cancelAll()
        do {
            _ = try await outgoing.value
            XCTFail("Expected cancellation of the original request")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAccountSwitchCancelsSharedArtworkAndAllowsFreshRequest() async throws {
        let flights = VividEmbyImageDataFlights()
        let url = URL(string: "https://artwork.example/emby/Items/1/Images/Primary")!
        let started = expectation(description: "Outgoing artwork started")
        let outgoing = Task {
            try await flights.load(url) {
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
                return Data([1])
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await flights.cancelAll()
        let fresh = try await flights.load(url) { Data([2]) }
        XCTAssertEqual(fresh, Data([2]))
        do {
            _ = try await outgoing.value
            XCTFail("The outgoing account's artwork must be cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTransientStartupFailureRecoversWithoutRecreatingView() async throws {
        var attempts = 0
        let value = try await VividImageRetry.load {
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            return "poster"
        }
        XCTAssertEqual(value, "poster")
        XCTAssertEqual(attempts, 2)
    }

    func testPersistentFailureStopsAfterOneRetry() async {
        var attempts = 0
        do {
            _ = try await VividImageRetry.load { () -> Int in
                attempts += 1
                throw URLError(.timedOut)
            }
            XCTFail("Expected the failed request to finish")
        } catch { XCTAssertEqual(attempts, 2) }
    }

    func testHTTPAndCancellationFailuresAreNotRetried() async {
        for code in [URLError.Code.badServerResponse, .cancelled, .cannotDecodeContentData] {
            var attempts = 0
            do {
                _ = try await VividImageRetry.load { () -> Int in
                    attempts += 1
                    throw URLError(code)
                }
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(attempts, 1) }
        }
    }

    func testCancellationDuringBackoffDoesNotStartAnotherRequest() async {
        let started = expectation(description: "First request failed")
        let task = Task {
            var attempts = 0
            do {
                _ = try await VividImageRetry.load { () -> Int in
                    attempts += 1
                    started.fulfill()
                    throw URLError(.timedOut)
                }
            } catch {}
            return attempts
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let attempts = await task.value
        XCTAssertEqual(attempts, 1)
    }
    func testRecoveryClassifiesTemporaryFailuresOnly() {
        for status in [408, 500, 502, 503, 504] {
            XCTAssertTrue(VividImageRetry.isRecoverable(VividImageHTTPError(statusCode: status)))
        }
        for status in [400, 401, 403, 404, 429, 501] {
            XCTAssertFalse(VividImageRetry.isRecoverable(VividImageHTTPError(statusCode: status)))
        }
        for error in [URLError(.cancelled), URLError(.cannotDecodeContentData), URLError(.badServerResponse)] {
            XCTAssertFalse(VividImageRetry.isRecoverable(error))
        }
        XCTAssertFalse(VividImageRetry.isRecoverable(CancellationError()))
    }

    func testVisibleArtworkRecoversFromServerFailure() async throws {
        var attempts = 0
        let image = try await VividImageRetry.recover {
            attempts += 1
            if attempts == 1 { throw VividImageHTTPError(statusCode: 503) }
            return "poster"
        }
        XCTAssertEqual(image, "poster")
        XCTAssertEqual(attempts, 2)
    }

    func testVisibleArtworkRecoveryBudgetIsBounded() async {
        var attempts = 0
        do {
            _ = try await VividImageRetry.recover { () -> Int in
                attempts += 1
                throw VividImageHTTPError(statusCode: 503)
            }
            XCTFail("Expected recovery to stop")
        } catch { XCTAssertEqual(attempts, 4) }
    }

    func testCancellingVisibleArtworkStopsDelayedRecovery() async {
        let started = expectation(description: "Artwork request started")
        let task = Task {
            var attempts = 0
            do {
                _ = try await VividImageRetry.recover { () -> Int in
                    attempts += 1
                    started.fulfill()
                    throw VividImageHTTPError(statusCode: 503)
                }
            } catch {}
            return attempts
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let attempts = await task.value
        XCTAssertEqual(attempts, 1)
    }

}
