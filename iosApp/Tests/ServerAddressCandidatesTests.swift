import XCTest
@testable import Vivid

/// The addresses the server form tries: plain HTTP works for any host when
/// it's asked for, but Auto only falls back to it on its own for a local
/// address.
@MainActor
final class ServerAddressCandidatesTests: XCTestCase {
    private func candidates(
        _ typed: String, port: String = "", choice: ServerProtocolChoice = .auto, provider: MediaServerProvider = .emby
    ) -> [String] {
        switch ServerAddressForm.candidates(typed: typed, portField: port, choice: choice, provider: provider, spelling: { $0 }) {
        case .success(let addresses): return addresses
        case .failure(let problem): XCTFail("Unexpected \(problem)"); return []
        }
    }

    func testAutoKeepsAPublicHostOnHTTPS() {
        XCTAssertEqual(candidates("media.example.test"), ["https://media.example.test"])
        XCTAssertEqual(candidates("media.example.test", provider: .silo), ["https://media.example.test"])
        XCTAssertEqual(candidates("media.example.test", port: "8096"), ["https://media.example.test:8096"])
        XCTAssertEqual(candidates("https://media.example.test", provider: .silo), ["https://media.example.test"])
    }

    func testAutoStillFallsBackToPlainHTTPForLocalAddresses() {
        XCTAssertEqual(candidates("192.168.1.20"),
                       ["https://192.168.1.20", "http://192.168.1.20", "http://192.168.1.20:8096"])
        XCTAssertEqual(candidates("nas", provider: .silo), ["https://nas", "http://nas", "http://nas:8090"])
        XCTAssertEqual(candidates("media.local", provider: .jellyfin),
                       ["https://media.local", "http://media.local", "http://media.local:8096"])
        XCTAssertEqual(candidates("https://nas", provider: .silo), ["https://nas", "http://nas:8090"])
    }

    func testPlainHTTPToAPublicHostWhenAskedFor() {
        XCTAssertEqual(candidates("http://media.example.test"), ["http://media.example.test"])
        XCTAssertEqual(candidates("http://media.example.test:8096"), ["http://media.example.test:8096"])
        XCTAssertEqual(candidates("http://media.example.test", provider: .silo),
                       ["http://media.example.test", "http://media.example.test:8090"])
        XCTAssertEqual(candidates("media.example.test", choice: .http), ["http://media.example.test"])
        XCTAssertEqual(candidates("media.example.test", port: "8096", choice: .http), ["http://media.example.test:8096"])
        XCTAssertEqual(candidates("media.example.test", choice: .https), ["https://media.example.test"])
    }

    /// Auto on a public host with no scheme typed only tries HTTPS, so the
    /// error says how to reach a plain-HTTP server.
    func testAutoSkippedPlainHTTPHint() {
        func skipped(_ typed: String, choice: ServerProtocolChoice = .auto) -> Bool {
            ServerAddressForm.autoSkippedPlainHTTP(candidates: candidates(typed, choice: choice), choice: choice, typed: typed)
        }
        XCTAssertTrue(skipped("media.example.test"))
        XCTAssertTrue(skipped("media.example.test:8096"))
        XCTAssertFalse(skipped("https://media.example.test"))
        XCTAssertFalse(skipped("http://media.example.test"))
        XCTAssertFalse(skipped("192.168.1.20"))
        XCTAssertFalse(skipped("media.example.test", choice: .https))
        XCTAssertFalse(skipped("media.example.test", choice: .http))
    }

    func testLocalHosts() {
        for host in ["192.168.1.20", "10.0.0.5", "[::1]", "[fe80::1%25en0]", "nas", "NAS.LOCAL", "media.local.", "localhost"] {
            XCTAssertTrue(LocalNetworkHost.contains(host), host)
        }
        for host in ["media.example.test", "media.example.test.", "local.example.test", ""] {
            XCTAssertFalse(LocalNetworkHost.contains(host), host)
        }
    }
}
