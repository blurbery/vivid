import XCTest
@testable import Vivid

final class DownloadSecurityTests: XCTestCase {
    func testRequestPathsRejectMalformedDeepLinksAndPreserveEncodedAssets() throws {
        for path in ["/api/v1/items/%", "/api/v1/items/%2", "/api/v1/items/%GG",
                     "/api/v1/items/a b", "/api/v1/items/a?b", "/api/v1/items/a#b"] {
            XCTAssertThrowsError(try HTTPClient.validatedRequestPath(path), path)
        }
        for path in ["/api/v1/items/123", "/proxy/api/v1/assets/a%20b.jpg",
                     "/api/v1/items/%25", "/api/v1/items/%E2%9C%93", "/api/v1/assets/a%2Fb"] {
            XCTAssertEqual(try HTTPClient.validatedRequestPath(path), path)
        }
        let link = try XCTUnwrap(URL(string: "vivid://item/%25"))
        let id = try XCTUnwrap(link.pathComponents.last)
        XCTAssertThrowsError(try HTTPClient.validatedRequestPath("/api/v1/items/\(id)"))
    }

    func testDownloadCredentialsRejectAccountProfileAndGenerationChanges() async throws {
        let name = "DownloadSecurityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let store = TokenStore(keychain: keychain, defaults: SharedDefaults(suite: suite, standard: suite))
        await store.switchActiveServer(serverId: "server-a")
        await store.setServerUrl("https://a.example.test/proxy")
        await store.saveTokens(accessToken: "access-a", refreshToken: "refresh-a")
        await store.setProfileId("profile-a")
        _ = await store.setProfileToken("proof-a")
        let captured = await store.captureOrdinaryRequestAuth()
        let original = try XCTUnwrap(captured)
        let url = try XCTUnwrap(URL(string: "https://a.example.test/proxy/api/v1/downloads/1/file"))
        let request = try await DownloadAuthHeaders.authorizedRequest(url: url, allowsCellular: false,
                                                                    expected: original, tokenStore: store)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")
        XCTAssertFalse(request.allowsCellularAccess)

        // A successful refresh keeps the same owner and is allowed to supply
        // the new access token without losing the captured profile proof.
        let refresh = await store.captureRefreshCredential(expected: original.account)
        let saved = await store.saveRefreshedTokens("rotated-a", "rotated-refresh-a", replacing: try XCTUnwrap(refresh))
        XCTAssertTrue(saved)
        let rotated = try await DownloadAuthHeaders.authorizedRequest(url: url, allowsCellular: true,
                                                                    expected: original, tokenStore: store)
        XCTAssertEqual(rotated.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-a")
        XCTAssertEqual(rotated.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")

        await store.setProfileId("profile-b")
        await assertIdentityRejected(url, original, store)
        await store.setProfileId("profile-a")
        _ = await store.setProfileToken("proof-b")
        await assertIdentityRejected(url, original, store)
        _ = await store.setProfileToken("proof-a")
        await store.saveTokens(accessToken: "another-account", refreshToken: "another-refresh")
        await assertIdentityRejected(url, original, store)
        await store.clearTokens()
        await store.switchActiveServer(serverId: "server-b")
        await store.setServerUrl("https://b.example.test")
        await store.saveTokens(accessToken: "access-b", refreshToken: "refresh-b")
        await assertIdentityRejected(url, original, store)
        await store.clearTokens()
    }

    func testDownloadOriginValidationAndEmbyHeaders() throws {
        for server in ["silo-a", "emby:a"] {
            let auth = CapturedOrdinaryRequestAuth(
                account: RefreshAccountIdentity(serverId: server, serverURL: "https://media.example.test/proxy",
                                                credentialGenerationID: UUID()),
                credentialOwner: .persistentServer(serverId: server), accessToken: "test-access",
                profileId: "test-profile", profileToken: "test-proof")
            for destination in ["https://other.example.test/proxy/file", "http://media.example.test/proxy/file",
                                "https://media.example.test:444/proxy/file", "https://media.example.test/outside/file",
                                "https://user:pass@media.example.test/proxy/file"] {
                XCTAssertThrowsError(try DownloadAuthHeaders.request(url: URL(string: destination)!, allowsCellular: true, auth: auth))
            }
            let request = try DownloadAuthHeaders.request(url: URL(string: "https://media.example.test:443/proxy/file")!,
                                                         allowsCellular: true, auth: auth)
            if server.hasPrefix("emby:") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "test-access")
                XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Emby-Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Token"))
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Token"), "test-proof")
            }
        }
    }

    private func assertIdentityRejected(_ url: URL, _ expected: CapturedOrdinaryRequestAuth, _ store: TokenStore) async {
        do {
            _ = try await DownloadAuthHeaders.authorizedRequest(url: url, allowsCellular: true, expected: expected, tokenStore: store)
            XCTFail("A stale download must not receive the new account's credentials")
        } catch HTTPError.requestIdentityChanged {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
