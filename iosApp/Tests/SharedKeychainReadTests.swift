import Security
import XCTest
@testable import Vivid

final class SharedKeychainReadTests: XCTestCase {
    private func keychain(_ read: @escaping () -> (OSStatus, Data?)) -> SharedKeychain {
        SharedKeychain(service: "vivid.test.read", accessGroup: nil,
                       audience: .currentUser, allowsAppLocalFallback: false,
                       readItem: { _ in read() })
    }

    func testMissingLoginDoesNotRetry() async throws {
        var reads = 0
        let store = keychain { reads += 1; return (errSecItemNotFound, nil) }
        let value = try await KeychainReadFailure.retryTemporaryRead(wait: { XCTFail("Missing is not unavailable") }) {
            try store.getChecked("account")
        }
        XCTAssertNil(value)
        XCTAssertEqual(reads, 1)
    }

    func testTemporaryFailureRecoversWithoutLosingSavedLogin() async throws {
        var reads = 0
        var waits = 0
        let store = keychain {
            reads += 1
            return reads == 1 ? (errSecInteractionNotAllowed, nil) : (errSecSuccess, Data("saved".utf8))
        }
        let value = try await KeychainReadFailure.retryTemporaryRead(wait: { waits += 1 }) {
            try store.getChecked("account")
        }
        XCTAssertEqual(value, "saved")
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(waits, 1)
    }

    func testPersistentUnavailabilityThrowsAfterBoundedRetries() async {
        var reads = 0
        let store = keychain { reads += 1; return (errSecNotAvailable, nil) }
        do {
            _ = try await KeychainReadFailure.retryTemporaryRead(wait: {}) { try store.getChecked("account") }
            XCTFail("Unavailable storage must not become a missing login")
        } catch {
            XCTAssertEqual(error as? KeychainReadFailure, KeychainReadFailure(status: errSecNotAvailable))
        }
        XCTAssertEqual(reads, 3)
    }

    func testEntitlementFailureDoesNotRetryOrLookInAnotherStore() async {
        var reads = 0
        let store = keychain { reads += 1; return (errSecMissingEntitlement, nil) }
        do {
            _ = try await KeychainReadFailure.retryTemporaryRead(wait: { XCTFail("Not temporary") }) {
                try store.getChecked("account")
            }
            XCTFail("Expected a read failure")
        } catch {
            XCTAssertEqual(error as? KeychainReadFailure, KeychainReadFailure(status: errSecMissingEntitlement))
        }
        XCTAssertEqual(reads, 1)
    }

    func testCancellationStopsRetry() async {
        var reads = 0
        let store = keychain { reads += 1; return (errSecNotAvailable, nil) }
        do {
            _ = try await KeychainReadFailure.retryTemporaryRead(wait: { throw CancellationError() }) {
                try store.getChecked("account")
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(reads, 1)
    }

    func testMalformedDataIsNotMissingLogin() {
        let store = keychain { (errSecSuccess, Data([0xff])) }
        XCTAssertThrowsError(try store.getChecked("account")) {
            XCTAssertEqual($0 as? KeychainReadFailure, KeychainReadFailure(status: errSecDecode))
        }
    }
}
