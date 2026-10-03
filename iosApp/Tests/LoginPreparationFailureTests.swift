import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Login preparation used to show one generic message for every failure, so
/// a dead server, an expired sign-in and a mistyped PIN looked the same.
final class LoginPreparationFailureTests: XCTestCase {
    func testDeadServerIsUnreachableEvenWhenWrappedByHTTPClient() {
        let wrapped = HTTPError.network(underlying: URLError(.cannotFindHost))
        XCTAssertEqual(LoginPreparationFailure.classify(wrapped, enteredPIN: false), .unreachable)
        XCTAssertEqual(LoginPreparationFailure.classify(URLError(.timedOut), enteredPIN: false), .unreachable)
    }

    func testProxyGatewayErrorsMeanTheServerIsDown() {
        for status in [502, 503, 504, 522, 530] {
            let error = HTTPError.http(statusCode: status, body: nil)
            XCTAssertEqual(LoginPreparationFailure.classify(error, enteredPIN: false), .unreachable, "\(status)")
        }
        XCTAssertEqual(LoginPreparationFailure.classify(HTTPError.http(statusCode: 500, body: nil), enteredPIN: false), .serverError)
    }

    func testOfflineDeviceIsNotBlamedOnTheServer() {
        let error = HTTPError.network(underlying: URLError(.notConnectedToInternet))
        XCTAssertEqual(LoginPreparationFailure.classify(error, enteredPIN: false), .offline)
    }

    func testRejectedPINIsAWrongPINNotAnExpiredSignIn() {
        let rejected = APIError.httpError(statusCode: 401)
        XCTAssertEqual(LoginPreparationFailure.classify(rejected, enteredPIN: true), .wrongPIN)
        XCTAssertEqual(LoginPreparationFailure.classify(rejected, enteredPIN: false), .signInExpired)
        XCTAssertEqual(LoginPreparationFailure.classify(ProfileTransitionError.missingPINProof, enteredPIN: true), .wrongPIN)
    }

    func testExpiredSignInLeavesTheAccountInsteadOfRetrying() {
        XCTAssertTrue(LoginPreparationFailure.signInExpired.primaryActionSignsOut)
        XCTAssertFalse(LoginPreparationFailure.unreachable.primaryActionSignsOut)
    }

    func testRetryCoversWrappedNetworkFailures() {
        XCTAssertTrue(LoginPreparationFailure.isTemporary(HTTPError.network(underlying: URLError(.timedOut))))
        XCTAssertTrue(LoginPreparationFailure.isTemporary(URLError(.networkConnectionLost)))
        XCTAssertFalse(LoginPreparationFailure.isTemporary(URLError(.cannotFindHost)))
        XCTAssertFalse(LoginPreparationFailure.isTemporary(APIError.httpError(statusCode: 401)))
    }
}
