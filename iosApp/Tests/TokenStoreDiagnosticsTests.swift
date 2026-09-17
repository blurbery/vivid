import Security
import XCTest
@testable import Vivid

/// Pins the `captureRequestAuth` refusal classifier.
///
/// Two properties matter and neither is obvious from reading the function:
/// the guard in `captureRequestAuth` and this classifier must agree on
/// evaluation order (otherwise a report attributes a mid-flight profile
/// switch to a server switch, or vice versa), and the tokens themselves are
/// consumed by hand out of collected reports, so a rename is a silent break
/// in meaning rather than a compile error.
final class TokenStoreDiagnosticsTests: XCTestCase {
    func testTemporaryReadFailureDoesNotCacheAnEmptySession() async {
        var accessReads = 0
        let keychain = SharedKeychain(
            service: "vivid.test.read", accessGroup: nil,
            allowsAppLocalFallback: false,
            readItem: { query in
                guard query[kSecAttrAccount as String] as? String == TokenStore.accessTokenKey(for: "test-server") else {
                    return (errSecItemNotFound, nil)
                }
                accessReads += 1
                return accessReads == 1
                    ? (errSecNotAvailable, nil)
                    : (errSecSuccess, Data("saved-session".utf8))
            }
        )
        let store = TokenStore(keychain: keychain)
        await store.retargetActiveServer(serverId: "test-server")
        let unavailable = await store.getAccessToken()
        let recovered = await store.getAccessToken()
        let cached = await store.getAccessToken()
        XCTAssertNil(unavailable)
        XCTAssertEqual(recovered, "saved-session")
        XCTAssertEqual(cached, "saved-session")
        XCTAssertEqual(accessReads, 2)
    }

    /// Every field valid and matching — the shape the classifier should never
    /// see, since the guard would have succeeded.
    private func reason(
        hasExpectedServerId: Bool = true,
        hasExpectedServerURL: Bool = true,
        hasExpectedProfileId: Bool = true,
        serverIdMatches: Bool = true,
        serverURLMatches: Bool = true,
        accountServerIdMatches: Bool = true,
        accountServerURLMatches: Bool = true,
        profileMatches: Bool = true
    ) -> String {
        TokenStore.requestIdentityMismatchReason(
            hasExpectedServerId: hasExpectedServerId,
            hasExpectedServerURL: hasExpectedServerURL,
            hasExpectedProfileId: hasExpectedProfileId,
            serverIdMatches: serverIdMatches,
            serverURLMatches: serverURLMatches,
            accountServerIdMatches: accountServerIdMatches,
            accountServerURLMatches: accountServerURLMatches,
            profileMatches: profileMatches
        )
    }

    func testEachMismatchMapsToItsOwnToken() {
        XCTAssertEqual(reason(hasExpectedServerId: false), "missingServerId")
        XCTAssertEqual(reason(hasExpectedServerURL: false), "missingServerURL")
        XCTAssertEqual(reason(hasExpectedProfileId: false), "missingProfileId")
        XCTAssertEqual(reason(serverIdMatches: false), "serverIdChanged")
        XCTAssertEqual(reason(serverURLMatches: false), "serverURLChanged")
        XCTAssertEqual(reason(accountServerIdMatches: false), "accountIdentityChanged")
        XCTAssertEqual(reason(accountServerURLMatches: false), "accountIdentityChanged")
        XCTAssertEqual(reason(profileMatches: false), "profileChanged")
    }

    /// The classifier must mirror the guard's short-circuit order. A profile
    /// switch that also crosses a server boundary is a server switch: the
    /// server is the outer identity, and reporting it as a profile change
    /// would send an investigation down the wrong path.
    func testEarlierMismatchesWinOverLaterOnes() {
        XCTAssertEqual(
            reason(hasExpectedServerId: false, profileMatches: false),
            "missingServerId"
        )
        XCTAssertEqual(
            reason(serverIdMatches: false, profileMatches: false),
            "serverIdChanged"
        )
        XCTAssertEqual(
            reason(accountServerIdMatches: false, profileMatches: false),
            "accountIdentityChanged"
        )
    }

    /// Unreachable from the guard, but the classifier must still return a
    /// stable token rather than an empty string a report reader would
    /// misread as a missing attribute.
    func testAllMatchingFallsBackToUnknown() {
        XCTAssertEqual(reason(), "unknown")
    }
}
