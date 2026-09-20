import XCTest
@testable import Vivid

final class JellyfinAdapterTests: XCTestCase {
    private var session: URLSession?
    private let user = "11111111111111111111111111111111"
    private let item = "22222222222222222222222222222222"
    private let source = "33333333333333333333333333333333"

    override func tearDown() {
        session?.invalidateAndCancel()
        session = nil
        JellyfinRequestStub.handler = nil
        super.tearDown()
    }

    private func adapter(_ handler: @escaping (URLRequest) throws -> (Int, Any)) -> JellyfinAdapter {
        JellyfinRequestStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JellyfinRequestStub.self]
        let session = URLSession(configuration: configuration)
        self.session = session
        return JellyfinAdapter(connection: JellyfinConnection(
            serverURL: "https://media.example.test/jellyfin", token: "test-token", userID: user,
            identity: nil, sessionOverride: session))
    }

    func testPeopleNavigationRoundTripsNativeIDsAndKeepsAccountsSeparate() async throws {
        let nativeID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let adapter = adapter { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if request.url!.path.hasSuffix("/Items") {
                XCTAssertEqual(query.first { $0.name == "PersonIds" }?.value, nativeID)
                return (200, ["Items": [], "TotalRecordCount": 0])
            }
            XCTAssertEqual(request.url!.path, "/jellyfin/Items/" + nativeID)
            return (200, ["Id": nativeID, "Name": "Example Person", "Type": "Person"])
        }
        let mapped = try adapter.item(["Id": item, "Name": "Film", "Type": "Movie", "People": [
            ["Id": nativeID, "Name": "Example Person", "Type": "Actor", "Role": "Lead"],
            ["Id": nativeID, "Name": "Example Person", "Type": "Director"]
        ]])
        let cast = try XCTUnwrap(mapped["cast"] as? [[String: Any]])
        let crew = try XCTUnwrap(mapped["crew"] as? [[String: Any]])
        let routeID = try XCTUnwrap(cast.first?["personId"] as? String)
        XCTAssertNotNil(Int(routeID))
        XCTAssertEqual(crew.first?["personId"] as? String, routeID)
        XCTAssertEqual(crew.first?["job"] as? String, "Director")
        let person = try await adapter.route(method: "GET", path: "/api/v1/people/" + routeID, query: [:], body: nil)
        let decoded: Person = try JellyfinAdapter.decode(person)
        XCTAssertEqual(decoded.id, Int(routeID))
        _ = try await adapter.route(method: "GET", path: "/api/v1/catalog", query: ["person_id": routeID], body: nil)
        let other = JellyfinAdapter(connection: JellyfinConnection(serverURL: adapter.connection.serverURL,
            token: "another-token", userID: "other-user", identity: nil, sessionOverride: session))
        do {
            _ = try await other.route(method: "GET", path: "/api/v1/people/" + routeID, query: [:], body: nil)
            XCTFail("A different profile must not inherit the first profile's person mapping")
        } catch JellyfinError.invalidResponse { }
        UserDefaults.standard.removeObject(forKey: "vivid.jellyfin." + adapter.connection.serverURL + "." + user + ".person." + routeID)
    }

    func testLocalSettingsAreIsolatedAndPersistAcrossReload() async throws {
        let suite = "jellyfin-settings-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = JellyfinLocalPreferences(defaults: defaults)
        for (key, value) in [("playback.subtitle_language", "eng"), ("playback.subtitle_mode", "always"), ("playback.audio_language", "fra")] {
            _ = try await preferences.apply(storageKey: JellyfinLocalPreferences.storageKey(serverID: "account-one", userID: "one"), user: "one", method: "PUT",
                path: ["api", "v1", "settings", "values", key], query: ["scope": "profile_device"], body: ["value": value])
        }
        let reloaded = JellyfinLocalPreferences(defaults: defaults)
        func read(server: String, user: String) async throws -> [[String: Any]] {
            let raw = try await reloaded.apply(storageKey: JellyfinLocalPreferences.storageKey(serverID: server, userID: user), user: user, method: "GET",
                path: ["api", "v1", "settings", "values", "effective"],
                query: ["keys": "playback.subtitle_language,playback.subtitle_mode,playback.audio_language"], body: [:])
            let result = try XCTUnwrap(raw as? [String: Any])
            return try XCTUnwrap(result["settings"] as? [[String: Any]])
        }
        let first = try await read(server: "account-one", user: "one")
        XCTAssertEqual(first.map { $0["value"] as? String }, ["eng", "always", "fra"])
        for (server, user) in [("account-one", "two"), ("account-two", "one")] {
            let second = try await read(server: server, user: user)
            XCTAssertTrue(second[0]["value"] is NSNull)
            XCTAssertEqual(second[1]["value"] as? String, "auto")
            XCTAssertTrue(second[2]["value"] is NSNull)
        }
    }

    func testQualityCapRequiresResizeForHigherResolutionSource() throws {
        var body: [String: Any] = ["EnableDirectPlay": true, "EnableDirectStream": true,
            "DeviceProfile": ["TranscodingProfiles": [["Type": "Video"]]]]
        JellyfinPlayback.applyPlaybackLimits(to: &body,
            source: ["MediaStreams": [["Type": "Video", "Height": 2160]]],
            quality: "1080p-high", hdr: true, dolbyVision: true)
        XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false)
        XCTAssertEqual(body["AllowVideoStreamCopy"] as? Bool, false)
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        XCTAssertEqual((profile["TranscodingProfiles"] as? [[String: Any]])?.first?["MaxHeight"] as? Int, 1080)
    }

    func testEpisodeAndSeasonWatchStateSurvivesDetailMapping() async throws {
        let adapter = adapter { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "UserId" }?.value, self.user)
            XCTAssertEqual(query.first { $0.name == "EnableUserData" }?.value, "true")
            if request.url!.path.hasSuffix("/Seasons") {
                return (200, ["Items": [["Id": "season3", "Name": "Season 3", "Type": "Season", "IndexNumber": 3,
                    "RecursiveItemCount": 50, "UserData": ["Played": false, "UnplayedItemCount": 24]]]])
            }
            XCTAssertEqual(query.first { $0.name == "Season" }?.value, "3")
            return (200, ["Items": [
                ["Id": "watched", "Name": "Watched", "Type": "Episode", "ParentIndexNumber": 3, "IndexNumber": 38,
                 "RunTimeTicks": 4_000_000_000, "UserData": ["Played": true, "PlaybackPositionTicks": 0]],
                ["Id": self.item, "Name": "Resume", "Type": "Episode", "ParentIndexNumber": 3, "IndexNumber": 39,
                 "RunTimeTicks": 4_000_000_000, "UserData": ["Played": false, "PlaybackPositionTicks": 2_981_729_964]]
            ]])
        }
        let seasons = try await adapter.route(method: "GET", path: "/api/v1/catalog/series/show/seasons", query: [:], body: nil)
        let seasonResponse: SeasonsResponse = try JellyfinAdapter.decode(seasons)
        XCTAssertEqual(seasonResponse.seasons.first?.seasonNumber, 3)
        XCTAssertEqual(seasonResponse.seasons.first?.userData?.watchedCount, 26)
        XCTAssertEqual(seasonResponse.seasons.first?.userData?.unplayedCount, 24)
        let episodes = try await adapter.route(method: "GET", path: "/api/v1/catalog/series/show/seasons/3/episodes", query: [:], body: nil)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(EpisodesResponse.self, from: JSONSerialization.data(withJSONObject: episodes))
        XCTAssertEqual(response.episodes[0].userData?.played, true)
        XCTAssertEqual(response.episodes[1].userData?.played, false)
        XCTAssertEqual(response.episodes[1].userData?.isInProgress, true)
        XCTAssertEqual(try XCTUnwrap(response.episodes[1].userData?.positionSeconds), 298.1729964, accuracy: 0.0001)
        XCTAssertEqual(response.episodes[1].seasonNumber, 3)
        XCTAssertEqual(response.episodes[1].episodeNumber, 39)
    }

    func testResumeEpisodeUsesExactVersionInsteadOfSeasonRepresentative() async throws {
        let adapter = adapter { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "UserId" }?.value, self.user)
            XCTAssertFalse(query.contains { $0.name == "resume_episode_id" })
            if request.url!.path.hasSuffix("/Episodes") {
                return (200, ["Items": [
                    ["Id": "earlier", "Name": "Earlier", "Type": "Episode", "SeriesId": "show",
                     "ParentIndexNumber": 2, "IndexNumber": 1, "UserData": ["Played": false]],
                    ["Id": "representative", "Name": "Episode", "Type": "Episode", "SeriesId": "show",
                     "ParentIndexNumber": 2, "IndexNumber": 3,
                     "UserData": ["Played": false, "PlaybackPositionTicks": 0]]
                ]])
            }
            XCTAssertEqual(request.url!.path, "/jellyfin/Items/" + self.item)
            return (200, ["Id": self.item, "Name": "Resume version", "Type": "Episode", "SeriesId": "show",
                "ParentIndexNumber": 2, "IndexNumber": 3, "RunTimeTicks": 30_000_000_000,
                "UserData": ["Played": false, "PlaybackPositionTicks": 13_077_083_599],
                "MediaSources": [["Id": self.source, "Name": "1080p", "MediaStreams": [
                    ["Type": "Video", "Index": 0, "Codec": "h264", "Height": 1080],
                    ["Type": "Audio", "Index": 1, "Codec": "aac", "Language": "eng"],
                    ["Type": "Subtitle", "Index": 2, "Codec": "srt", "Language": "eng"]]]]])
        }
        let raw = try await adapter.route(method: "GET", path: "/api/v1/catalog/series/show/seasons/2/episodes",
            query: ["resume_episode_id": item], body: nil)
        let response: EpisodesResponse = try JellyfinAdapter.decode(raw)
        XCTAssertEqual(response.episodes.count, 2)
        XCTAssertEqual(response.episodes[0].contentId, "earlier")
        XCTAssertEqual(response.episodes[0].userData?.played, false)
        let selected = try XCTUnwrap(response.episodes.first { $0.contentId == item })
        XCTAssertEqual(selected.seasonNumber, 2)
        XCTAssertEqual(selected.episodeNumber, 3)
        XCTAssertEqual(selected.userData?.isInProgress, true)
        XCTAssertEqual(try XCTUnwrap(selected.userData?.positionSeconds), 1307.7083599, accuracy: 0.0001)
        XCTAssertEqual(selected.files?.first?.fileId, JellyfinAdapter.numberID(source))
        let watch: WatchDetail = try JellyfinAdapter.decode(try adapter.watch(
            try await adapter.rawItem(item), preferences: [:]))
        XCTAssertEqual(watch.versions.first?.audioTracks?.count, 1)
        XCTAssertEqual(watch.versions.first?.subtitleTracks?.count, 1)
        XCTAssertEqual(watch.userData?.positionSeconds, selected.userData?.positionSeconds)
    }

    func testResumeEpisodeRejectsDifferentSeriesOrSeason() async throws {
        for (series, season) in [("other-show", 2), ("show", 1)] {
            let adapter = adapter { request in
                if request.url!.path.hasSuffix("/Episodes") { return (200, ["Items": []]) }
                return (200, ["Id": self.item, "Name": "Wrong route", "Type": "Episode", "SeriesId": series,
                              "ParentIndexNumber": season, "IndexNumber": 3])
            }
            do {
                _ = try await adapter.episodes(seriesID: "show", seasonNumber: "2", resumeEpisodeID: item)
                XCTFail("A different series or season must not be inserted into this page")
            } catch JellyfinError.invalidResponse { }
            session?.invalidateAndCancel()
        }
    }

    func testMissingResumeVersionPreservesSeasonRowsAndTheirWatchState() async throws {
        let adapter = adapter { request in
            if request.url!.path.hasSuffix("/Episodes") {
                return (200, ["Items": [["Id": "earlier", "Name": "Earlier", "Type": "Episode",
                    "SeriesId": "show", "ParentIndexNumber": 2, "IndexNumber": 1,
                    "UserData": ["Played": true, "PlaybackPositionTicks": 0]]]])
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/Items/" + self.item))
            return (404, [:]) // Both the current and legacy item routes are absent.
        }
        let response: EpisodesResponse = try JellyfinAdapter.decode(try await adapter.episodes(
            seriesID: "show", seasonNumber: "2", resumeEpisodeID: item))
        XCTAssertEqual(response.episodes.map(\.contentId), ["earlier"])
        XCTAssertEqual(response.episodes.first?.userData?.played, true)
        XCTAssertEqual(response.episodes.first?.userData?.positionSeconds, 0)
        XCTAssertFalse(response.episodes.contains { $0.contentId == item })
    }

    func testResumeFetchDoesNotHideAuthenticationOrServerFailures() async throws {
        for status in [401, 403, 500] {
            let adapter = adapter { request in
                request.url!.path.hasSuffix("/Episodes") ? (200, ["Items": []]) : (status, [:])
            }
            do {
                _ = try await adapter.episodes(seriesID: "show", seasonNumber: "2", resumeEpisodeID: item)
                XCTFail("Resume failure must propagate: \(status)")
            } catch JellyfinError.signInRequired {
                XCTAssertEqual(status, 401)
            } catch HTTPError.http(let actual, _) {
                XCTAssertEqual(actual, status)
            }
            session?.invalidateAndCancel()
        }
    }

    func testResumeFetchDoesNotHideTransportFailureOrCancellation() async throws {
        for code in [URLError.timedOut, URLError.cancelled] {
            let adapter = adapter { request in
                if request.url!.path.hasSuffix("/Episodes") { return (200, ["Items": []]) }
                throw URLError(code)
            }
            do {
                _ = try await adapter.episodes(seriesID: "show", seasonNumber: "2", resumeEpisodeID: item)
                XCTFail("Transport failures must propagate")
            } catch let error as URLError {
                XCTAssertEqual(error.code, code)
            }
            session?.invalidateAndCancel()
        }
    }

    func testMissingSeasonStillFailsWhenResumeIsMissing() async throws {
        let adapter = adapter { _ in (404, [:]) }
        do {
            _ = try await adapter.episodes(seriesID: "show", seasonNumber: "2", resumeEpisodeID: item)
            XCTFail("Only the optional resume item may be absent")
        } catch HTTPError.http(let status, _) {
            XCTAssertEqual(status, 404)
        }
    }

    func testResumeEpisodeMissingFromSeasonListIsRetained() async throws {
        let adapter = adapter { request in
            if request.url!.path.hasSuffix("/Episodes") { return (200, ["Items": []]) }
            return (200, ["Id": self.item, "Name": "Resume", "Type": "Episode", "SeriesId": "show",
                          "ParentIndexNumber": 2, "IndexNumber": 3,
                          "UserData": ["Played": false, "PlaybackPositionTicks": 50_000_000]])
        }
        let response: EpisodesResponse = try JellyfinAdapter.decode(try await adapter.episodes(
            seriesID: "show", seasonNumber: "2", resumeEpisodeID: item))
        XCTAssertEqual(response.episodes.map(\.contentId), [item])
        XCTAssertEqual(response.episodes.first?.userData?.positionSeconds, 5)
    }

    func testSeriesCardsUseMainPosterAndKeepEpisodeStillsSeparate() throws {
        let adapter = adapter { _ in XCTFail("Artwork mapping needs no metadata request"); return (200, [:]) }
        for kind in ["Episode", "Season"] {
            let raw: [String: Any] = ["Id": item, "Name": "Episode or season", "Type": kind,
                "SeriesId": "parent-series", "ImageTags": ["Primary": "own-art"],
                "SeriesPrimaryImageTag": "series-art"]
            let mapped = try adapter.item(raw)
            let poster = try XCTUnwrap(URLComponents(string: try XCTUnwrap(mapped["posterUrl"] as? String)))
            XCTAssertEqual(poster.path, "/jellyfin/Items/parent-series/Images/Primary")
            XCTAssertEqual(poster.queryItems?.first { $0.name == "tag" }?.value, "series-art")
            let still = try XCTUnwrap(URLComponents(string: try XCTUnwrap(mapped["stillUrl"] as? String)))
            XCTAssertEqual(still.path, "/jellyfin/Items/" + item + "/Images/Primary")
            var missingTag = raw
            missingTag.removeValue(forKey: "SeriesPrimaryImageTag")
            let untagged = try XCTUnwrap(URLComponents(string: try XCTUnwrap(adapter.poster(missingTag))))
            XCTAssertEqual(untagged.path, poster.path)
            XCTAssertNil(untagged.queryItems?.first { $0.name == "tag" })
        }
        for kind in ["Series", "Movie"] {
            let mapped = try adapter.item(["Id": item, "Name": "Title", "Type": kind,
                                           "ImageTags": ["Primary": "own-art"]])
            let poster = try XCTUnwrap(URLComponents(string: try XCTUnwrap(mapped["posterUrl"] as? String)))
            XCTAssertEqual(poster.path, "/jellyfin/Items/" + item + "/Images/Primary")
        }
    }

    func testResumeAndNextUpCardsUseEpisodePreviewWithoutReplacingSeriesPoster() throws {
        let adapter = adapter { _ in return (200, [:]) }
        let mapped = try adapter.item(["Id": item, "Name": "Episode", "Type": "Episode",
            "SeriesId": "parent-series", "ImageTags": ["Primary": "episode-preview"],
            "SeriesPrimaryImageTag": "series-poster", "ParentBackdropItemId": "parent-series",
            "ParentBackdropImageTags": ["series-backdrop"]])
        for row in ["continue_watching", "next_up", "latestmedia_library"] {
            let section = adapter.section(row, row, ["items": [mapped]])
            let card = try XCTUnwrap((section["items"] as? [[String: Any]])?.first)
            XCTAssertEqual(card["posterUrl"] as? String, mapped["posterUrl"] as? String)
            XCTAssertEqual(card["backdropUrl"] as? String,
                mapped[row == "latestmedia_library" ? "backdropUrl" : "stillUrl"] as? String)
        }
    }

    func testBrowseRequestsOnlyCardMetadataAndKeepsWatchState() async throws {
        let adapter = adapter { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let fields = query.first { $0.name == "Fields" }?.value ?? ""
            XCTAssertEqual(fields, JellyfinAdapter.browseFields)
            for omitted in ["People", "MediaSources", "MediaStreams", "Chapters"] {
                XCTAssertFalse(fields.split(separator: ",").contains(Substring(omitted)))
            }
            XCTAssertEqual(query.first { $0.name == "EnableUserData" }?.value, "true")
            XCTAssertEqual(query.first { $0.name == "StartIndex" }?.value, "60")
            return (200, ["Items": [["Id": self.item, "Name": "Film", "Type": "Movie",
                "UserData": ["Played": true, "IsFavorite": true]]], "TotalRecordCount": 120])
        }
        let response: CatalogResponse = try JellyfinAdapter.decode(try await adapter.catalog(["offset": "60", "limit": "60"]))
        XCTAssertEqual(response.items.first?.userState?.played, true)
        XCTAssertEqual(response.items.first?.userState?.isFavorite, true)
        XCTAssertEqual(response.total, 120)
        XCTAssertEqual(response.hasMore, true)
    }

    func testLibraryDirectoryIsIsolatedByUserServerAndLoginEpochAndExpires() async throws {
        let directory = JellyfinLibraryDirectory()
        let epoch = UUID()
        func connection(server: String = "jellyfin:one", user: String = "one", generation: UUID) -> JellyfinConnection {
            let account = RefreshAccountIdentity(serverId: server, serverURL: "https://media.example.test", credentialGenerationID: generation)
            let auth = CapturedOrdinaryRequestAuth(account: account, credentialOwner: .persistentServer(serverId: server),
                accessToken: "test-token", profileId: user, profileToken: nil)
            return JellyfinConnection(serverURL: account.serverURL, token: auth.accessToken, userID: user, identity: auth)
        }
        let original = connection(generation: epoch)
        let start = Date(timeIntervalSince1970: 1000)
        await directory.remember([["Id": "library-one"]], connection: original, now: start)
        let id = String(JellyfinAdapter.numberID("library-one"))
        let cached = await directory.nativeID(id, connection: original, now: start)
        XCTAssertEqual(cached, "library-one")
        for other in [connection(user: "two", generation: epoch), connection(server: "jellyfin:two", generation: epoch), connection(generation: UUID())] {
            let leaked = await directory.nativeID(id, connection: other, now: start)
            XCTAssertNil(leaked)
        }
        let expired = await directory.nativeID(id, connection: original, now: start.addingTimeInterval(301))
        XCTAssertNil(expired)
    }

    func testDownloadStatusRejectsDelayedAndReplayedUpdates() throws {
        let row: [String: Any] = ["status": "completed", "revision": 2, "updatedAt": "2026-09-20T06:00:02.000Z"]
        XCTAssertNil(try JellyfinDownloads.updatedStatus(row: row, body: ["status": "downloading", "revision": 1, "updated_at": "2026-09-20T06:00:03.000Z"]))
        XCTAssertNil(try JellyfinDownloads.updatedStatus(row: row, body: ["status": "downloading", "revision": 2, "updated_at": "2026-09-20T06:00:01.000Z"]))
        XCTAssertNil(try JellyfinDownloads.updatedStatus(row: row, body: ["status": "downloading", "revision": 2, "updated_at": "2026-09-20T06:00:03.000Z"]))
        let next = try XCTUnwrap(JellyfinDownloads.updatedStatus(row: row, body: ["status": "downloading", "revision": 3, "updated_at": "2026-09-20T06:00:03.000Z"]))
        XCTAssertEqual(next["revision"] as? Int, 3)
        XCTAssertEqual(next["updatedAt"] as? String, "2026-09-20T06:00:03.000Z")
        let completed = try XCTUnwrap(JellyfinDownloads.updatedStatus(row: next, body: ["status": "completed", "revision": 3, "updated_at": "2026-09-20T06:00:04.000Z"]))
        XCTAssertEqual(completed["status"] as? String, "completed")
        XCTAssertThrowsError(try JellyfinDownloads.updatedStatus(row: row, body: ["status": "completed", "updated_at": "invalid-date"]))
    }

    func testLegacySettingsWithoutCapturedIdentityKeepTheirKeyFormat() async throws {
        let adapter = adapter { _ in XCTFail("Local settings must not request the server"); return (500, [:]) }
        let key = "test." + UUID().uuidString
        let path = "/api/v1/settings/" + key
        defer { UserDefaults.standard.removeObject(forKey: "vivid.jellyfin.setting." + adapter.connection.serverURL + "." + user + "." + key) }
        _ = try await adapter.route(method: "PUT", path: path, query: [:], body: ["value": "saved"])
        let value = try await adapter.route(method: "GET", path: path, query: [:], body: nil)
        XCTAssertEqual((value as? [String: Any])?["value"] as? String, "saved")
    }

    @MainActor
    func testReplacementRetiresLastQualifiedPositionAndPreservesPreviewState() async throws {
        var bodies: [[String: Any]] = []
        let adapter = adapter { request in
            bodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]))
            return (200, [:])
        }
        let stream = StreamRequest(url: URL(string: "https://media.example.test/stream")!, headers: [:], serverUrl: adapter.connection.serverURL)
        let qualified = JellyfinPlayback(connection: adapter.connection, itemID: item, sourceID: source,
            playSessionID: "old-session", stream: stream, method: "DirectPlay", audioIndex: nil, subtitleIndex: nil, position: 0)
        try await qualified.report(position: 72, isPaused: false)
        try await qualified.retireForReplacement()
        XCTAssertEqual(bodies.last?["PlaySessionId"] as? String, "old-session")
        XCTAssertEqual(bodies.last?["PositionTicks"] as? Int64, 720_000_000)
        let count = bodies.count
        try await qualified.retireForReplacement()
        XCTAssertEqual(bodies.count, count)
        let preview = JellyfinPlayback(connection: adapter.connection, itemID: item, sourceID: source,
            playSessionID: "preview", stream: stream, method: "DirectPlay", audioIndex: nil, subtitleIndex: nil, position: 12)
        try await preview.retireForReplacement()
        XCTAssertEqual(bodies.last?["Failed"] as? Bool, true)
        XCTAssertNil(bodies.last?["PositionTicks"])
    }

    func testProviderIdentityAndBasePathsStaySeparate() throws {
        XCTAssertEqual(MediaServerProvider.forServerID("jellyfin:one"), .jellyfin)
        XCTAssertEqual(MediaServerProvider.forServerID("emby:one"), .emby)
        XCTAssertEqual(MediaServerProvider.forServerID("one"), .silo)
        XCTAssertEqual(try JellyfinConnection.url(serverURL: "https://media.example.test", path: "/Items").path, "/Items")
        XCTAssertEqual(try JellyfinConnection.url(serverURL: "https://media.example.test/media/", path: "/Items").path, "/media/Items")
        XCTAssertEqual(try EmbyConnection.url(serverURL: "https://media.example.test", path: "/Items").path, "/emby/Items")
        XCTAssertThrowsError(try JellyfinConnection.url(serverURL: "https://media.example.test", path: "//other.example/Items"))
        XCTAssertThrowsError(try JellyfinConnection.url(serverURL: "https://media.example.test", path: "/../Items"))
    }

    func testNativeAuthenticationAndUserScope() async throws {
        let adapter = adapter { request in
            XCTAssertEqual(request.url?.path, "/jellyfin/Items")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "UserId" }?.value, self.user)
            XCTAssertFalse(query.contains { $0.name.lowercased().contains("token") || $0.name == "api_key" })
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser ") == true)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"test-token\"") == true)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Token"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Emby-Token"))
            return (200, ["Items": [], "TotalRecordCount": 0])
        }
        _ = try await adapter.items(query: ["UserId":"other-account"])
    }

    func testLegacyJellyfinRetryOnlyForMapped404() async throws {
        var paths: [String] = []
        let adapter = adapter { request in
            paths.append(request.url!.path)
            if paths.count == 1 { return (404, [:]) }
            return (200, ["Id":self.item,"Name":"Example","Type":"Movie"])
        }
        _ = try await adapter.rawItem(item)
        XCTAssertEqual(paths, ["/jellyfin/Items/" + item, "/jellyfin/Users/" + user + "/Items/" + item])
        paths.removeAll()
        JellyfinRequestStub.handler = { request in paths.append(request.url!.path); return (401, [:]) }
        do {
            _ = try await adapter.rawItem(item)
            XCTFail("Rejected credentials must fail without another route or provider")
        } catch JellyfinError.signInRequired { }
        XCTAssertEqual(paths.count, 1)
    }

    func testHomeUsesJellyfinRowsAndArrayLatestResponse() async throws {
        let adapter = adapter { request in
            switch request.url!.path {
            case "/jellyfin/UserViews":
                return (200, ["Items":[["Id":"library1","Name":"Films","CollectionType":"movies"]]])
            case "/jellyfin/UserItems/Resume", "/jellyfin/Shows/NextUp":
                return (200, ["Items":[],"TotalRecordCount":0])
            case "/jellyfin/Users/" + self.user:
                return (200, ["Configuration":["LatestItemsExcludes":[]]])
            case "/jellyfin/Items/Latest":
                return (200, [["Id":self.item,"Name":"Example","Type":"Movie"]])
            default:
                XCTFail("Unexpected home endpoint: \(request.url!.path)")
                return (500, [:])
            }
        }
        let result = try await adapter.home()
        let rows = try XCTUnwrap(result["sections"] as? [[String:Any]])
        XCTAssertEqual(rows.compactMap { $0["sectionType"] as? String }, ["continue_watching","next_up","latestmedia_library1"])
        XCTAssertEqual((rows.last?["items"] as? [[String:Any]])?.first?["contentId"] as? String, item)
    }

    func testFiltersAndDownloadCapabilitiesAvoidEmbyServices() async throws {
        let adapter = adapter { request in
            switch request.url!.path {
            case "/jellyfin/Items/Filters": return (200, ["Genres":["Drama"],"OfficialRatings":["PG"]])
            case "/jellyfin/Users/" + self.user: return (200, ["Policy":["EnableContentDownloading":true]])
            default: XCTFail("Unexpected endpoint"); return (500, [:])
            }
        }
        let filters = try await adapter.route(method:"GET",path:"/api/v1/catalog/filters",query:[:],body:nil) as? [String:Any]
        XCTAssertEqual(filters?["genres"] as? [String], ["Drama"])
        let capability = try await adapter.route(method:"GET",path:"/api/v1/downloads/capability",query:[:],body:nil) as? [String:Any]
        XCTAssertEqual(capability?["qualityPresets"] as? [String], ["original"])
        XCTAssertEqual(capability?["transcodeEnabled"] as? Bool, false)
    }

    @MainActor
    func testPlaybackNegotiationReportingAndPreviewRetirement() async throws {
        var requests: [URLRequest] = []
        let media: [String:Any] = ["Id":source,"Container":"mkv","RunTimeTicks":6_000_000_000,
            "SupportsDirectPlay":true,"SupportsTranscoding":false,
            "MediaStreams":[["Type":"Video","Index":0,"Codec":"h264"],["Type":"Audio","Index":2,"Codec":"aac"]]]
        let adapter = adapter { request in
            requests.append(request)
            if request.url!.path.hasSuffix("/PlaybackInfo") {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(body["AutoOpenLiveStream"] as? Bool, false, "Negotiation must not allocate an open stream")
                XCTAssertEqual(body["UserId"] as? String, self.user)
                XCTAssertEqual(body["MediaSourceId"] as? String, self.source)
                XCTAssertEqual(body["AudioStreamIndex"] as? Int, 2)
                return (200, ["MediaSources":[media],"PlaySessionId":"play-session"])
            }
            return (200, [:])
        }
        let raw: [String:Any] = ["Id":item,"Name":"Example","Type":"Movie","MediaSources":[media]]
        let detail: WatchDetail = try JellyfinAdapter.decode(adapter.watch(raw, preferences:[:]))
        let metadata = JellyfinPlayback.Metadata(connection:adapter.connection,raw:raw,detail:detail)
        let (prepared, playback) = try await JellyfinPlayback.prepare(metadata:metadata,detail:detail,
            version:XCTUnwrap(detail.versions.first),start:10,audioOrdinal:0,subtitleIndex:nil,bitrateKbps:nil,quality:nil)
        XCTAssertEqual(prepared.session.playMethod, "DirectPlay")
        XCTAssertEqual(playback.stream.url.path, "/jellyfin/Videos/" + item + "/stream")
        try await playback.ping()
        try await playback.stopWithoutProgress()
        XCTAssertEqual(requests.suffix(2).map { $0.url!.path }, ["/jellyfin/Sessions/Playing/Ping","/jellyfin/Sessions/Playing/Stopped"])
        let stop = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String:Any])
        XCTAssertEqual(stop["Failed"] as? Bool, true)
        XCTAssertNil(stop["PositionTicks"])

        let reporting = JellyfinPlayback(connection:adapter.connection,itemID:item,sourceID:source,playSessionID:"reporting",
            stream:playback.stream,method:"DirectPlay",audioIndex:2,subtitleIndex:nil,position:0)
        try await reporting.report(position:65,isPaused:false)
        try await reporting.report(position:70,isPaused:true,stopping:true)
        XCTAssertEqual(requests.suffix(3).map { $0.url!.path }, ["/jellyfin/Sessions/Playing","/jellyfin/Sessions/Playing/Progress","/jellyfin/Sessions/Playing/Stopped"])
        let final = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String:Any])
        XCTAssertEqual(final["PositionTicks"] as? Int64, 700_000_000)
    }
}

private final class JellyfinRequestStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer,maxLength:buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    data.append(contentsOf:buffer.prefix(count))
                }
                request.httpBody = data
            }
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}
