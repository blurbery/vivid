import XCTest
@testable import Vivid

final class VividImageRetryTests: XCTestCase {
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
