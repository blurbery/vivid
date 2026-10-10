import XCTest
@testable import Vivid

final class JellyfinAdapterTests: XCTestCase {
    private var session: URLSession?
    private let user = "11111111111111111111111111111111"
    private let item = "22222222222222222222222222222222"
    private let source = "33333333333333333333333333333333"
    private var transcodeAllowed = false

    override func tearDown() {
        session?.invalidateAndCancel()
        session = nil
        JellyfinRequestStub.handler = nil
        JellyfinLegacyRoutes.shared.reset()
        super.tearDown()
    }

    func testOlderServerRoutesAreRememberedOnlyAfterTheOlderRouteSucceeds() async throws {
        var paths: [String] = []
        let adapter = adapter { request in
            paths.append(request.url!.path)
            return request.url!.path == "/jellyfin/UserViews" ? (404, [:]) : (200, ["Items": []])
        }
        _ = try await adapter.connection.data("GET", "/UserViews")
        XCTAssertEqual(paths, ["/jellyfin/UserViews", "/jellyfin/Users/\(user)/Views"])
        paths.removeAll()
        _ = try await adapter.connection.data("GET", "/UserViews")
        XCTAssertEqual(paths, ["/jellyfin/Users/\(user)/Views"], "A known older server skips the missing route")
    }

    func testMissingItemDoesNotMarkTheServerAsOlder() async throws {
        let adapter = adapter { _ in (404, [:]) }
        do {
            _ = try await adapter.connection.data("GET", "/Items/" + item)
            XCTFail("A missing item must still fail")
        } catch {}
        XCTAssertFalse(JellyfinLegacyRoutes.shared.prefersLegacy(adapter.connection.serverURL))
    }

    func testRememberedOlderServerReturnsToCurrentRoutesAfterAnUpgrade() async throws {
        var paths: [String] = []
        let adapter = adapter { request in
            paths.append(request.url!.path)
            return request.url!.path.hasPrefix("/jellyfin/Users/") ? (404, [:]) : (200, ["Items": []])
        }
        JellyfinLegacyRoutes.shared.remember(adapter.connection.serverURL)
        _ = try await adapter.connection.data("GET", "/UserViews")
        XCTAssertEqual(paths, ["/jellyfin/Users/\(user)/Views", "/jellyfin/UserViews"])
        XCTAssertFalse(JellyfinLegacyRoutes.shared.prefersLegacy(adapter.connection.serverURL))
    }

    func testPeopleStoreMovesOlderPerPersonKeysIntoOneMap() throws {
        let suite = "jellyfin-people-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("native-one", forKey: "partition.person.101")
        defaults.set("native-two", forKey: "partition.person.202")
        defaults.set("other", forKey: "elsewhere.person.303")
        let store = JellyfinPeopleStore(defaults: defaults)
        XCTAssertEqual(store.nativeID(routeID: "101", partition: "partition"), "native-one")
        XCTAssertEqual(store.nativeID(routeID: "202", partition: "partition"), "native-two")
        XCTAssertNil(defaults.object(forKey: "partition.person.101"))
        XCTAssertNil(defaults.object(forKey: "partition.person.202"))
        XCTAssertEqual(defaults.string(forKey: "elsewhere.person.303"), "other", "Other partitions are untouched")
        XCTAssertEqual(defaults.dictionary(forKey: JellyfinPeopleStore.key("partition")) as? [String: String],
                       ["101": "native-one", "202": "native-two"])
        let reloaded = JellyfinPeopleStore(defaults: defaults)
        XCTAssertEqual(reloaded.nativeID(routeID: "101", partition: "partition"), "native-one")
    }

