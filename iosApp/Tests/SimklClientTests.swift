import XCTest
@testable import Vivid

final class SimklClientTests: XCTestCase {
    func testIDsNormaliseAndOnlyMatchWithoutAContradiction() {
        let ids = SimklIDs(tmdb: "00123", imdb: " tt0903747 ", tvdb: "0")
        XCTAssertEqual(ids.tmdb, "123")
        XCTAssertEqual(ids.imdb, "tt0903747")
        XCTAssertNil(ids.tvdb)
        XCTAssertNil(SimklIDs(imdb: "tt").imdb)
        XCTAssertNil(SimklIDs(tmdb: "-4").tmdb)
        XCTAssertTrue(ids.matches(SimklIDs(imdb: "tt0903747")))
        XCTAssertFalse(ids.matches(SimklIDs(tmdb: "123", imdb: "tt1111111")), "A contradicting ID is a different title")
        XCTAssertFalse(ids.matches(SimklIDs(tvdb: "81189")), "No shared ID is no match")
        XCTAssertTrue(SimklIDs(simkl: 7, tmdb: "1").matches(SimklIDs(simkl: 7, tmdb: "2")), "Simkl's own ID decides")
        XCTAssertFalse(SimklIDs(simkl: 7, tmdb: "1").matches(SimklIDs(simkl: 8, tmdb: "1")))
    }

