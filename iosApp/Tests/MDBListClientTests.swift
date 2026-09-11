import XCTest
@testable import Vivid

final class MDBListClientTests: XCTestCase {
    func testMDBListProgressOnlyShowsKnownTotalsAndClampsCounts() {
        XCTAssertNil(MDBListSyncProgress(step: 2, label: "Reading history").fraction)
        XCTAssertEqual(MDBListSyncProgress(step: 3, label: "Movies", completed: 5, total: 20).fraction, 0.25)
        XCTAssertEqual(MDBListSyncProgress(step: 4, label: "Episodes", completed: 25, total: 20).fraction, 1)
        XCTAssertEqual(MDBListSyncProgress(step: 1, label: "Watchlist", completed: 0, total: 0).fraction, 1)
        XCTAssertEqual(MDBListSyncProgress(step: 3, label: "Movies", completed: 5, total: 20).description, "Step 3 of 4 · Movies · 5 of 20")
    }

    func testOpenSubtitlesConnectionUsesDocumentedLanguagesResponse() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { request in
                XCTAssertEqual(request.url?.path, "/api/v1/infos/languages")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Api-Key"), "test-key")
                return (200, #"{"data":[{"language_code":"en","language_name":"English"},{"language_code":"pt-br","language_name":"Portuguese (Brazilian)"}]}"#)
            }
            MDBListStubProtocol.transport = stub
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MDBListStubProtocol.self]
            try await OpenSubtitlesClient(configuration: configuration).validate(key: "test-key")
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    func testOpenSubtitlesConnectionRejectsMalformedAndUnauthorisedResponses() {
        runAsync {
            for (status, body) in [(200, #"{"data":{"output_formats":["srt"]}}"#),
                                   (200, #"{"data":[]}"#), (200, #"{"data":[{"language_code":"en"}]}"#),
                                   (401, #"{"message":"Invalid API key"}"#)] {
                let stub = MDBListTestTransport()
                stub.handler = { _ in (status, body) }
                MDBListStubProtocol.transport = stub
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MDBListStubProtocol.self]
                do {
                    try await OpenSubtitlesClient(configuration: configuration).validate(key: "test-key")
                    XCTFail("Expected validation failure")
                } catch let error as OpenSubtitlesError {
                    if status == 401 { guard case .credentials = error else { XCTFail("Wrong error"); continue } }
                    else { guard case .response = error else { XCTFail("Wrong error"); continue } }
                }
                XCTAssertEqual(stub.requests.count, 1)
            }
        }
    }

    func testOpenSubtitlesSearchPreservesHTTPFailureCodeWithoutResponseDetails() {
        runAsync {
            for status in [400, 422, 500, 503] {
                let stub = MDBListTestTransport()
                stub.handler = { _ in (status, #"{"message":"private-response-detail"}"#) }
                MDBListStubProtocol.transport = stub
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MDBListStubProtocol.self]
                do {
                    _ = try await OpenSubtitlesClient(configuration: configuration).search(
                        OpenSubtitleQuery(title: "Series", type: "episode", season: 1, episode: 2), language: "en", key: "test-key")
                    XCTFail("Expected HTTP failure")
                } catch let error as OpenSubtitlesError {
                    guard case .httpStatus(let actual) = error else { XCTFail("Lost status code"); continue }
                    XCTAssertEqual(actual, status)
                    XCTAssertFalse(error.localizedDescription.contains("private-response-detail"))
                    XCTAssertFalse(error.localizedDescription.contains("test-key"))
                }
            }
        }
    }

    func testUnconfiguredOpenSubtitlesSearchDoesNotSendARequest() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { _ in XCTFail("Must not send a request"); return (500, "{}") }
            MDBListStubProtocol.transport = stub
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MDBListStubProtocol.self]
            do {
                _ = try await OpenSubtitlesClient(configuration: configuration).search(
                    OpenSubtitleQuery(title: "Movie", type: "movie", season: nil, episode: nil), language: "en", key: " ")
                XCTFail("Expected missing configuration")
            } catch let error as OpenSubtitlesError {
                guard case .notConfigured = error else { XCTFail("Wrong error"); return }
            }
            XCTAssertTrue(stub.requests.isEmpty)
        }
    }

