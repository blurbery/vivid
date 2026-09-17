import XCTest
@testable import Vivid

final class VividImageRetryTests: XCTestCase {
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
}