    func testHistorySendsShowIDsWithEpisodeNumbersAndNeverTitles() throws {
        let movie = SimklHistoryEntry(ids: SimklIDs(tmdb: "27205", imdb: "tt1375666"), season: nil, episode: nil,
                                      watchedAt: "2026-10-30T10:00:00Z")
        let episode = SimklHistoryEntry(ids: SimklIDs(tmdb: "1396", tvdb: "81189"), season: 2, episode: 5,
                                        watchedAt: "2026-10-30T11:00:00Z")
        let body = SimklClient.historyBody([movie, episode])
        let movies = try XCTUnwrap(body["movies"] as? [[String: Any]])
        let shows = try XCTUnwrap(body["shows"] as? [[String: Any]])
        XCTAssertEqual(movies.first?["watched_at"] as? String, "2026-10-30T10:00:00Z")
        XCTAssertEqual((movies.first?["ids"] as? [String: Any])?["tmdb"] as? String, "27205")
        XCTAssertEqual(shows.first?["use_tvdb_anime_seasons"] as? Bool, true)
        let season = try XCTUnwrap((shows.first?["seasons"] as? [[String: Any]])?.first)
        XCTAssertEqual(season["number"] as? Int, 2)
        let sent = try XCTUnwrap((season["episodes"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["number"] as? Int, 5)
        XCTAssertEqual(sent["watched_at"] as? String, "2026-10-30T11:00:00Z")
        XCTAssertNil(movies.first?["title"])
        XCTAssertNil(shows.first?["title"])
        XCTAssertNil(shows.first?["watched_at"])
    }

    func testHistoryConfirmsFromNotFoundAndFlagsTitlesFiledAsAnotherKind() throws {
        let entries = [
            SimklHistoryEntry(ids: SimklIDs(tmdb: "1"), season: nil, episode: nil, watchedAt: "a"),
            SimklHistoryEntry(ids: SimklIDs(tmdb: "2"), season: nil, episode: nil, watchedAt: "b"),
            SimklHistoryEntry(ids: SimklIDs(tvdb: "3"), season: 1, episode: 1, watchedAt: "c"),
            SimklHistoryEntry(ids: SimklIDs(tvdb: "3"), season: 1, episode: 2, watchedAt: "d"),
        ]
        let response: [String: Any] = [
            "added": ["movies": 1, "episodes": 1, "statuses": [
                ["request": ["type": "movie", "ids": ["tmdb": "1"]], "response": ["simkl_type": "tv"]],
            ]],
            "not_found": ["movies": [["ids": ["tmdb": "2"]]], "shows": [],
                          "episodes": [["ids": ["tvdb": "3"], "seasons": [["number": 1, "episodes": [["number": 2]]]]]]],
        ]
        let result = try SimklClient.historyResult(response, entries: entries)
        XCTAssertEqual(result.accepted, [0, 2])
        XCTAssertEqual(result.mismatched, [0])

        let everything = try SimklClient.historyResult(["added": ["movies": 2], "not_found": ["movies": [], "shows": [], "episodes": []]],
                                                       entries: entries)
        XCTAssertEqual(everything.accepted, [0, 1, 2, 3])
    }

    func testHistoryKeepsEverythingPendingWhenNotFoundCantBeAccountedFor() throws {
        let entries = [SimklHistoryEntry(ids: SimklIDs(tmdb: "1"), season: nil, episode: nil, watchedAt: "a")]
        for notFound: [String: Any] in [["movies": [["title": "No IDs"]]], ["movies": [["ids": ["tmdb": "999"]]]],
                                        ["episodes": [["ids": ["tvdb": "5"], "seasons": [["episodes": [["number": 1]]]]]]]] {
            XCTAssertTrue(try SimklClient.historyResult(["added": [String: Any](), "not_found": notFound], entries: entries).accepted.isEmpty)
        }
        XCTAssertThrowsError(try SimklClient.historyResult(["not_found": [String: Any]()], entries: entries))
        XCTAssertThrowsError(try SimklClient.historyResult(["added": [String: Any](), "not_found": ["movies": "x"]], entries: entries))
    }

    func testLibraryFilesAnimeWithShowsOrMoviesAndAcceptsEmptyShapes() throws {
        let response: [String: Any] = [
            "movies": [["status": "plantowatch", "watched_episodes_count": 0, "last_watched_at": NSNull(),
                        "movie": ["title": "Film", "year": 2010, "ids": ["simkl": 10, "tmdb": "27205"]]]],
            "shows": [["status": "watching", "watched_episodes_count": 3,
                       "show": ["title": "Series", "ids": ["simkl": 11, "tvdb": "81189"]]]],
            "anime": [["status": "completed", "anime_type": "movie", "show": ["title": "Anime film", "ids": ["simkl": 12, "mal": "1"]]],
                      ["status": "someday", "anime_type": "tv", "show": ["title": "Anime", "ids": ["simkl": 13]]]],
        ]
        let items = Dictionary(uniqueKeysWithValues: try SimklClient.parseLibrary(response).map { ($0.simkl, $0) })
        XCTAssertEqual(items[10]?.kind, .movie)
        XCTAssertEqual(items[10]?.isPlanToWatch, true)
        XCTAssertEqual(items[10]?.hasHistory, false)
        XCTAssertEqual(items[11]?.hasHistory, true)
        XCTAssertEqual(items[12]?.kind, .movie)
        XCTAssertEqual(items[12]?.type, "anime")
        XCTAssertEqual(items[13]?.kind, .show)
        XCTAssertNil(items[13]?.status, "An unknown status keeps the title in the library")
        for empty: Any? in [nil, NSNull(), [Any](), [String: Any]()] {
            XCTAssertTrue(try SimklClient.parseLibrary(empty).isEmpty)
        }
        XCTAssertThrowsError(try SimklClient.parseLibrary(["movies": [["movie": ["ids": ["tmdb": "1"]]]]]), "Rows need a Simkl ID")
        XCTAssertThrowsError(try SimklClient.parseLibrary([1]))
        XCTAssertEqual(try SimklClient.parseLibraryIDs(["anime": [["show": ["ids": ["simkl": 4]]]],
                                                        "movies": [["movie": ["ids": ["simkl": 5]]]]]), [4, 5])
    }

    func testWatchlistPolicyNeverDeletesHistoryOrMovesTitlesSimklTracks() {
        func row(_ status: SimklStatus?, watched: Int = 0) -> SimklLibraryItem {
            SimklLibraryItem(simkl: 1, kind: .show, type: "shows", status: status, ids: SimklIDs(simkl: 1),
                             title: "Series", year: nil, watchedEpisodes: watched, lastWatchedAt: nil)
        }
        typealias P = SimklWatchlistPolicy
        // First sync combines both lists, without moving a tracked title.
        XCTAssertEqual(P.action(local: true, remote: nil, mapped: true, previousLocal: nil, previousRemote: nil), .addRemote)
        XCTAssertEqual(P.action(local: true, remote: nil, mapped: false, previousLocal: nil, previousRemote: nil), .none)
        XCTAssertEqual(P.action(local: true, remote: row(.completed), mapped: true, previousLocal: nil, previousRemote: nil), .none)
        XCTAssertEqual(P.action(local: false, remote: row(.plantowatch), mapped: true, previousLocal: nil, previousRemote: nil), .addLocal)
        // Removing from Vivid removes only a Plan to Watch title with no history.
        XCTAssertEqual(P.action(local: false, remote: row(.plantowatch), mapped: true, previousLocal: true, previousRemote: true), .removeRemote)
        XCTAssertEqual(P.action(local: false, remote: row(.plantowatch, watched: 2), mapped: true, previousLocal: true, previousRemote: true), .none)
        XCTAssertEqual(P.action(local: false, remote: row(.watching), mapped: true, previousLocal: true, previousRemote: false), .none)
        // Simkl moving a title on after it's watched keeps it on Vivid's watchlist.
        XCTAssertEqual(P.action(local: true, remote: row(.watching, watched: 1), mapped: true, previousLocal: true, previousRemote: true), .none)
        XCTAssertEqual(P.action(local: true, remote: row(.completed), mapped: true, previousLocal: true, previousRemote: true), .none)
        XCTAssertEqual(P.action(local: true, remote: row(nil), mapped: true, previousLocal: true, previousRemote: true), .none)
        // A deletion or a drop on Simkl comes back.
        XCTAssertEqual(P.action(local: true, remote: nil, mapped: true, previousLocal: true, previousRemote: true), .removeLocal)
        XCTAssertEqual(P.action(local: true, remote: row(.dropped), mapped: true, previousLocal: true, previousRemote: true), .removeLocal)
        XCTAssertEqual(P.action(local: true, remote: nil, mapped: false, previousLocal: true, previousRemote: true), .none, "An unmatched title is never removed")
        // Vivid's own add isn't repeated while Simkl catches up.
        XCTAssertEqual(P.action(local: true, remote: nil, mapped: true, previousLocal: true, previousRemote: false), .none)
        XCTAssertEqual(P.action(local: false, remote: nil, mapped: true, previousLocal: false, previousRemote: true), .none)
        // Changes on both sides at once leave things as they are.
        XCTAssertEqual(P.action(local: false, remote: nil, mapped: true, previousLocal: true, previousRemote: true), .none)
        XCTAssertEqual(P.action(local: true, remote: row(.plantowatch), mapped: true, previousLocal: false, previousRemote: false), .none)
    }

    func testRemovalDiffNeverTrustsAReplyMissingMostOfTheLibrary() {
        let cached = Array(1...100)
        XCTAssertEqual(SimklRemovalCheck.removals(cached: cached, present: Set(3...100)), [1, 2])
        XCTAssertNil(SimklRemovalCheck.removals(cached: cached, present: []), "An empty reply is read again in full")
        XCTAssertNil(SimklRemovalCheck.removals(cached: cached, present: Set(1...50)))
        XCTAssertNil(SimklRemovalCheck.removals(cached: [1, 2], present: []))
        XCTAssertEqual(SimklRemovalCheck.removals(cached: [1, 2, 3], present: [1, 2]), [3])
        XCTAssertEqual(SimklRemovalCheck.removals(cached: [], present: []), [])
        XCTAssertEqual(SimklRemovalCheck.removals(cached: [1], present: [1, 2]), [])
    }

    func testActivitiesNoticeMovedStatusesAndRemovalsPerType() throws {
        let old = try SimklActivities(json: ["all": "2026-10-01T00:00:00Z",
            "movies": ["all": "x", "plantowatch": "2026-10-01T00:00:00Z", "removed_from_list": "2026-09-01T00:00:00Z"],
            "anime": ["plantowatch": NSNull()]])
        let new = try SimklActivities(json: ["all": "2026-10-02T00:00:00Z",
            "movies": ["plantowatch": "2026-10-01T00:00:00Z", "removed_from_list": "2026-10-02T00:00:00Z"],
            "anime": ["watching": "2026-10-02T00:00:00Z"],
            "settings": ["all": "2026-10-02T00:00:00Z"]])
        XCTAssertFalse(new.statusesMoved("movies", since: old))
        XCTAssertTrue(new.removalsMoved("movies", since: old))
        XCTAssertTrue(new.statusesMoved("anime", since: old))
        XCTAssertFalse(new.statusesMoved("tv_shows", since: old))
        XCTAssertNil(try SimklActivities(json: ["all": NSNull()]).all)
        XCTAssertThrowsError(try SimklActivities(json: ["all": 4]))
        XCTAssertThrowsError(try SimklActivities(json: nil))
    }

    func testDeviceSignInStatesAndWriteAccess() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let approved = try SimklClient.parsePoll(status: 200, json: ["access_token": "simkl_at_a", "refresh_token": "simkl_rt_b",
            "token_type": "Bearer", "expires_in": 604_800, "scope": "media:read media:write"], now: now)
        guard case .approved(let tokens) = approved else { return XCTFail("Expected tokens") }
        XCTAssertTrue(tokens.canWrite)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(604_800))
        let readOnly = try SimklClient.parseTokens(["access_token": "a", "refresh_token": "b", "token_type": "bearer",
            "expires_in": 10, "scope": "media:read"], now: now)
        XCTAssertFalse(readOnly.canWrite, "Simkl quietly downgrades an unrecognised scope")
        XCTAssertEqual(try SimklClient.parsePoll(status: 400, json: ["error": "authorization_pending"], now: now), .pending)
        XCTAssertEqual(try SimklClient.parsePoll(status: 400, json: ["error": "slow_down"], now: now), .slowDown)
        XCTAssertEqual(try SimklClient.parsePoll(status: 400, json: ["error": "expired_token"], now: now), .expired)
        XCTAssertThrowsError(try SimklClient.parsePoll(status: 401, json: ["error": "invalid_client"], now: now)) {
            XCTAssertEqual($0 as? SimklFailure, .notConfigured)
        }
        XCTAssertThrowsError(try SimklClient.parseTokens(["access_token": "a b", "refresh_token": "b", "token_type": "Bearer",
            "expires_in": 10], now: now))
        let code = try SimklClient.parseDeviceAuthorization(["device_code": "secret", "user_code": "BDWP-HQPK",
            "verification_uri": "https://simkl.com/pin", "verification_uri_complete": "http://simkl.com/pin?user_code=BDWP-HQPK",
            "expires_in": 900, "interval": 1], now: now)
        XCTAssertEqual(code.interval, 5, "Never poll faster than five seconds")
        XCTAssertNil(code.completeURL, "Only an https approval link is opened")
        XCTAssertEqual(code.expiresAt, now.addingTimeInterval(900))
    }