    func testOpenSubtitlesCanonicalSearchRedirectKeepsKeyOnExactHTTPSAPIEndpoint() throws {
        var original = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/subtitles?query=Moana")!)
        original.setValue("test-key", forHTTPHeaderField: "Api-Key")
        let canonical = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/subtitles?query=moana")!)
        let redirected = try XCTUnwrap(OpenSubtitlesClient.canonicalSearchRedirect(original: original, proposed: canonical))
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Api-Key"), "test-key")
        for destination in ["http://api.opensubtitles.com/api/v1/subtitles", "https://evil.test/api/v1/subtitles",
                            "https://api.opensubtitles.com:8443/api/v1/subtitles", "https://api.opensubtitles.com/api/v1/download",
                            "https://user:pass@api.opensubtitles.com/api/v1/subtitles"] {
            XCTAssertNil(OpenSubtitlesClient.canonicalSearchRedirect(original: original, proposed: URLRequest(url: URL(string: destination)!)))
        }
        original.httpMethod = "POST"
        XCTAssertNil(OpenSubtitlesClient.canonicalSearchRedirect(original: original, proposed: canonical))
    }

    func testOpenSubtitlesUsesCanonicalSearchTextForMoana() {
        let query = OpenSubtitleQuery(title: "  Moana  ", type: "movie", season: nil, episode: nil)
        XCTAssertEqual(query.parameters(language: "en")["query"], "moana")
    }

    func testOpenSubtitlesEpisodeSearchKeepsSeasonAndEpisode() {
        let query = OpenSubtitleQuery(title: "Series", type: "episode", season: 2, episode: 3).parameters(language: "en")
        XCTAssertEqual(query["type"], "episode")
        XCTAssertEqual(query["season_number"], "2")
        XCTAssertEqual(query["episode_number"], "3")
        XCTAssertNil(OpenSubtitleQuery(title: "Film", type: "movie", season: 2, episode: 3).parameters(language: "en")["episode_number"])
    }

    func testOpenSubtitlesOnlyDownloadsHTTPSFromProviderHosts() {
        for url in ["https://dl.opensubtitles.com/file.srt", "https://dl.opensubtitles.org/file.srt"] {
            XCTAssertTrue(OpenSubtitlesClient.isDownloadURL(URL(string: url)!))
        }
        for url in ["http://dl.opensubtitles.com/file", "https://opensubtitles.com.evil.test/file", "https://evilopensubtitles.com/file", "https://user:pass@opensubtitles.com/file", "file:///tmp/file", "https://opensubtitles.com:8080/file"] {
            XCTAssertFalse(OpenSubtitlesClient.isDownloadURL(URL(string: url)!))
        }
    }

