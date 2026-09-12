import XCTest
@testable import Vivid

final class EmbyAdapterTests: XCTestCase {
    private var testSession: URLSession?

    override func tearDown() {
        testSession?.invalidateAndCancel()
        testSession = nil
        EmbyReviewRequestStub.handler = nil
        super.tearDown()
    }

    private func stubbedAdapter(_ handler: @escaping (URLRequest) throws -> (Int, Any)) -> EmbyAdapter {
        EmbyReviewRequestStub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbyReviewRequestStub.self]
        let session = URLSession(configuration: config)
        testSession = session
        return EmbyAdapter(connection: EmbyConnection(
            serverURL: "https://media.example.test", token: nil, userID: "user-1", identity: nil,
            sessionOverride: session
        ))
    }

    func testDownloadConversionRequiresDownloadAndSyncPermissions() async throws {
        for (downloads, conversion) in [(false, false), (false, true), (true, false)] {
            let adapter = stubbedAdapter { request in
                XCTAssertEqual(request.url?.path, "/emby/Users/user-1")
                return (200, ["Policy": ["EnableContentDownloading": downloads, "EnableSyncTranscoding": conversion,
                    "EnableVideoPlaybackTranscoding": true]])
            }
            let raw = try await adapter.route(method: "GET", path: "/api/v1/downloads/capability", query: [:], body: nil)
            let capability: DownloadCapability = try EmbyAdapter.decode(raw)
            XCTAssertEqual(capability.downloadAllowed, downloads)
            XCTAssertEqual(capability.qualityPresets, ["original"])
            XCTAssertFalse(capability.transcodeEnabled)
            testSession?.invalidateAndCancel()
        }
    }

    func testUnavailableEmbyConversionPreservesOriginalDownloads() async throws {
        for failure in [500, 404] {
            let adapter = stubbedAdapter { request in
                if request.url?.path == "/emby/Users/user-1" {
                    return (200, ["Policy": ["EnableContentDownloading": true, "EnableSyncTranscoding": true]])
                }
                return (failure, [:])
            }
            let raw = try await adapter.route(method: "GET", path: "/api/v1/downloads/capability", query: [:], body: nil)
            let capability: DownloadCapability = try EmbyAdapter.decode(raw)
            XCTAssertTrue(capability.isUsable)
            XCTAssertEqual(capability.qualityPresets, ["original"])
            XCTAssertFalse(capability.transcodeEnabled)
            testSession?.invalidateAndCancel()
        }
    }

    func testDownloadConversionNegotiatesOnlyThisDeviceAndAccount() async throws {
        var paths: [String] = []
        let adapter = stubbedAdapter { request in
            let url = try XCTUnwrap(request.url)
            paths.append(url.path)
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            switch url.path {
            case "/emby/Sessions":
                XCTAssertEqual(query["DeviceId"], EmbyConnection.deviceID)
                return (200, [
                    ["Id": "other-account", "DeviceId": EmbyConnection.deviceID, "UserId": "user-2"],
                    ["Id": "other-device", "DeviceId": "not-this-device", "UserId": "user-1"],
                    ["Id": "current-session", "DeviceId": EmbyConnection.deviceID, "UserId": "user-1"]
                ])
            case "/emby/Sessions/Capabilities/Full":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(query["Id"], "current-session")
                return (200, [:])
            case "/emby/Sync/Options":
                XCTAssertEqual(query["UserId"], "user-1")
                XCTAssertEqual(query["TargetId"], EmbyConnection.deviceID)
                return (200, [
                    "ProfileOptions": [["Id": "original", "EnableQualityOptions": false], ["Id": "mobile", "EnableQualityOptions": true]],
                    "QualityOptions": [["Id": "original", "IsOriginalQuality": true], ["Id": "high", "IsDefault": true, "IsOriginalQuality": false]]
                ])
            default: throw URLError(.badURL)
            }
        }
        let options = try await EmbyDownloadConversion.availableOptions(connection: adapter.connection)
        XCTAssertEqual(options.profile, "mobile")
        XCTAssertEqual(options.quality, "high")
        XCTAssertEqual(paths, ["/emby/Sessions", "/emby/Sessions/Capabilities/Full", "/emby/Sync/Options"])
        let body = try EmbyDownloadConversion.request(itemID: "movie-1", userID: "user-1", format: .twoMbps, options: options)
        XCTAssertEqual(body["Bitrate"] as? Int, 2_000_000)
        XCTAssertEqual(body["ItemIds"] as? [String], ["movie-1"])
        XCTAssertEqual(body["TargetId"] as? String, EmbyConnection.deviceID)
        XCTAssertEqual(body["Profile"] as? String, "mobile")
        XCTAssertEqual(body["Container"] as? String, "mp4")
        XCTAssertEqual(body["VideoCodec"] as? String, "h264")
        XCTAssertEqual(body["SyncNewContent"] as? Bool, false)
        XCTAssertThrowsError(try EmbyDownloadConversion.request(itemID: "movie-1", userID: "user-1", format: .original, options: options))
    }

    func testConversionDoesNotRegisterAnotherAccountsSession() async throws {
        let adapter = stubbedAdapter { request in
            XCTAssertEqual(request.url?.path, "/emby/Sessions")
            return (200, [["Id": "other-account", "DeviceId": EmbyConnection.deviceID, "UserId": "user-2"]])
        }
        do {
            _ = try await EmbyDownloadConversion.availableOptions(connection: adapter.connection)
            XCTFail("A different account's session must never be changed")
        } catch EmbyError.unsupportedFeature { }
    }

    func testConversionCreationRejectsMismatchedJobsAndTargets() throws {
        let valid: [String: Any] = ["Job": ["Id": 12], "JobItems": [["Id": 34, "JobId": 12, "TargetId": EmbyConnection.deviceID]]]
        let result = try EmbyDownloadConversion.creation(valid)
        XCTAssertEqual(result.jobID, "12")
        XCTAssertEqual(result.itemID, "34")
        for item in [["Id": 34, "JobId": 99, "TargetId": EmbyConnection.deviceID],
                     ["Id": 34, "JobId": 12, "TargetId": "other-device"]] as [[String: Any]] {
            XCTAssertThrowsError(try EmbyDownloadConversion.creation(["Job": ["Id": 12], "JobItems": [item]]))
        }
        for value: Any in [true, 1.5, -1, "../wrong", ""] {
            XCTAssertThrowsError(try EmbyDownloadConversion.identifier(value))
        }
    }

    func testConversionRequiresCompleteMetadataBeforeDownloadStarts() throws {
        for status in ["Queued", "Converting"] {
            XCTAssertEqual(try EmbyDownloadConversion.status(of: ["Status": status]), "preparing")
            XCTAssertThrowsError(try EmbyDownloadConversion.readySource(from: ["Status": status], sourceID: "source-1"))
        }
        XCTAssertEqual(try EmbyDownloadConversion.status(of: ["Status": "Failed"]), "failed")
        XCTAssertThrowsError(try EmbyDownloadConversion.status(of: ["Status": "Unknown"]))
        XCTAssertThrowsError(try EmbyDownloadConversion.readySource(from: ["Status": "ReadyToTransfer"], sourceID: "source-1"))
        let source = try EmbyDownloadConversion.readySource(from: ["Status": "ReadyToTransfer", "MediaSource": ["Container": "mp4", "Size": 1234]], sourceID: "source-1")
        XCTAssertEqual(source["Container"] as? String, "mp4")
        XCTAssertEqual(source["Id"] as? String, "source-1")
        XCTAssertEqual(source["Size"] as? Int, 1234)
    }

    func testFilterRoutePagesBothEndpointsAndPreservesLibraryScope() async throws {
        let adapter = stubbedAdapter { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/Views") { return (200, ["Items": [["Id": "12"]]]) }
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["ParentId"], "12")
            XCTAssertEqual(query["UserId"], "user-1")
            XCTAssertEqual(query["Limit"], "1000")
            XCTAssertEqual(query["Recursive"], "true")
            let start = try XCTUnwrap(Int(query["StartIndex"]!))
            XCTAssertLessThan(start, 2)
            let names = url.path.hasSuffix("/Genres") ? ["Action", "Drama"] : ["PG", "R"]
            return (200, ["Items": [["Name": names[min(start, 1)]]], "TotalRecordCount": 2])
        }
        let result = try await adapter.route(method: "GET", path: "/api/v1/catalog/filters", query: ["library_id": "12"], body: nil)
        let filters: CatalogFilters = try EmbyAdapter.decode(result)
        XCTAssertEqual(filters.genres, ["Action", "Drama"])
        XCTAssertEqual(filters.contentRatings, ["PG", "R"])
    }

    func testFilterRouteMapsHTTPFailuresAtEachStep() async throws {
        for (suffix, step) in [("/Views", "Library lookup"), ("/Genres", "Genres"), ("/OfficialRatings", "Ratings")] {
            let adapter = stubbedAdapter { request in
                if request.url!.path.hasSuffix(suffix) { return (503, [:]) }
                if request.url!.path.hasSuffix("/Views") { return (200, ["Items": [["Id": "12"]]]) }
                return (200, ["Items": [], "TotalRecordCount": 0])
            }
            do {
                _ = try await adapter.route(method: "GET", path: "/api/v1/catalog/filters", query: ["library_id": "12"], body: nil)
                XCTFail("Expected a filter request failure")
            } catch EmbyError.filterRequestFailed(let actualStep, let status) {
                XCTAssertEqual(actualStep, step)
                XCTAssertEqual(status, 503)
            }
            testSession?.invalidateAndCancel()
        }
    }

    func testFilterRouteRejectsMissingItems() async throws {
        let adapter = stubbedAdapter { _ in (200, ["TotalRecordCount": 1]) }
        do {
            _ = try await adapter.route(method: "GET", path: "/api/v1/catalog/filters", query: [:], body: nil)
            XCTFail("Expected an invalid response")
        } catch EmbyError.invalidResponse {}
    }

    func testFilterRouteStopsEmptyPageDespiteInflatedTotal() async throws {
        let adapter = stubbedAdapter { _ in (200, ["Items": [], "TotalRecordCount": Int.max]) }
        let raw = try await adapter.route(method: "GET", path: "/api/v1/catalog/filters", query: [:], body: nil)
        let filters: CatalogFilters = try EmbyAdapter.decode(raw)
        XCTAssertTrue(filters.genres.isEmpty)
        XCTAssertTrue(filters.contentRatings.isEmpty)
    }

    func testFilterRouteBoundsRowsAndShortPages() async throws {
        for (pageSize, expectedRequests) in [(1000, 10), (1, 100), (10_001, 1)] {
            var requests = 0
            let adapter = stubbedAdapter { _ in
                requests += 1
                guard requests <= expectedRequests else { throw URLError(.badServerResponse) }
                return (200, ["Items": Array(repeating: ["Name": "Drama"], count: pageSize), "TotalRecordCount": Int.max])
            }
            do {
                _ = try await adapter.route(method: "GET", path: "/api/v1/catalog/filters", query: [:], body: nil)
                XCTFail("Expected the paging bound to reject the response")
            } catch EmbyError.invalidResponse {}
            XCTAssertEqual(requests, expectedRequests)
            testSession?.invalidateAndCancel()
        }
    }

    func testFilterRouteAcceptsExactlyTenThousandRows() async throws {
        let adapter = stubbedAdapter { request in
            if request.url!.path.hasSuffix("/OfficialRatings") { return (200, ["Items": []]) }
            return (200, ["Items": Array(repeating: ["Name": "Drama"], count: 1000), "TotalRecordCount": 10_000])
        }
        let raw = try await adapter.route(method: "GET", path: "/api/v1/catalog/filters", query: [:], body: nil)
        let filters: CatalogFilters = try EmbyAdapter.decode(raw)
        XCTAssertEqual(filters.genres, ["Drama"])
    }

    func testSupplementalNextUpPreservesLoadedSectionsOnHTTPNetworkAndMalformedResponse() async throws {
        let sections: [[String: Any]] = [["id": "resume", "sectionType": "continue_watching", "items": []]]
        for failure in 0..<3 {
            let adapter = stubbedAdapter { _ in
                if failure == 0 { throw URLError(.notConnectedToInternet) }
                if failure == 1 { return (200, []) }
                return (503, [:])
            }
            let result = try await adapter.supplyingCombinedNextUp(sections, enabled: true)
            XCTAssertTrue(NSArray(array: result).isEqual(to: sections))
            testSession?.invalidateAndCancel()
        }
    }

    func testSupplementalNextUpPreservesCancellationAndSignInFailure() async throws {
        for cancelled in [false, true] {
            let adapter = stubbedAdapter { _ in
                if cancelled { throw URLError(.cancelled) }
                return (401, [:])
            }
            do {
                _ = try await adapter.supplyingCombinedNextUp([], enabled: true)
                XCTFail("Expected cancellation or sign-in failure")
            } catch EmbyError.signInRequired {
                XCTAssertFalse(cancelled)
            } catch let error as URLError {
                XCTAssertTrue(cancelled)
                XCTAssertEqual(error.code, .cancelled)
            }
            testSession?.invalidateAndCancel()
        }
    }

    func testSupplementalNextUpOnlyLoadsWhenNeeded() async throws {
        var requests = 0
        let adapter = stubbedAdapter { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/emby/Shows/NextUp")
            return (200, ["Items": [], "TotalRecordCount": 0])
        }
        let existing: [[String: Any]] = [["id": "next", "sectionType": "next_up"]]
        let disabled = try await adapter.supplyingCombinedNextUp([], enabled: false)
        let unchanged = try await adapter.supplyingCombinedNextUp(existing, enabled: true)
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertTrue(NSArray(array: unchanged).isEqual(to: existing))
        XCTAssertEqual(requests, 0)
        let loaded = try await adapter.supplyingCombinedNextUp([], enabled: true)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(loaded.last?["sectionType"] as? String, "next_up")
    }


    private var adapter: EmbyAdapter {
        EmbyAdapter(connection:EmbyConnection(serverURL:"https://media.example.test",token:nil,userID:"user-1",identity:nil))
    }

    func testFilterOptionsDecodeNamesAndStringValues() throws {
        let raw: [String: Any] = [
            "Genres": ["Drama", ["Name": "Action"], "Drama"],
            "OfficialRatings": [["Name": "PG"], "R"]
        ]
        let filters: CatalogFilters = try EmbyAdapter.decode(EmbyAdapter.catalogFilterOptions(raw))
        XCTAssertEqual(filters.genres, ["Action", "Drama"])
        XCTAssertEqual(filters.contentRatings, ["PG", "R"])
        let empty: CatalogFilters = try EmbyAdapter.decode(EmbyAdapter.catalogFilterOptions([:]))
        XCTAssertTrue(empty.genres.isEmpty)
    }

    func testServerAddressPreservesProxyPrefixAndAvoidsDuplicateAPIPrefix() throws {
        XCTAssertEqual(try EmbyConnection.url(serverURL:"https://media.example.test:443/proxy",path:"/Users/AuthenticateByName").absoluteString,
                       "https://media.example.test:443/proxy/emby/Users/AuthenticateByName")
        XCTAssertEqual(try EmbyConnection.url(serverURL:"https://media.example.test/emby/",path:"/System/Info/Public").path,"/emby/System/Info/Public")
        XCTAssertEqual(try EmbyConnection.url(serverURL:"https://media.example.test",path:"/Items",query:["SearchTerm":"a&b #c"]).query,"SearchTerm=a%26b%20%23c")
    }

    func testRejectsCredentialURLsAndPathInjection() {
        for base in ["file:///tmp/server", "https://user:password@media.example.test", "https://media.example.test?api_key=secret"] {
            XCTAssertThrowsError(try EmbyConnection.url(serverURL:base,path:"/Items"))
        }
        for path in ["//other.example.test/Items", "/../Users", "https://other.example.test/Items"] {
            XCTAssertThrowsError(try EmbyConnection.url(serverURL:"https://media.example.test",path:path))
        }
        for id in ["", "../1", "1?token=x", "1/2", "%2f"] { XCTAssertThrowsError(try EmbyConnection.id(id)) }
    }

    func testProviderNamespacesKeepExistingServerIdentity() {
        XCTAssertEqual(MediaServerProvider.forServerID("existing-id"),.silo)
        XCTAssertEqual(MediaServerProvider.forServerID("emby:existing-id"),.emby)
        XCTAssertEqual(EmbyAdapter.numberID("12345"),12345)
        XCTAssertEqual(EmbyAdapter.numberID("source-a"),EmbyAdapter.numberID("source-a"))
        XCTAssertNotEqual(EmbyAdapter.numberID("source-a"),EmbyAdapter.numberID("source-b"))
    }

    func testRuntimeRejectsOutOfRangeJSONNumbersWithoutTrapping() throws {
        for value in ["1e100", "1e308", "5.5340232221128655e27"] {
            let json = Data("{\"Id\":\"1\",\"Name\":\"Movie\",\"Type\":\"Movie\",\"RunTimeTicks\":\(value)}".utf8)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            XCTAssertThrowsError(try adapter.item(raw)) { error in
                guard case EmbyError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testRuntimePreservesOrdinaryFractionalMissingAndLargeIntegerTicks() throws {
        for (ticks, minutes) in [(0.0, 0), (-100.0, 0), (899_000_000.0, 1), (Double(Int64.max), 15_372_286_728)] {
            let mapped = try adapter.item(["Id": "1", "Name": "Movie", "Type": "Movie", "RunTimeTicks": ticks])
            XCTAssertEqual(mapped["runtime"] as? Int, minutes)
        }
        let missing = try adapter.item(["Id": "1", "Name": "Movie", "Type": "Movie"])
        XCTAssertEqual(missing["runtime"] as? Int, 0)
    }

    func testEpisodeMappingDecodesExistingScreensAndConvertsTicks() throws {
        let raw: [String:Any] = ["Id":"123", "Name":"Episode", "Type":"Episode", "SeriesId":"456", "SeriesName":"Series",
            "ParentIndexNumber":2,"IndexNumber":3,"RunTimeTicks":36_000_000_000 as Int64,
            "UserData":["PlaybackPositionTicks":900_000_000,"Played":false,"IsFavorite":true],
            "ImageTags":["Primary":"tag-a"],"MediaSources":[["Id":"source-a","Container":"mkv","RunTimeTicks":36_000_000_000 as Int64,
                "MediaStreams":[["Type":"Video","Index":0,"Codec":"hevc","Height":2160],
                                ["Type":"Audio","Index":2,"Codec":"aac","Language":"eng"],
                                ["Type":"Audio","Index":4,"Codec":"flac","Language":"eng"],
                                ["Type":"Subtitle","Index":6,"Codec":"srt","IsExternal":true]]]]]
        let mapped = try adapter.item(raw)
        let browse: BrowseItem = try EmbyAdapter.decode(mapped)
        let section: SectionItem = try EmbyAdapter.decode(mapped)
        let detail: ItemDetail = try EmbyAdapter.decode(mapped)
        let watch: WatchDetail = try EmbyAdapter.decode(mapped)
        let episode: EpisodeListItem = try EmbyAdapter.decode(mapped)
        XCTAssertEqual(browse.runtime,60)
        XCTAssertEqual(section.positionSeconds,90)
        XCTAssertEqual(detail.seriesId,"456")
        XCTAssertEqual(episode.episodeNumber,3)
        XCTAssertEqual(watch.versions[0].audioTracks?.compactMap(\.index),[0,1])
        XCTAssertEqual(watch.versions[0].subtitleTracks?.first?.index,6)
        XCTAssertEqual(watch.versions[0].duration,3600)
        XCTAssertTrue(browse.userState?.isFavorite == true)
        XCTAssertFalse(browse.posterUrl?.contains("api_key") == true)
    }

    func testMinimalMovieAndSeasonHaveRequiredFields() throws {
        let movie = try adapter.item(["Id":"1","Name":"Movie","Type":"Movie"])
        let watch: WatchDetail = try EmbyAdapter.decode(movie)
        XCTAssertEqual(watch.versions.count,0)
        let season: Season = try EmbyAdapter.decode(adapter.item(["Id":"2","Name":"Specials","Type":"Season","IndexNumber":0,"RecursiveItemCount":4]))
        XCTAssertEqual(season.seasonNumber,0)
        XCTAssertEqual(season.episodeCount,4)
    }

    func testProgressTicksAreBounded() {
        XCTAssertEqual(EmbyPlayback.ticks(90.25),902_500_000)
        XCTAssertEqual(EmbyPlayback.ticks(-1),0)
        XCTAssertEqual(EmbyPlayback.ticks(.nan),0)
        XCTAssertEqual(EmbyPlayback.ticks(.infinity),0)
        XCTAssertEqual(EmbyPlayback.ticks(.greatestFiniteMagnitude),Int64.max)
    }

    func testUnsupportedServerFeatureDoesNotSendSiloRequest() async throws {
        do {
            _ = try await adapter.route(method:"POST",path:"/api/v1/playback/start",query:[:],body:[:])
            XCTFail("A Silo playback route must not reach Emby")
        } catch EmbyError.unsupportedFeature { }
    }
    func testSubtitleSettingsReachWatchAndSeriesOverridesWin() throws {
        let raw: [String:Any] = ["Id":"1","Name":"Movie","Type":"Movie"]
        let prefs: [String:Any] = ["playback.subtitle_language":"eng","playback.subtitle_mode":"always","playback.show_forced_subtitles":true]
        let watch: WatchDetail = try EmbyAdapter.decode(adapter.watch(raw,preferences:prefs))
        XCTAssertEqual(watch.effectiveSubtitleLanguage,"eng")
        XCTAssertEqual(watch.effectiveSubtitleMode,"always")
        XCTAssertEqual(watch.effectiveShowForcedSubtitles,true)
        let overridden: WatchDetail = try EmbyAdapter.decode(adapter.watch(raw,preferences:prefs,subtitle:["subtitle_mode":"off","show_forced_subtitles":false]))
        XCTAssertEqual(overridden.effectiveSubtitleMode,"off")
        XCTAssertEqual(overridden.effectiveShowForcedSubtitles,false)
    }

    func testSubtitlePreferencesPersistAndDeviceOverridesCanBeRemoved() async throws {
        let suite = "Vivid.EmbyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "nav.shortcuts.profile": ["key": "nav.shortcuts", "value": ["items": []]]
        ]), forKey: "account-a")
        let store = EmbyLocalPreferences(defaults:defaults)
        let path = ["api","v1","settings","values","playback.subtitle_language"]
        _ = try await store.apply(storageKey:"account-a",user:"user",method:"PUT",path:path,query:["scope":"profile"],body:["value":"eng"])
        _ = try await store.apply(storageKey:"account-a",user:"user",method:"PUT",path:path,query:["scope":"profile_device"],body:["value":"fra"])
        let migrated = try XCTUnwrap(defaults.data(forKey: "account-a"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        XCTAssertNil(rows["nav.shortcuts.profile"])
        let reopened = EmbyLocalPreferences(defaults:defaults)
        func effective(_ account: String) async throws -> String? {
            let result = try await reopened.apply(storageKey:account,user:"user",method:"GET",path:["effective"],query:["keys":"playback.subtitle_language"],body:[:]) as? [String:Any]
            return (result?["settings"] as? [[String:Any]])?.first?["value"] as? String
        }
        let device = try await effective("account-a")
        XCTAssertEqual(device,"fra")
        let otherAccount = try await effective("account-b")
        XCTAssertNil(otherAccount)
        _ = try await reopened.apply(storageKey:"account-a",user:"user",method:"DELETE",path:path,query:["scope":"profile_device"],body:[:])
        let inherited = try await effective("account-a")
        XCTAssertEqual(inherited,"eng")
    }

    func testQualityAndHDRPreferencesConstrainEmbyNegotiation() {
        let source: [String:Any] = ["MediaStreams":[["Type":"Video","Height":2160,"VideoRange":"HDR10"]]]
        var limited: [String:Any] = ["EnableDirectPlay":true,"DeviceProfile":["TranscodingProfiles":[["Type":"Video"]]]]
        EmbyPlayback.applyPlaybackLimits(to:&limited,source:source,quality:"720p",hdr:true,dolbyVision:true)
        XCTAssertEqual(limited["EnableDirectPlay"] as? Bool,false)
        XCTAssertEqual(limited["AllowVideoStreamCopy"] as? Bool,false)
        let profile = limited["DeviceProfile"] as? [String:Any]
        XCTAssertEqual((profile?["TranscodingProfiles"] as? [[String:Any]])?.first?["MaxHeight"] as? Int,720)
        var sdr: [String:Any] = ["EnableDirectPlay":true]
        EmbyPlayback.applyPlaybackLimits(to:&sdr,source:source,quality:"auto",hdr:false,dolbyVision:true)
        XCTAssertEqual(sdr["EnableDirectPlay"] as? Bool,false)
        var original: [String:Any] = ["EnableDirectPlay":true]
        EmbyPlayback.applyPlaybackLimits(to:&original,source:source,quality:"original",hdr:true,dolbyVision:true)
        XCTAssertEqual(original["EnableDirectPlay"] as? Bool,true)
    }

    func testHomeSectionPreservesServerIdentityAndTitle() throws {
        let mapped = adapter.homeSection(["Id":"custom-row","Name":"My chosen row","SectionType":"Resume"],catalog:["items":[],"total":0])
        let row: ResolvedSection = try EmbyAdapter.decode(mapped)
        XCTAssertEqual(row.id,"custom-row")
        XCTAssertEqual(row.title,"My chosen row")
        XCTAssertEqual(row.sectionType,"continue_watching")
        XCTAssertTrue(row.items.isEmpty)
    }

    func testEmbyCollectionsBecomePosterCardsAndExcludeNavigationFolders() throws {
        XCTAssertNil(adapter.collection(["Id":"1","Name":"Movies","Type":"CollectionFolder"]))
        XCTAssertNil(adapter.collection(["Id":"2","Name":"Playlist","Type":"Playlist"]))
        let mapped = try XCTUnwrap(adapter.collection(["Id":"3","Name":"Film collection","Type":"BoxSet","ChildCount":4,"ImageTags":["Primary":"poster-tag"]]))
        let card: LibraryCollection = try EmbyAdapter.decode(mapped)
        XCTAssertEqual(card.id,"3")
        XCTAssertEqual(card.name,"Film collection")
        XCTAssertEqual(card.itemCount,4)
        XCTAssertEqual(card.kind,.regular)
        XCTAssertNotNil(card.posterUrl)
    }

    func testSeasonTabsExcludeEpisodeRecordsAndPreserveCounts() throws {
        let rows: [[String:Any]] = [
            ["Id":"season-4","Name":"Gone Tomorrow","Type":"Season","IndexNumber":4,"ChildCount":8],
            ["Id":"episode-1","Name":"Pilot","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1],
            ["Id":"season-0","Name":"Behind the Scenes","Type":"Season","IndexNumber":0,"ChildCount":2]]
        let response: SeasonsResponse = try EmbyAdapter.decode(["seasons":adapter.seasonRows(rows)])
        XCTAssertEqual(response.seasons.map(\.contentId),["season-4","season-0"])
        XCTAssertEqual(response.seasons.map(\.title),["Season 4","Specials"])
        XCTAssertEqual(response.seasons.map(\.episodeCount),[8,2])
        XCTAssertEqual(response.seasons.last?.isSpecials,true)
    }

    func testCroppedVersionsUseDisplayResolutionClass() throws {
        for (width,height,expected) in [(3840,1606,"2160p"),(1920,802,"1080p"),(1280,534,"720p"),(1920,1080,"1080p")] {
            let raw: [String:Any] = ["Id":"source","MediaStreams":[["Type":"Video","Width":width,"Height":height]]]
            let version: FileVersion = try EmbyAdapter.decode(adapter.version(raw))
            XCTAssertEqual(version.resolution,expected)
            XCTAssertEqual(version.videoTracks?.first?.height,height)
            XCTAssertEqual(version.videoTracks?.first?.width,width)
        }
    }

    func testHomeUsesLegacyEndpointsBefore41004() {
        XCTAssertFalse(EmbyAdapter.usesServerHomeSections(version:"4.9.5.0"))
        XCTAssertFalse(EmbyAdapter.usesServerHomeSections(version:"4.10.0.3"))
        XCTAssertTrue(EmbyAdapter.usesServerHomeSections(version:"4.10.0.4"))
        XCTAssertTrue(EmbyAdapter.usesServerHomeSections(version:"4.11.0.0"))
    }

    func testLegacyHomePreservesConfiguredOrderAndDisabledRows() {
        let settings: [String:Any] = ["homesection0":"collections","homesection1":"nextup","homesection2":"resume","homesection3":"none","homesection4":"none","homesection5":"none","homesection6":"none"]
        XCTAssertEqual(EmbyAdapter.legacyHomeSectionTypes(settings:settings),["collections","nextup","resume"])
    }

}

private final class EmbyReviewRequestStub: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (Int, Any))?
    static var handler: ((URLRequest) throws -> (Int, Any))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            let data = try JSONSerialization.data(withJSONObject: body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