    func testRedirectLookupReadsTheSimklIDForTheRightKind() {
        XCTAssertEqual(SimklClient.parseRedirect("https://simkl.com/movies/472214/inception", kind: .movie), 472214)
        XCTAssertNil(SimklClient.parseRedirect("https://simkl.com/movies/472214/inception", kind: .show))
        XCTAssertEqual(SimklClient.parseRedirect("/tv/17465/game-of-thrones", kind: .show), 17465)
        XCTAssertEqual(SimklClient.parseRedirect("https://simkl.com/anime/37089/cowboy-bebop", kind: .show), 37089)
        XCTAssertNil(SimklClient.parseRedirect("https://simkl.com/search/?q=x", kind: .movie))
        XCTAssertNil(SimklClient.parseRedirect("https://example.com/movies/1/x", kind: .movie))
        XCTAssertNil(SimklClient.parseRedirect(nil, kind: .movie))
    }

    func testRemovalOnlyEverSendsSimklIDsForUnwatchedPlanToWatchTitles() throws {
        let plan = SimklLibraryItem(simkl: 9, kind: .movie, type: "movies", status: .plantowatch, ids: SimklIDs(simkl: 9, tmdb: "1"),
                                    title: "Film", year: nil, watchedEpisodes: 0, lastWatchedAt: nil)
        let body = SimklClient.removeBody([plan])
        let movie = try XCTUnwrap((body["movies"] as? [[String: Any]])?.first)
        XCTAssertEqual(movie["ids"] as? [String: Int], ["simkl": 9])
        XCTAssertNil(movie["seasons"])
        XCTAssertEqual(try SimklClient.removeResult(["deleted": ["movies": 1], "not_found": ["movies": [], "shows": []]], items: [plan]), [0])
        XCTAssertEqual(try SimklClient.removeResult(["deleted": ["movies": 0], "not_found": ["movies": [["ids": ["simkl": 9]]]]], items: [plan]), [])
        runAsync {
            var watched = plan
            watched.lastWatchedAt = "2026-10-01T00:00:00Z"
            let stub = SimklTestTransport()
            stub.handler = { _ in XCTFail("A watched title must never be sent for removal"); return (500, "{}", [:]) }
            SimklStubProtocol.transport = stub
            do {
                _ = try await self.client().removeFromLibrary([watched], token: "token")
                XCTFail("Expected the removal to be refused")
            } catch { XCTAssertEqual(error as? SimklFailure, .incomplete) }
            XCTAssertTrue(stub.requests.isEmpty)
        }
    }