    func testOpenSubtitlesRejectsErrorPagesAndInvalidFiles() {
        XCTAssertTrue(OpenSubtitlesClient.isSubtitle(Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)))
        for text in ["", "<html>error --> error</html>", "unreadable", "\0 --> invalid"] {
            XCTAssertFalse(OpenSubtitlesClient.isSubtitle(Data(text.utf8)))
        }
    }

    func testOpenSubtitlesParsesFilesAndDeduplicatesIDs() throws {
        let file: [String: Any] = ["file_id": 12, "file_name": "Film.srt"]
        let result = try OpenSubtitlesClient.parseResults(["data": [["attributes": ["language": "en", "hearing_impaired": true, "files": [file, file]]]]])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 12)
        XCTAssertEqual(result.first?.name, "Film.srt")
        XCTAssertEqual(result.first?.hearingImpaired, true)
        XCTAssertThrowsError(try OpenSubtitlesClient.parseResults(["error": "invalid"]))
    }

    func testOpenSubtitlesDownloadNeverSendsAPIKeyToFileHost() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                if request.url?.host == "api.opensubtitles.com" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Api-Key"), "test-key")
                    XCTAssertEqual(request.url?.path, "/api/v1/download")
                    XCTAssertEqual(request.httpMethod, "POST")
                    return (200, #"{"link":"https://dl.opensubtitles.com/file.srt"}"#)
                }
                XCTAssertNil(request.value(forHTTPHeaderField: "Api-Key"))
                return (200, "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
            }
            MDBListStubProtocol.transport = stub
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MDBListStubProtocol.self]
            let result = OpenSubtitleResult(id: 12, name: "Film", language: "en", hearingImpaired: false)
            let data = try await OpenSubtitlesClient(configuration: configuration).download(result, key: "test-key")
            XCTAssertTrue(OpenSubtitlesClient.isSubtitle(data))
            XCTAssertEqual(stub.requests.count, 2)
        }
    }

    func testEmptyHistoryWithoutPaginationRemainsAValidConnectedAccount() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { request in
                if request.url?.path == "/user" { return (200, #"{"user_id":123}"#) }
                return (200, #"{"movies":[],"episodes":[]}"#)
            }
            MDBListStubProtocol.transport = stub
            let client = self.client()
            let userID = try await client.validate(key: "test-key")
            let history = try await client.history(key: "test-key")
            XCTAssertEqual(userID, 123)
            XCTAssertTrue(history.isEmpty)
            XCTAssertEqual(stub.requests.count, 3)
        }
    }

    func testBareEmptyHistoryAndWatchlistArraysAreValid() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { _ in (200, "[]") }
            MDBListStubProtocol.transport = stub
            let history = try await self.client().history(key: "test-key")
            let watchlist = try await self.client().watchlist(key: "test-key")
            XCTAssertTrue(history.isEmpty)
            XCTAssertTrue(watchlist.isEmpty)
        }
    }

    func testEmptyHistoryWithZeroTotalAndOmittedBuckets() throws {
        let page: [String: Any] = ["pagination": ["total": 0]]
        XCTAssertTrue(try MDBListClient.parseHistory(page, type: "episode").isEmpty)
        XCTAssertNil(try MDBListClient.historyNextCursor(page, itemCount: 0))
        XCTAssertThrowsError(try MDBListClient.parseHistory(["episodes": NSNull()], type: "episode"))
        XCTAssertThrowsError(try MDBListClient.parseHistory([:], type: "movie"))
        XCTAssertThrowsError(try MDBListClient.historyNextCursor(["pagination": ["total": 10, "offset": 0]], itemCount: 0))
        XCTAssertThrowsError(try MDBListClient.historyNextCursor(["_vividHasMore": true], itemCount: 0))
        XCTAssertThrowsError(try MDBListClient.historyNextCursor([:], itemCount: 1000))
    }

    func testWatchlistIncompletePagesCannotBecomeRemovalSnapshots() throws {
        XCTAssertThrowsError(try MDBListClient.watchlistNextCursor(["pagination": 42], itemCount: 1))
        XCTAssertThrowsError(try MDBListClient.watchlistNextCursor(["next_cursor": 42], itemCount: 1))
        XCTAssertThrowsError(try MDBListClient.watchlistNextCursor(["next_cursor": "", "_vividHasMore": true], itemCount: 1))
        XCTAssertThrowsError(try MDBListClient.watchlistNextCursor([:], itemCount: 1000))
        XCTAssertNil(try MDBListClient.watchlistNextCursor([:], itemCount: 12))
        XCTAssertEqual(try MDBListClient.watchlistNextCursor(["pagination": ["next_cursor": "page2"]], itemCount: 1000), "page2")
    }

    func testWatchlistFirstSyncMergesWithoutDeletingEitherList() {
        for local in [false, true] {
            for remote in [false, true] {
                XCTAssertEqual(MDBListWatchlistPolicy.desired(local: local, remote: remote,
                    previousLocal: nil, previousRemote: nil), local || remote)
            }
        }
    }

    func testWatchlistRemovalsPropagateFromEitherSideAndDoNotReappear() {
        XCTAssertFalse(MDBListWatchlistPolicy.desired(local: false, remote: true, previousLocal: true, previousRemote: true))
        XCTAssertFalse(MDBListWatchlistPolicy.desired(local: true, remote: false, previousLocal: true, previousRemote: true))
        XCTAssertFalse(MDBListWatchlistPolicy.desired(local: false, remote: false, previousLocal: false, previousRemote: false))
        XCTAssertTrue(MDBListWatchlistPolicy.desired(local: true, remote: false, previousLocal: false, previousRemote: false))
        XCTAssertTrue(MDBListWatchlistPolicy.desired(local: false, remote: true, previousLocal: false, previousRemote: false))
    }

    func testWatchlistInterruptedSyncReplaysTheSameRemoval() {
        XCTAssertFalse(MDBListWatchlistPolicy.desired(local: false, remote: false, previousLocal: true, previousRemote: true))
        XCTAssertTrue(MDBListWatchlistPolicy.desired(local: true, remote: true, previousLocal: nil, previousRemote: nil))
    }

    func testWatchlistMatchingRequiresSameMediaTypeAndConsistentExternalIDs() throws {
        let movie = try XCTUnwrap(MDBListWatchlistItem(type: "movie", title: "Same title", tmdb: "123", imdb: "tt123"))
        let show = try XCTUnwrap(MDBListWatchlistItem(type: "show", title: "Same title", tmdb: "123", imdb: "tt123"))
        let conflict = try XCTUnwrap(MDBListWatchlistItem(type: "movie", title: "Same title", tmdb: "123", imdb: "tt456"))
        XCTAssertFalse(movie.matches(show))
        XCTAssertFalse(movie.matches(conflict))
        XCTAssertTrue(movie.matches(MDBListWatchlistItem(type: "movie", title: "Localised title", tmdb: nil, imdb: "tt123")!))
        XCTAssertNil(MDBListWatchlistItem(type: "episode", title: "Episode", tmdb: "123", imdb: nil))
        XCTAssertNil(MDBListWatchlistItem(type: "show", title: "Show", tmdb: "0", imdb: "invalid"))
    }

    func testWatchlistParsesNestedAndLegacyIDs() throws {
        let movies = try MDBListClient.parseWatchlist(["movies": [["title": "Film", "id": 44, "ids": ["tmdb": 123, "imdb": "tt123"]]]], type: "movie")
        XCTAssertEqual(movies.first?.tmdb, "123")
        let shows = try MDBListClient.parseWatchlist(["shows": [["title": "Series", "id": 456, "imdb_id": "tt456"]]], type: "show")
        XCTAssertEqual(shows.first?.type, "show")
        XCTAssertEqual(shows.first?.tmdb, "456")
        XCTAssertThrowsError(try MDBListClient.parseWatchlist(["error": "unavailable"], type: "movie"))
        XCTAssertThrowsError(try MDBListClient.parseWatchlist(["movies": [["title": "No IDs"]]], type: "movie"))
    }

    func testWatchlistPaginationAndRepeatedCursorProtection() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { request in
                XCTAssertEqual(request.url?.path, "/watchlist/items")
                return (200, #"{"movies":[{"id":123,"title":"Film"}],"pagination":{"next_cursor":"same"}}"#)
            }
            MDBListStubProtocol.transport = stub
            do { _ = try await self.client().watchlist(key: "test-key"); XCTFail("Expected repeated cursor failure") }
            catch { XCTAssertTrue(error is MDBListFailure) }
            XCTAssertEqual(stub.requests.count, 2)
        }
    }

    func testWatchlistAddAndRemoveUseSeparateRoutesWithoutHistoryWrites() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertTrue(["/watchlist/items/add", "/watchlist/items/remove"].contains(request.url!.path))
                return (200, #"{"added":1,"existing":0,"not_found":0}"#)
            }
            MDBListStubProtocol.transport = stub
            let item = MDBListWatchlistItem(type: "show", title: "Series", tmdb: "123", imdb: nil)!
            try await self.client().setWatchlist(item, present: true, key: "test-key")
            try await self.client().setWatchlist(item, present: false, key: "test-key")
            XCTAssertEqual(stub.requests.map { $0.url!.path }, ["/watchlist/items/add", "/watchlist/items/remove"])
        }
    }

    func testImportOnlyAllowsKnownUnwatchedZeroProgress() {
        XCTAssertTrue(MDBListImportPolicy.isEligible(played: false, inProgress: false, position: 0, locallyStarted: false))
        XCTAssertFalse(MDBListImportPolicy.isEligible(played: true, inProgress: false, position: 0, locallyStarted: false))
        XCTAssertFalse(MDBListImportPolicy.isEligible(played: nil, inProgress: false, position: 0, locallyStarted: false))
        XCTAssertFalse(MDBListImportPolicy.isEligible(played: false, inProgress: false, position: nil, locallyStarted: false))
    }

    func testImportPreservesWatchesRewatchesAndPlaybackBeforeFirstReport() {
        for played in [false, true] {
            for position in [0.1, 60, 1800] {
                XCTAssertFalse(MDBListImportPolicy.isEligible(played: played, inProgress: false, position: position, locallyStarted: false))
            }
        }
        XCTAssertFalse(MDBListImportPolicy.isEligible(played: false, inProgress: true, position: 0, locallyStarted: false))
        XCTAssertFalse(MDBListImportPolicy.isEligible(played: false, inProgress: false, position: 0, locallyStarted: true))
        XCTAssertFalse(MDBListImportPolicy.isEligible(played: false, inProgress: false, position: .nan, locallyStarted: false))
        XCTAssertFalse(MDBListImportPolicy.isEligible(played: false, inProgress: false, position: -1, locallyStarted: false))
    }

    func testImportRejectsAmbiguousAndConflictingExternalIDs() {
        let tmdb = MDBListItemID(type: "movie", provider: "tmdb", value: "123")!
        let imdb = MDBListItemID(type: "movie", provider: "imdb", value: "tt12345")!
        let wrongIMDb = MDBListItemID(type: "movie", provider: "imdb", value: "tt54321")!
        XCTAssertTrue(MDBListImportPolicy.matches([tmdb, imdb], records: [[tmdb, imdb]]))
        XCTAssertTrue(MDBListImportPolicy.matches([tmdb, imdb], records: [[imdb]]))
        XCTAssertFalse(MDBListImportPolicy.matches([tmdb, imdb], records: [[tmdb, wrongIMDb]]))
        XCTAssertFalse(MDBListImportPolicy.matches([tmdb, imdb], records: [[tmdb, imdb], [tmdb, wrongIMDb]]))
        XCTAssertFalse(MDBListImportPolicy.matches([], records: [[tmdb]]))
    }

    func testImportDoesNotConfuseMoviesEpisodesOrSeriesIDs() {
        let movie = MDBListItemID(type: "movie", provider: "tmdb", value: "123")!
        let episode = MDBListItemID(type: "episode", provider: "tmdb", value: "123")!
        XCTAssertFalse(MDBListImportPolicy.matches([episode], records: [[movie]]))
        XCTAssertTrue(MDBListImportPolicy.matches([episode], records: [[episode], [episode]]))
    }

    func testEpisodeIDsNeverUseSeriesIMDb() throws {
        XCTAssertNil(MDBListItemID(type: "episode", provider: "imdb", value: "tt0903747"))
        XCTAssertNil(MDBListItemID(type: "show", provider: "tmdb", value: "1396"))
        XCTAssertNotEqual(MDBListItemID(type: "episode", provider: "tmdb", value: "123"),
                          MDBListItemID(type: "movie", provider: "tmdb", value: "123"))
    }

    func testRejectsMalformedIdentifiers() {
        for value in ["", "0", "-1", "nan", "12/34"] {
            XCTAssertNil(MDBListItemID(type: "movie", provider: "tmdb", value: value))
        }
        XCTAssertNil(MDBListItemID(type: "movie", provider: "imdb", value: "tt"))
        XCTAssertEqual(MDBListItemID(type: "movie", provider: "tmdb", value: "00123")?.value, "123")
    }

    func testReadsEpisodeOwnIDsInsteadOfParentIDs() throws {
        let page: [String: Any] = ["episodes": [["episode": [
            "ids": ["tmdb": 777, "tvdb": 888],
            "show": ["ids": ["tmdb": 123]], "season": 1, "number": 2
        ]]]]
        let item = try XCTUnwrap(MDBListClient.parseHistory(page, type: "episode").first)
        XCTAssertEqual(item.ids.count, 2)
        XCTAssertTrue(item.ids.contains(MDBListItemID(type: "episode", provider: "tmdb", value: "777")!))
        XCTAssertFalse(item.ids.contains(MDBListItemID(type: "episode", provider: "tmdb", value: "123")!))
    }

    func testMalformedSnapshotIsNotAnEmptyHistory() {
        XCTAssertThrowsError(try MDBListClient.parseHistory(["error": "unavailable"], type: "movie"))
        XCTAssertThrowsError(try MDBListClient.parseHistory(["movies": [["wrong": true]]], type: "movie"))
        XCTAssertNoThrow(try MDBListClient.parseHistory(["movies": []], type: "movie"))
    }

    func testCursorPaginationAndSeparateMediaTypes() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { request in
                let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let type = q.first { $0.name == "mediatype" }?.value
                let cursor = q.first { $0.name == "cursor" }?.value
                if type == "episode" { return (200, #"{"episodes":[],"pagination":{"next_cursor":null}}"#) }
                if cursor == nil { return (200, #"{"movies":[{"movie":{"ids":{"tmdb":1}}}],"pagination":{"next_cursor":"next"}}"#) }
                return (200, #"{"movies":[{"movie":{"ids":{"tmdb":2}}}],"pagination":{"next_cursor":null}}"#)
            }
            MDBListStubProtocol.transport = stub
            let history = try await self.client().history(key: "test-key")
            XCTAssertEqual(history.count, 2)
            XCTAssertEqual(stub.requests.count, 3)
            XCTAssertTrue(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        }
    }

    func testMalformedCursorAbortsInsteadOfAcceptingPartialSnapshot() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { _ in (200, #"{"movies":[],"pagination":{"next_cursor":123}}"#) }
            MDBListStubProtocol.transport = stub
            do { _ = try await self.client().history(key: "test-key"); XCTFail("Expected invalid cursor") }
            catch { XCTAssertTrue(error is MDBListFailure) }
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    func testRepeatedCursorAbortsInsteadOfDuplicatingHistory() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { _ in (200, #"{"movies":[],"pagination":{"next_cursor":"same"}}"#) }
            MDBListStubProtocol.transport = stub
            do { _ = try await self.client().history(key: "test-key"); XCTFail("Expected pagination failure") }
            catch { XCTAssertTrue(error is MDBListFailure) }
            XCTAssertEqual(stub.requests.count, 2)
        }
    }

    func testUncertainWriteUsesTheSuppliedStableDateAndDoesNotRetry() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { _ in (500, #"{"error":"unavailable"}"#) }
            MDBListStubProtocol.transport = stub
            do {
                try await self.client().add(MDBListItemID(type: "episode", provider: "tmdb", value: "777")!,
                                            watchedAt: "2026-09-11T00:00:00Z", key: "test-key")
                XCTFail("Expected server failure")
            } catch { XCTAssertTrue(error is MDBListFailure) }
            XCTAssertEqual(stub.requests.count, 1)
            let body = try XCTUnwrap(stub.bodies.first)
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertNil(json["shows"])
            let entry = (json["episodes"] as! [[String: Any]])[0]
            XCTAssertEqual(entry["watched_at"] as? String, "2026-09-11T00:00:00Z")
        }
    }

    func testHistoryBatchUploadsFiftyEpisodesInOneRequest() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { _ in (200, #"{"updated":{"episodes":50},"not_found":{},"errors":[]}"#) }
            MDBListStubProtocol.transport = stub
            let items = (1...50).map { MDBListItemID(type: "episode", provider: "tmdb", value: String($0))! }
            let accepted = try await self.client().addBatch(items.map { ($0, "stable-date") }, key: "test-key")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(stub.bodies.first)) as! [String: Any]
            let episodes = body["episodes"] as! [[String: Any]]
            XCTAssertEqual(episodes.count, 50)
            XCTAssertNil(body["shows"])
            XCTAssertEqual(episodes.last?["watched_at"] as? String, "stable-date")
            XCTAssertEqual(accepted, Set(items))
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    func testUnmatchedEpisodeDoesNotAbortBatchOrAcknowledgeUnconfirmedItems() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { _ in
                (200, #"{"updated":{"episodes":1},"not_found":{"episodes":[{"ids":{"tmdb":43}}]},"errors":[],"plays":[{"type":"episode","ids":{"tmdb":44}}]}"#)
            }
            MDBListStubProtocol.transport = stub
            let missing = MDBListItemID(type: "episode", provider: "tmdb", value: "43")!
            let found = MDBListItemID(type: "episode", provider: "tmdb", value: "44")!
            let accepted = try await self.client().addBatch([(missing, "date"), (found, "date")], key: "test-key")
            XCTAssertEqual(accepted, [found])
        }
    }

    func testPartialHistoryBatchWithoutPlaysRemainsUnconfirmed() {
        runAsync {
            let stub = MDBListTestTransport()
            stub.handler = { _ in (200, #"{"updated":{"episodes":0},"not_found":{},"errors":[{"message":"unresolved"}]}"#) }
            MDBListStubProtocol.transport = stub
            let item = MDBListItemID(type: "episode", provider: "tmdb", value: "43")!
            let accepted = try await self.client().addBatch([(item, "date")], key: "test-key")
            XCTAssertTrue(accepted.isEmpty)
        }
    }

    func testNullOrEmptyHistoryCursorCannotHideAnUnprovenFullPage() throws {
        for cursor: Any in [NSNull(), ""] {
            XCTAssertThrowsError(try MDBListClient.historyNextCursor(["next_cursor": cursor], itemCount: 1000))
            XCTAssertNil(try MDBListClient.historyNextCursor(["next_cursor": cursor, "pagination": ["total": 1000, "offset": 0]], itemCount: 1000))
            XCTAssertNil(try MDBListClient.historyNextCursor(["next_cursor": cursor], itemCount: 3))
        }
    }

    func testDownloadedSubtitleAndSelectionSurviveSameItemReplacement() {
        var files = OpenSubtitleSessionFiles()
        XCTAssertTrue(files.prepare(contentID: "movie").isEmpty)
        let url = URL(fileURLWithPath: "/tmp/test-subtitle.srt")
        _ = files.register(.init(id: 7, url: url, name: "Subtitle", language: "en", hearingImpaired: false))
        files.selectedID = 7
        XCTAssertTrue(files.prepare(contentID: "movie").isEmpty)
        XCTAssertEqual(files.entries[7]?.url, url)
        XCTAssertEqual(files.selectedID, 7)
        files.selectedID = nil
        XCTAssertTrue(files.prepare(contentID: "movie").isEmpty)
        XCTAssertNil(files.selectedID, "Off must remain off after replacement")
    }

    func testDownloadedSubtitlesNeverCarryIntoAnotherEpisodeOrSurviveFinalCleanup() {
        var files = OpenSubtitleSessionFiles()
        _ = files.prepare(contentID: "episode-1")
        let url = URL(fileURLWithPath: "/tmp/test-subtitle.srt")
        _ = files.register(.init(id: 7, url: url, name: "Subtitle", language: "en", hearingImpaired: false))
        files.selectedID = 7
        XCTAssertEqual(files.prepare(contentID: "episode-2"), [url])
        XCTAssertTrue(files.entries.isEmpty)
        XCTAssertNil(files.selectedID)
        _ = files.register(.init(id: 8, url: url, name: "Other", language: "en", hearingImpaired: false))
        XCTAssertEqual(files.clear(), [url])
        XCTAssertTrue(files.entries.isEmpty)
        XCTAssertNil(files.contentID)
    }

    private func client() -> MDBListClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MDBListStubProtocol.self]
        return MDBListClient(configuration: configuration)
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

private final class MDBListTestTransport: @unchecked Sendable {
    var handler: ((URLRequest) -> (Int, String))!
    var requests: [URLRequest] = []
    var bodies: [Data] = []
}

private final class MDBListStubProtocol: URLProtocol, @unchecked Sendable {
    static var transport: MDBListTestTransport!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let transport = Self.transport!
        transport.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
            transport.bodies.append(body)
        } else if let body = request.httpBody { transport.bodies.append(body) }
        let (status, body) = transport.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
