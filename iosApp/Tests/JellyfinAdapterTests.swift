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
            _ = try await preferences.apply(storageKey: "account-one", user: "one", method: "PUT",
                path: ["api", "v1", "settings", "values", key], query: ["scope": "profile_device"], body: ["value": value])
        }
        let reloaded = JellyfinLocalPreferences(defaults: defaults)
        func read(_ key: String) async throws -> [[String: Any]] {
            let result = try await reloaded.apply(storageKey: key, user: key, method: "GET",
                path: ["api", "v1", "settings", "values", "effective"],
                query: ["keys": "playback.subtitle_language,playback.subtitle_mode,playback.audio_language"], body: [:]) as! [String: Any]
            return result["settings"] as! [[String: Any]]
        }
        let first = try await read("account-one")
        XCTAssertEqual(first.map { $0["value"] as? String }, ["eng", "always", "fra"])
        let second = try await read("account-two")
        XCTAssertTrue(second[0]["value"] is NSNull)
        XCTAssertEqual(second[1]["value"] as? String, "auto")
        XCTAssertTrue(second[2]["value"] is NSNull)
    }

    func testQualityCapRequiresResizeForHigherResolutionSource() {
        var body: [String: Any] = ["EnableDirectPlay": true, "EnableDirectStream": true,
            "DeviceProfile": ["TranscodingProfiles": [["Type": "Video"]]]]
        JellyfinPlayback.applyPlaybackLimits(to: &body,
            source: ["MediaStreams": [["Type": "Video", "Height": 2160]]],
            quality: "1080p-high", hdr: true, dolbyVision: true)
        XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false)
        XCTAssertEqual(body["AllowVideoStreamCopy"] as? Bool, false)
        let profile = body["DeviceProfile"] as! [String: Any]
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

    func testLegacyJellyfinRetryOnlyForMissingRoute() async throws {
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
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String:Any]
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
        let stop = try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as! [String:Any]
        XCTAssertEqual(stop["Failed"] as? Bool, true)
        XCTAssertNil(stop["PositionTicks"])

        let reporting = JellyfinPlayback(connection:adapter.connection,itemID:item,sourceID:source,playSessionID:"reporting",
            stream:playback.stream,method:"DirectPlay",audioIndex:2,subtitleIndex:nil,position:0)
        try await reporting.report(position:65,isPaused:false)
        try await reporting.report(position:70,isPaused:true,stopping:true)
        XCTAssertEqual(requests.suffix(3).map { $0.url!.path }, ["/jellyfin/Sessions/Playing","/jellyfin/Sessions/Playing/Progress","/jellyfin/Sessions/Playing/Stopped"])
        let final = try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as! [String:Any]
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