    func testPeopleStoreIsBoundedAndKeepsRecentPeople() throws {
        let suite = "jellyfin-people-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["1": "old-one", "2": "old-two"], forKey: JellyfinPeopleStore.key("p"))
        let store = JellyfinPeopleStore(defaults: defaults, limit: 3)
        for id in 3...5 { store.remember(routeID: String(id), nativeID: "new-\(id)", partition: "p") }
        XCTAssertNil(store.nativeID(routeID: "1", partition: "p"))
        XCTAssertNil(store.nativeID(routeID: "2", partition: "p"))
        for id in 3...5 { XCTAssertEqual(store.nativeID(routeID: String(id), partition: "p"), "new-\(id)") }
        store.save("p")
        XCTAssertEqual((defaults.dictionary(forKey: JellyfinPeopleStore.key("p")) ?? [:]).count, 3)
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
        UserDefaults.standard.removeObject(forKey: JellyfinPeopleStore.key("vivid.jellyfin." + adapter.connection.serverURL + "." + user))
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
                if query.first(where: { $0.name == "Fields" })?.value == "ChildCount" {
                    return (200, ["Items": [["Id": "season3", "Name": "Season 3", "Type": "Season", "IndexNumber": 3, "ChildCount": 50]]])
                }
                return (200, ["Items": [["Id": "season3", "Name": "Season 3", "Type": "Season", "IndexNumber": 3,
                    "RecursiveItemCount": 50, "UserData": ["Played": false, "UnplayedItemCount": 24]]]])
            }
            guard query.contains(where: { $0.name == "Season" }) else {
                XCTFail("A season without versions must not list the whole series")
                return (200, ["Items": []])
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

    /// Jellyfin 12.2 counts each version of an episode in a season's totals, so seasons
    /// whose episodes have several versions are recounted from the grouped episode rows.
    private func versionedSeasons(episodeStatus: Int = 200) -> JellyfinAdapter {
        func episode(_ season: Int, _ number: Int, versions: Int?, played: Bool = false, seasonID: String? = nil, virtual: Bool = false) -> [String: Any] {
            var row: [String: Any] = ["Id": "s\(season)e\(number)", "Name": "Episode \(number)", "Type": "Episode",
                "ParentIndexNumber": season, "IndexNumber": number, "LocationType": virtual ? "Virtual" : "FileSystem",
                "UserData": ["Played": played]]
            row["MediaSourceCount"] = versions
            row["SeasonId"] = seasonID
            return row
        }
        return adapter { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if request.url!.path.hasSuffix("/Seasons") {
                // Without RecursiveItemCount, Jellyfin reports ChildCount with versions grouped.
                if query.first(where: { $0.name == "Fields" })?.value == "ChildCount" {
                    return (200, ["Items": [("season1", 8), ("library-a-season2", 4), ("season3", 5)].map {
                        ["Id": $0.0, "Name": "Season", "Type": "Season", "ChildCount": $0.1] }])
                }
                return (200, ["Items": [
                    // 8 episodes with two versions each, 2 watched: every count is doubled.
                    ["Id": "season1", "Name": "Season 1", "Type": "Season", "IndexNumber": 1, "RecursiveItemCount": 16,
                     "ChildCount": 16, "UserData": ["Played": false, "UnplayedItemCount": 12]],
                    // Merged across libraries, and one episode has only one version: not a doubling.
                    ["Id": "library-a-season2", "Name": "Season 2", "Type": "Season", "IndexNumber": 2, "RecursiveItemCount": 7,
                     "ChildCount": 7, "UserData": ["Played": false, "UnplayedItemCount": 5]],
                    // No versions: the server's counts stay as they are.
                    ["Id": "season3", "Name": "Season 3", "Type": "Season", "IndexNumber": 3, "RecursiveItemCount": 5,
                     "ChildCount": 5, "UserData": ["Played": false, "UnplayedItemCount": 3]]
                ]])
            }
            XCTAssertNil(query.first { $0.name == "Season" }, "One request covers every season")
            XCTAssertEqual(query.first { $0.name == "EnableImages" }?.value, "false")
            guard episodeStatus == 200 else { return (episodeStatus, [:]) }
            return (200, ["Items":
                (1...8).map { episode(1, $0, versions: 2, played: $0 <= 2) } + [episode(1, 9, versions: nil, virtual: true)]
                + [2, 2, 2, 1].enumerated().map { episode(2, $0 + 1, versions: $1, played: $0 == 0, seasonID: "library-b-season2") }
                + (1...5).map { episode(3, $0, versions: nil, played: $0 == 1) }])
        }
    }

    func testSeasonCountsGroupVersionsOfEachEpisode() async throws {
        let raw = try await versionedSeasons().route(method: "GET", path: "/api/v1/catalog/series/show/seasons", query: [:], body: nil)
        let seasons = try JellyfinAdapter.decode(raw, as: SeasonsResponse.self).seasons
        XCTAssertEqual(seasons.map(\.episodeCount), [8, 4, 5])
        XCTAssertEqual(seasons.map { $0.userData?.watchedCount }, [2, 1, 2])
        XCTAssertEqual(seasons.map { $0.userData?.unplayedCount }, [6, 3, 3])
        XCTAssertEqual(seasons.map { $0.userData?.played }, [false, false, false])
    }

    func testSeasonCountsKeepServerValuesWhenEpisodeListFails() async throws {
        let raw = try await versionedSeasons(episodeStatus: 500).route(method: "GET", path: "/api/v1/catalog/series/show/seasons", query: [:], body: nil)
        let seasons = try JellyfinAdapter.decode(raw, as: SeasonsResponse.self).seasons
        XCTAssertEqual(seasons.map(\.episodeCount), [16, 7, 5])
        XCTAssertEqual(seasons.map { $0.userData?.watchedCount }, [4, 2, 2])
    }

    func testOnlySeasonsCountingVersionsListTheWholeSeries() {
        let seasons: [[String: Any]] = [["Id": "a", "RecursiveItemCount": 16], ["Id": "b", "RecursiveItemCount": 5]]
        XCTAssertTrue(JellyfinAdapter.countsVersions(seasons, grouped: [["Id": "a", "ChildCount": 8], ["Id": "b", "ChildCount": 5]]))
        XCTAssertFalse(JellyfinAdapter.countsVersions(seasons, grouped: [["Id": "a", "ChildCount": 16], ["Id": "b", "ChildCount": 5]]))
        XCTAssertFalse(JellyfinAdapter.countsVersions(seasons, grouped: []), "A failed check keeps the server's counts")
    }

    func testSeasonDetailCountsGroupVersionsOfEachEpisode() async throws {
        // A grouped ChildCount of 16 means no versions, so the season detail skips the episode list.
        for (groupedCount, expected) in [(8, 8), (16, 16)] {
            let adapter = adapter { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                if request.url!.path.hasSuffix("/Episodes") {
                    XCTAssertEqual(groupedCount, 8, "A season without versions must not list its episodes")
                    XCTAssertEqual(query.first { $0.name == "Season" }?.value, "2")
                    return (200, ["Items": (1...8).map { ["Id": "e\($0)", "Name": "Episode \($0)", "Type": "Episode", "ParentIndexNumber": 2,
                        "IndexNumber": $0, "MediaSourceCount": 2, "UserData": ["Played": true]] }])
                }
                if query.first(where: { $0.name == "Fields" })?.value == "ChildCount" {
                    return (200, ["Id": "season2", "Name": "Season 2", "Type": "Season", "ChildCount": groupedCount])
                }
                return (200, ["Id": "season2", "Name": "Season 2", "Type": "Season", "SeriesId": "show", "IndexNumber": 2,
                    "RecursiveItemCount": 16, "UserData": ["Played": true, "UnplayedItemCount": 0]])
            }
            let detail = try await adapter.route(method: "GET", path: "/api/v1/catalog/items/season2", query: [:], body: nil) as? [String: Any]
            XCTAssertEqual(detail?["episodeCount"] as? Int, expected)
            XCTAssertEqual((detail?["userData"] as? [String: Any])?["watchedCount"] as? Int, expected)
        }
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

    func testSearchAllScopeIncludesMoviesAndSeries() async throws {
        var types: [String] = []
        let adapter = adapter { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            types.append(query.first { $0.name == "IncludeItemTypes" }?.value ?? "")
            return (200, ["Items": [], "TotalRecordCount": 0])
        }
        let cases: [(String?, String)] = [("video", "Movie,Series"), (nil, "Movie,Series"), ("unknown", "Movie,Series"),
                                          ("movie", "Movie"), ("series", "Series"), ("episode", "Episode")]
        for (type, expected) in cases {
            var input = ["source": "query", "q": "night"]
            input["type"] = type
            _ = try await adapter.catalog(input)
            XCTAssertEqual(types, [expected], "type=\(type ?? "none")")
            types.removeAll()
        }
        _ = try await adapter.catalog(["source": "history", "type": "video"])
        XCTAssertEqual(types, ["Movie,Episode"], "History keeps its own item types")
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
            if ["/jellyfin/UserItems/Resume", "/jellyfin/Shows/NextUp", "/jellyfin/Items/Latest"].contains(request.url!.path) {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                let fields = Set((query.first { $0.name == "Fields" }?.value ?? "").split(separator: ",").map(String.init))
                XCTAssertFalse(fields.contains("People"))
                XCTAssertFalse(fields.contains("Chapters"))
                XCTAssertTrue(fields.contains("MediaSources"))
                XCTAssertTrue(fields.contains("MediaStreams"))
                XCTAssertEqual(query.first { $0.name == "EnableUserData" }?.value, "true")
            }
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
            case "/jellyfin/Users/" + self.user:
                return (200, ["Policy":["EnableContentDownloading":true,"EnableVideoPlaybackTranscoding":self.transcodeAllowed]])
            default: XCTFail("Unexpected endpoint"); return (500, [:])
            }
        }
        let filters = try await adapter.route(method:"GET",path:"/api/v1/catalog/filters",query:[:],body:nil) as? [String:Any]
        XCTAssertEqual(filters?["genres"] as? [String], ["Drama"])
        // Smaller qualities come from the playback transcoder, so they follow
        // the account's transcoding permission, for single items and batches.
        for allowed in [false, true] {
            transcodeAllowed = allowed
            let capability = try await adapter.route(method:"GET",path:"/api/v1/downloads/capability",query:[:],body:nil) as? [String:Any]
            XCTAssertEqual(capability?["qualityPresets"] as? [String], allowed ? DownloadFormat.allCases.map(\.rawValue) : ["original"])
            XCTAssertEqual(capability?["transcodeEnabled"] as? Bool, allowed)
            XCTAssertEqual(capability?["bulkQuality"] as? Bool, allowed)
            XCTAssertEqual(capability?["seasonDownload"] as? Bool, true)
            XCTAssertEqual(capability?["seriesMonitoring"] as? Bool, false)
        }
    }