    func testRequestsCarryRequiredParametersAndReportTheDailyLimit() {
        runAsync {
            let stub = SimklTestTransport()
            stub.handler = { request in
                if request.url?.path == "/sync/activities" {
                    return (429, #"{"error":"user_limit_exceeded","code":429}"#, ["Retry-After": "120"])
                }
                return (200, #"{"user":{"name":"x"},"account":{"id":42,"type":"free"}}"#, ["X-RateLimit-Remaining": "17"])
            }
            SimklStubProtocol.transport = stub
            let client = self.client()
            let account = try await client.accountID(token: "token")
            XCTAssertEqual(account, 42)
            XCTAssertEqual(client.requestsRemaining, 17)
            let request = try XCTUnwrap(stub.requests.first)
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["client_id"], "test-client")
            XCTAssertEqual(query["app-name"], "vivid")
            XCTAssertNotNil(query["app-version"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Vivid/") == true)
            do {
                _ = try await client.activities(token: "token")
                XCTFail("Expected the daily limit")
            } catch { XCTAssertEqual(error as? SimklFailure, .quota(retryAfter: 120)) }
        }
    }

    func testQuotaResetWaitsForMidnightInNewYork() {
        // 30 October 2026, 23:00 in New York (UTC-4) is 03:00 UTC on the 31st.
        let date = Date(timeIntervalSince1970: 1_793_415_600)
        let wait = SimklClient.secondsUntilQuotaReset(from: date)
        XCTAssertEqual(wait, 3600 + 300, accuracy: 1)
    }

    func testProgressOnlyShowsKnownTotalsAndClampsCounts() {
        XCTAssertNil(SimklSyncProgress(step: 1, label: "Library").fraction)
        XCTAssertEqual(SimklSyncProgress(step: 2, label: "Watchlist", completed: 5, total: 20).fraction, 0.25)
        XCTAssertEqual(SimklSyncProgress(step: 3, label: "Watches", completed: 0, total: 0).fraction, 1)
        XCTAssertEqual(SimklSyncProgress(step: 2, label: "Watchlist", completed: 25, total: 20).description, "Step 2 of 3 · Watchlist · 20 of 20")
    }

    private func client() -> SimklClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimklStubProtocol.self]
        return SimklClient(configuration: configuration, clientID: "test-client")
    }

    private func runAsync(_ operation: @escaping () async throws -> Void) {
        let done = expectation(description: "request finished")
        Task {
            do { try await operation() } catch { XCTFail("Unexpected error: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}

private final class SimklTestTransport: @unchecked Sendable {
    var handler: ((URLRequest) -> (Int, String, [String: String]))!
    var requests: [URLRequest] = []
}

private final class SimklStubProtocol: URLProtocol, @unchecked Sendable {
    static var transport: SimklTestTransport!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let transport = Self.transport!
        transport.requests.append(request)
        let (status, body, headers) = transport.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                            headerFields: headers.merging(["Content-Type": "application/json"]) { current, _ in current })!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