    func testBatchDownloadsKeepOnlyPresentEpisodesWithAUsableSource() {
        let sources: [[String: Any]] = [["Id": source]]
        let items: [[String: Any]] = [
            ["Id": "episode-1", "Type": "Episode", "MediaSources": sources],
            ["Id": "episode-2", "Type": "Episode", "LocationType": "Virtual", "MediaSources": sources],
            ["Id": "episode-3", "Type": "Episode", "IsMissing": true, "MediaSources": sources],
            ["Id": "episode-4", "Type": "Episode"],
            ["Id": "episode-5", "Type": "Episode", "MediaSources": []],
            ["Id": "episode-6", "Type": "Episode", "MediaSources": [["Id": "../source"]]],
            ["Id": "season-1", "Type": "Season", "MediaSources": sources],
            ["Id": "episode-1", "Type": "Episode", "MediaSources": sources],
            ["Id": "episode-7", "Type": "Episode", "LocationType": "FileSystem", "IsMissing": false, "MediaSources": sources]
        ]
        XCTAssertEqual(JellyfinDownloads.downloadableEpisodes(items).compactMap { $0["Id"] as? String }, ["episode-1", "episode-7"])
    }

    func testBatchDownloadRejectsUnpermittedQualityAndFileChoicesBeforeListingEpisodes() async throws {
        let base: [String: Any] = ["content_id": item, "series": true, "batch_id": "batch-1"]
        for extra in [["quality": "2mbps"], ["file_id": 7], ["episode_id": item], ["season_number": "2"]] as [[String: Any]] {
            var paths: [String] = []
            let adapter = adapter { request in
                paths.append(request.url!.path)
                return (200, ["Policy": ["EnableContentDownloading": true, "EnableVideoPlaybackTranscoding": false]])
            }
            do {
                _ = try await adapter.route(method: "POST", path: "/api/v1/downloads", query: [:], body: base.merging(extra) { _, new in new })
                XCTFail("A smaller batch quality needs transcode permission, and batches choose each episode's file")
            } catch JellyfinError.unsupportedFeature { }
            XCTAssertEqual(paths, ["/jellyfin/Users/\(user)"], "No episode listing")
            session?.invalidateAndCancel()
        }
    }

    func testSeriesAndSeasonBatchesListPresentEpisodesInOneRequest() async throws {
        for season in [2, nil] as [Int?] {
            var listed: [[String: String]] = []
            let adapter = adapter { request in
                let url = try XCTUnwrap(request.url)
                if url.path == "/jellyfin/Users/" + self.user { return (200, ["Policy": ["EnableContentDownloading": true]]) }
                XCTAssertEqual(url.path, "/jellyfin/Shows/\(self.item)/Episodes")
                listed.append(Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }))
                return (200, ["Items": [["Id": self.item, "Type": "Episode", "IsMissing": true, "MediaSources": [["Id": self.source]]]]])
            }
            var body: [String: Any] = ["content_id": item, "series": true, "quality": "original", "batch_id": "batch-1"]
            body["season_number"] = season
            do {
                _ = try await adapter.route(method: "POST", path: "/api/v1/downloads", query: [:], body: body)
                XCTFail("Only missing episodes leaves nothing to download")
            } catch JellyfinDownloads.BatchError.noEpisodes { }
            XCTAssertEqual(listed.count, 1)
            let query = try XCTUnwrap(listed.first)
            XCTAssertEqual(query["Season"], season.map { String($0) })
            XCTAssertEqual(query["IsMissing"], "false")
            XCTAssertEqual(query["UserId"], user)
            XCTAssertEqual(query["EnableUserData"], "true")
            XCTAssertEqual(query["Fields"], JellyfinAdapter.fields)
            XCTAssertEqual(query["SortBy"], "ParentIndexNumber,IndexNumber")
            session?.invalidateAndCancel()
        }
        XCTAssertEqual(JellyfinDownloads.BatchError.noEpisodes.localizedDescription, "No downloadable episodes were found.")
        XCTAssertEqual(JellyfinDownloads.BatchError.alreadyDownloaded.localizedDescription, "All available episodes are already downloaded.")
    }

    func testBatchEpisodesCarryTheRequestBatchIDInServerOrder() throws {
        let adapter = adapter { _ in XCTFail("Building registrations makes no requests"); return (500, [:]) }
        let sources: [[String: Any]] = [["Id": source, "Size": 1234]]
        let items: [[String: Any]] = [
            ["Id": "episode-2", "Name": "Two", "Type": "Episode", "MediaSources": sources],
            ["Id": "episode-3", "Type": "Episode", "MediaSources": sources],
            ["Id": "episode-1", "Name": "One", "Type": "Episode", "MediaSources": sources]
        ]
        let body: [String: Any] = ["content_id": item, "series": true, "batch_id": "batch-1"]
        let built = try JellyfinDownloads.batchEpisodes(items, body: body, adapter: adapter)
        XCTAssertEqual(built.map { $0.itemID }, ["episode-2", "episode-1"], "An episode without a title can't be mapped and is skipped")
        XCTAssertEqual(Set(built.map { $0.id }).count, 2)
        for episode in built {
            XCTAssertTrue(episode.id.hasPrefix("jellyfin-"))
            XCTAssertEqual(episode.entry["itemID"] as? String, episode.itemID)
            let stored = try XCTUnwrap(episode.entry["row"] as? [String: Any])
            for row in [episode.row, stored] {
                XCTAssertEqual(row["id"] as? String, episode.id)
                XCTAssertEqual(row["contentId"] as? String, item, "Episode rows name their series")
                XCTAssertEqual(row["episodeId"] as? String, episode.itemID)
                XCTAssertEqual(row["batchId"] as? String, "batch-1")
                XCTAssertEqual(row["status"] as? String, "ready")
                XCTAssertEqual(row["quality"] as? String, "original")
            }
        }
    }

    func testBatchEpisodesStreamTheChosenQuality() throws {
        let adapter = adapter { _ in XCTFail("Building registrations makes no requests"); return (500, [:]) }
        let streams: [[String: Any]] = [
            ["Type": "Subtitle", "Index": 3, "Codec": "subrip", "Language": "eng", "IsExternal": false],
            ["Type": "Subtitle", "Index": 4, "Codec": "PGSSUB", "Language": "eng", "IsExternal": false]
        ]
        let sources: [[String: Any]] = [["Id": source, "Size": 1234, "RunTimeTicks": 36_000_000_000, "DefaultAudioStreamIndex": 2,
                                         "MediaStreams": streams]]
        let items: [[String: Any]] = [["Id": "episode-1", "Name": "One", "Type": "Episode", "MediaSources": sources]]
        let body: [String: Any] = ["content_id": item, "season_number": 1, "batch_id": "batch-1"]
        // An original file already carries its embedded subtitles; a transcode
        // leaves them out, so the text one is saved beside it (never the bitmap).
        let original = try XCTUnwrap(JellyfinDownloads.batchEpisodes(items, body: body, adapter: adapter).first)
        XCTAssertEqual(((original.entry["manifest"] as? [String: Any])?["subtitles"] as? [[String: Any]])?.count, 0)
        let built = try JellyfinDownloads.batchEpisodes(items, body: body, format: .fiveMbps, adapter: adapter)
        let subtitles = try XCTUnwrap((built.first?.entry["manifest"] as? [String: Any])?["subtitles"] as? [[String: Any]])
        XCTAssertEqual(subtitles.map { $0["index"] as? Int }, [3])
        XCTAssertEqual(subtitles.first?["external"] as? Bool, false)
        XCTAssertEqual(subtitles.first?["format"] as? String, "srt")
        let episode = try XCTUnwrap(built.first)
        XCTAssertEqual(StreamedTranscodeDownload.format(of: episode.entry), .fiveMbps)
        XCTAssertEqual(episode.entry["audioStreamIndex"] as? Int, 2)
        for row in [episode.row, try XCTUnwrap(episode.entry["row"] as? [String: Any])] {
            XCTAssertEqual(row["quality"] as? String, "5mbps")
            XCTAssertEqual(row["contentId"] as? String, item, "Episode rows still name their series")
            XCTAssertEqual(row["batchId"] as? String, "batch-1")
            XCTAssertEqual(row["fileSize"] as? Int64, StreamedTranscodeDownload.estimatedBytes(format: .fiveMbps, durationSeconds: 3600))
        }
        XCTAssertEqual((episode.entry["manifest"] as? [String: Any])?["container"] as? String, "mp4")
    }

    func testBatchRetriesUnfinishedStoredEpisodesAndSkipsTheRest() {
        func built(_ itemID: String) -> JellyfinDownloads.BatchEpisode {
            let row: [String: Any] = ["id": "new-" + itemID, "episodeId": itemID, "status": "ready", "batchId": "batch-2"]
            let entry: [String: Any] = ["itemID": itemID, "row": row]
            return (itemID: itemID, id: "new-" + itemID, entry: entry, row: row)
        }
        func entry(_ id: String, _ itemID: String, _ status: String, deletionPending: Bool = false) -> [String: Any] {
            let row: [String: Any] = ["id": id, "episodeId": itemID, "status": status, "batchId": "batch-1"]
            return ["itemID": itemID, "deletionPending": deletionPending, "row": row]
        }
        let stored: [String: [String: Any]] = [
            "old-2": entry("old-2", "episode-2", "ready"),
            "old-3": entry("old-3", "episode-3", "downloading"),
            "old-4": entry("old-4", "episode-4", "ready", deletionPending: true),
            "old-5": entry("old-5", "episode-5", "completed"),
            "old-6a": entry("old-6a", "episode-6", "completed"),
            "old-6b": entry("old-6b", "episode-6", "downloading"),
            "old-6c": entry("old-6c", "episode-6", "ready")
        ]
        let result = JellyfinDownloads.batchResult(built: (1...6).map { built("episode-\($0)") }, stored: stored)
        XCTAssertEqual(result.fresh.map { $0.id }, ["new-episode-1", "new-episode-4"], "A copy awaiting deletion doesn't count")
        XCTAssertEqual(result.fresh.map { $0.entry["itemID"] as? String }, ["episode-1", "episode-4"])
        XCTAssertEqual(result.rows.compactMap { $0["id"] as? String }, ["new-episode-1", "old-2", "old-3", "new-episode-4", "old-6b"],
                       "One row per episode in built order, reusing unfinished stored copies and skipping completed ones")
        XCTAssertEqual(result.rows.compactMap { $0["status"] as? String }, Array(repeating: "ready", count: 5))
        XCTAssertEqual(result.rows.compactMap { $0["batchId"] as? String }, ["batch-2", "batch-1", "batch-1", "batch-2", "batch-1"])
        let skipped = JellyfinDownloads.batchResult(built: [built("episode-5")], stored: stored)
        XCTAssertTrue(skipped.fresh.isEmpty)
        XCTAssertTrue(skipped.rows.isEmpty, "Nothing to return, so the request fails as already downloaded")
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
            // A request still in flight after its test's tearDown cleared the
            // handler fails on its own instead of asserting into the next test.
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}
