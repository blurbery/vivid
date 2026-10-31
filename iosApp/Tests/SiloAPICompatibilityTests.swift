import XCTest
@testable import Vivid

/// Code written for Silo's v1 API keeps working against a v2 server: requests
/// are rewritten on the way out and replies turned back into v1 shapes.
final class SiloAPICompatibilityTests: XCTestCase {
    private let base = "https://server.example/silo"

    private func request(_ path: String, method: String = "GET", body: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
        request.httpMethod = method
        if let body { request.httpBody = Data(body.utf8) }
        request.setValue("Bearer account", forHTTPHeaderField: "Authorization")
        request.setValue("profile", forHTTPHeaderField: "X-Profile-Id")
        return try SiloAPICompatibility.request(request)
    }

    private func response(_ json: String, path: String) throws -> [String: Any] {
        let data = try SiloAPICompatibility.response(Data(json.utf8), path: path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func queryItems(_ request: URLRequest) throws -> [URLQueryItem] {
        let url = try XCTUnwrap(request.url)
        return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    // MARK: - Artwork

    func testSignedRelativeArtworkURLsResolveToTheRespondingServer() throws {
        let item: [String: Any] = [
            "poster_url": "/api/v2/artwork/poster?exp=123&sig=a%2Fb%2Bc",
            "backdrop_url": "https://cdn.example/backdrop",
            "logo_url": "//cdn.example/logo",
            "stream_url": "/api/v2/playback/stream",
            "title": "/api/v2/artwork/not-a-url",
        ]
        let body = try JSONSerialization.data(withJSONObject: ["sections": [["items": [item]]]])
        let output = try SiloAPICompatibility.response(
            body, path: "/api/v1/home/sections",
            requestURL: URL(string: "https://server.example:8443/silo/api/v2/home/sections"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let section = try XCTUnwrap((document["sections"] as? [[String: Any]])?.first)
        let resolved = try XCTUnwrap((section["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(resolved["poster_url"] as? String,
                       "https://server.example:8443/api/v2/artwork/poster?exp=123&sig=a%2Fb%2Bc")
        for key in ["backdrop_url", "logo_url", "stream_url", "title"] {
            XCTAssertEqual(resolved[key] as? String, item[key] as? String, key)
        }
    }

    func testCachedRelativeArtworkCanLoadAfterHomeIsReopened() {
        let cached = "/api/v2/artwork/poster?exp=123&sig=a%2Fb%2Bc"
        let server = URL(string: "https://server.example:8443/silo")
        XCTAssertEqual(SiloAPICompatibility.artworkURL(cached, relativeTo: server)?.absoluteString,
                       "https://server.example:8443/api/v2/artwork/poster?exp=123&sig=a%2Fb%2Bc")
        XCTAssertNil(SiloAPICompatibility.artworkURL(cached, relativeTo: nil))
        XCTAssertEqual(SiloAPICompatibility.artworkURL("https://cdn.example/poster", relativeTo: server)?.absoluteString,
                       "https://cdn.example/poster")
    }

    // MARK: - Requests

    func testRenamedEndpointsAndMethodsPreserveBasePathAndAuth() throws {
        let routes = [
            ("/api/v1/auth/setup", "GET", "/api/v2/system/setup", "GET"),
            ("/api/v1/auth/setup", "POST", "/api/v2/auth/setup", "POST"),
            ("/api/v1/auth/me", "GET", "/api/v2/account/me", "GET"),
            ("/api/v1/people/42", "GET", "/api/v2/catalog/people/42", "GET"),
            ("/api/v1/profiles/p", "PUT", "/api/v2/profiles/p", "PATCH"),
            ("/api/v1/collections/c", "PUT", "/api/v2/collections/c", "PATCH"),
            ("/api/v1/collections/sort-preference", "PUT", "/api/v2/collections/sort-preference", "PUT"),
            ("/api/v1/playback/capability", "GET", "/api/v2/playback/capabilities", "GET"),
        ]
        for (oldPath, oldMethod, newPath, newMethod) in routes {
            let routed = try request(oldPath, method: oldMethod)
            XCTAssertEqual(routed.url?.path, "/silo" + newPath, oldPath)
            XCTAssertEqual(routed.httpMethod, newMethod, oldPath)
            XCTAssertEqual(routed.value(forHTTPHeaderField: "Authorization"), "Bearer account", oldPath)
            XCTAssertEqual(routed.value(forHTTPHeaderField: "X-Profile-Id"), "profile", oldPath)
        }
    }

    func testEscapedContentIdentifierAndOpaqueV2URLRemainIntact() throws {
        let routed = try request("/api/v1/catalog/items/movie%3Aone%2Ftwo")
        let url = try XCTUnwrap(routed.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                       "/silo/api/v2/catalog/items/movie%3Aone%2Ftwo")
        let opaque = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example/api/v2/stream/token?signature=opaque")))
        XCTAssertEqual(try SiloAPICompatibility.request(opaque), opaque)
    }

    func testCatalogueSortSeekAndGroupedFilters() throws {
        let routed = try request(
            "/api/v1/catalog?offset=60&limit=60&sort=year&order=desc&include_total=false&snapshot=window"
                + "&groups%5B0%5D%5Bmatch%5D=any&groups%5B0%5D%5Brules%5D%5B0%5D%5Bfield%5D=genre"
                + "&groups%5B0%5D%5Brules%5D%5B0%5D%5Bop%5D=contains&groups%5B0%5D%5Brules%5D%5B0%5D%5Bvalue%5D=Drama")
        let query = Dictionary(uniqueKeysWithValues: try queryItems(routed).map { ($0.name, $0.value!) })
        XCTAssertEqual(query["seek"], "60")
        XCTAssertEqual(query["cursor"], "window")
        XCTAssertEqual(query["sort"], "-year")
        XCTAssertEqual(query["skip_total"], "true")
        XCTAssertNil(query["offset"])
        XCTAssertNil(query["order"])
        let groups = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((query["groups"] ?? "").utf8)) as? [[String: Any]])
        XCTAssertEqual(groups.first?["match"] as? String, "any")
        XCTAssertEqual(((groups.first?["rules"] as? [[String: Any]])?.first)?["value"] as? String, "Drama")
    }

    func testBuiltFiltersReachV2WithTheTypesTheServerCompares() throws {
        var state = CatalogFilterState()
        state.genres = ["Horror"]
        state.contentRatings = ["15"]
        state.decades = [2010]
        state.dolbyVision = true
        state.watchStatus = .unwatched
        let parameters = CatalogQueryBuilder.build(
            state, libraryId: 7, mediaType: .movie, offset: 0, limit: 60, provider: .silo)
        var components = try XCTUnwrap(URLComponents(string: base + "/api/v1/catalog"))
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let routed = try SiloAPICompatibility.request(URLRequest(url: try XCTUnwrap(components.url)))
        let groupsText = try XCTUnwrap(try queryItems(routed).first { $0.name == "groups" }?.value)
        let groups = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(groupsText.utf8)) as? [[String: Any]])
        let rules = groups.flatMap { $0["rules"] as? [[String: Any]] ?? [] }
        func value(_ field: String) -> Any? { rules.first { $0["field"] as? String == field }?["value"] }
        XCTAssertEqual(value("genre") as? String, "Horror")
        XCTAssertEqual(value("content_rating") as? String, "15")
        XCTAssertEqual(value("year") as? [Int], [2010, 2019])
        XCTAssertEqual(value("dolby_vision") as? Bool, true)
        XCTAssertEqual(value("watched") as? Bool, false)
        XCTAssertTrue(groupsText.contains("\"value\":false"))
        XCTAssertTrue(groupsText.contains("\"value\":[2010,2019]"))
    }

    func testPersonalListsUseHydratedCataloguePagination() throws {
        let routed = try request("/api/v1/watchlist?offset=60&limit=60")
        XCTAssertEqual(routed.url?.path, "/silo/api/v2/catalog")
        let items = try queryItems(routed)
        XCTAssertTrue(items.contains(URLQueryItem(name: "source", value: "watchlist")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "seek", value: "60")))
    }

    func testIDsConvertOnlyAtTheWireBoundary() throws {
        let start = try request(
            "/api/v1/playback/start", method: "POST",
            body: #"{"file_id":42,"profile_id":"007","client_playback_context":{"device":{"id":"009"}}}"#)
        let body = try jsonBody(start)
        XCTAssertEqual(body["file_id"] as? String, "42")
        XCTAssertEqual(body["profile_id"] as? String, "007")

        let login = try response(#"{"user":{"id":"42","username":"viewer"},"access_token":"opaque"}"#, path: "/api/v1/auth/login")
        XCTAssertEqual((login["user"] as? [String: Any])?["id"] as? Int, 42)

        let profiles = try response(#"{"items":[{"id":"007","allowed_library_ids":["42"]}]}"#, path: "/api/v1/profiles")
        let first = (profiles["profiles"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["id"] as? String, "007")
        XCTAssertEqual(first?["allowed_library_ids"] as? [Int], [42])
    }

    func testSettingsValuesRemainOpaqueAndManifestRevisionIsUsed() throws {
        let text = #"{"key":"custom","value":{"library_id":42,"nested":{"file_id":"007"}}}"#
        let body = try jsonBody(try request("/api/v1/settings/values/custom", method: "PUT", body: text))
        XCTAssertEqual((body["value"] as? [String: Any])?["library_id"] as? Int, 42)
        let reply = try response(text, path: "/api/v1/settings/values/custom")
        XCTAssertEqual(((reply["value"] as? [String: Any])?["nested"] as? [String: Any])?["file_id"] as? String, "007")
        let contract = try response(#"{"revision":"opaque","manifest_revision":12}"#, path: "/api/v1/settings/contract/capabilities")
        XCTAssertEqual(contract["revision"] as? Int, 12)
    }

    func testNativeItemDetailKeepsCreditIDsAsStrings() throws {
        let fixture = #"""
        {"content_id":"movie:heat-1995","type":"movie","title":"Heat","year":1995,"genres":["Crime"],"keywords":[],
         "status":"","tagline":"A Los Angeles crime saga","subtitles":[],"overlay_summary":{"resolution":"4K"},
         "user_state":{"played":true,"is_favorite":true,"in_watchlist":false},
         "work_formats":[{"type":"ebook","content_id":"ebook:heat","library_id":"2"}],
         "cast":[{"name":"Lead Actor","character":"Detective","order":0,"person_id":"7"}],"crew":[],
         "user_data":{"watched_count":1,"unplayed_count":0,"in_progress_count":0,"played":true,"last_file_id":"120"},
         "versions":[{"file_id":"120","file_path":"/media/movies/Heat.mkv","resolution":"2160p","codec_video":"",
           "codec_audio":"","container":"","hdr":false,"file_size":0,"duration":0,"bitrate":0,
           "added_at":"2026-01-02T03:04:05.678Z"}]}
        """#
        var item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        item["crew"] = [["name": "Director", "job": "Director", "person_id": "008"]]
        let converted = try SiloAPICompatibility.response(
            try JSONSerialization.data(withJSONObject: item), path: "/api/v1/catalog/items/movie:heat-1995")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(ItemDetail.self, from: converted)
        XCTAssertEqual(detail.title, "Heat")
        XCTAssertEqual(detail.cast?.first?.personId, "7")
        XCTAssertEqual(detail.crew?.first?.personId, "008")
        XCTAssertEqual(detail.versions?.first?.fileId, 120)
        XCTAssertEqual(detail.userData?.lastFileId, 120)
    }

    func testNativeWatchDetailDecodesMarkerTimesAndDuration() throws {
        let fixture = #"""
        {"content_id":"movie:heat-1995","type":"movie","title":"Heat","year":1995,
         "versions":[{"file_id":"42","resolution":"1080p","codec_video":"h264","codec_audio":"eac3","hdr":false,
           "container":"mkv","file_size":1024,"duration_seconds":10200,"bitrate":8000000,
           "added_at":"2026-01-02T03:04:05.000Z",
           "video_tracks":[{"codec":"h264","dv_config_present":false,"dv_bl_compat_id_present":false,"width":1920,
             "height":1080,"interlaced":false}],
           "audio_tracks":[{"language":"eng","codec":"eac3","channels":6,"default":true}],
           "chapters":[{"index":1,"title":"Opening","start_seconds":0,"end_seconds":300,"source":"embedded"}],
           "intro":{"start_seconds":0,"end_seconds":90}}],
         "playback_variants":[{"variant_id":"v1","part_count":1,"default_file_id":"42",
           "parts":[{"part_index":0,"default_file_id":"42","versions":[]}]}],
         "subtitles":[{"source":"embedded","language":"eng","forced":false,"hearing_impaired":false}],
         "credits":{"start_seconds":10000,"end_seconds":10200},
         "user_data":{"position_seconds":1325.5,"duration_seconds":10200,"is_in_progress":true,"watched_count":0,
           "unplayed_count":0,"in_progress_count":0,"played":false,"last_file_id":"3"},
         "effective_subtitle_language":"eng"}
        """#
        let converted = try SiloAPICompatibility.response(Data(fixture.utf8), path: "/api/v1/watch/movie:heat-1995")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let watch = try decoder.decode(WatchDetail.self, from: converted)
        XCTAssertEqual(watch.versions.first?.duration, 10_200)
        XCTAssertEqual(watch.versions.first?.intro?.end, 90)
        XCTAssertEqual(watch.credits?.start, 10_000)
        XCTAssertEqual(watch.versions.first?.chapters?.first?.endSeconds, 300)
        XCTAssertEqual(watch.userData?.positionSeconds, 1_325.5)
    }

    func testV2SettingsListsUseRepeatedQueryParameters() throws {
        let routed = try request("/api/v1/settings/values/effective?keys=ui.theme,player.volume&library_ids=1,2&series_ids=tv:one,tv:two")
        let items = try queryItems(routed)
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        XCTAssertEqual(values("keys"), ["ui.theme", "player.volume"])
        XCTAssertEqual(values("library_ids"), ["1", "2"])
        XCTAssertEqual(values("series_ids"), ["tv:one", "tv:two"])
    }

    func testQRLoginUnwrapsTokens() throws {
        let reply = try response(
            #"{"status":"approved","profile_id":"p","tokens":{"access_token":"a","refresh_token":"r","user":{"id":"42"}}}"#,
            path: "/api/v1/auth/device/poll")
        XCTAssertEqual(reply["access_token"] as? String, "a")
        XCTAssertEqual(reply["profile_id"] as? String, "p")
        XCTAssertEqual((reply["user"] as? [String: Any])?["id"] as? Int, 42)
    }

    func testCatalogueAndEpisodeEnvelopes() throws {
        let catalogue = try response(
            #"{"items":[],"window_cursor":"window","page":{"has_more":true,"next_cursor":"next"}}"#, path: "/api/v1/catalog")
        XCTAssertEqual(catalogue["has_more"] as? Bool, true)
        XCTAssertEqual(catalogue["snapshot"] as? String, "window")
        let episodes = try response(
            #"{"items":[{"content_id":"episode:one","files":[{"file_id":"12"}]}]}"#,
            path: "/api/v1/catalog/series/s/seasons/1/episodes")
        let episode = (episodes["episodes"] as? [[String: Any]])?.first
        XCTAssertEqual(episode?["content_id"] as? String, "episode:one")
        XCTAssertEqual((episode?["files"] as? [[String: Any]])?.first?["file_id"] as? Int, 12)
    }

    func testPlaybackCapabilityRespectsAvailabilityAndPermission() throws {
        for (state, allowed, enabled) in [("available", true, true), ("disabled", true, false), ("available", false, false)] {
            let reply = try response(#"{"state":"\#(state)","allowed":\#(allowed)}"#, path: "/api/v1/playback/capability")
            XCTAssertEqual(reply["enabled"] as? Bool, enabled, "\(state) \(allowed)")
        }
    }

    func testProgressUploadChangesSecondsToMilliseconds() throws {
        let upload = try request(
            "/api/v1/sync/progress", method: "POST",
            body: #"{"items":[{"media_item_id":"movie:one","position":1.5,"duration":60,"force_overwrite":false}]}"#)
        let item = (try jsonBody(upload)["items"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["position_ms"] as? Int, 1_500)
        XCTAssertEqual(item?["duration_ms"] as? Int, 60_000)
        XCTAssertNil(item?["position"])
        let reply = try response(#"{"items":[{"media_item_id":"movie:one","status":"success"}]}"#, path: "/api/v1/sync/progress")
        XCTAssertEqual((reply["results"] as? [[String: Any]])?.first?["status"] as? String, "ok")
    }

    // MARK: - Other areas: media requests and playback decisions

    func testNativeV2MediaPreservesSignedReferenceAndHeaderCredential() throws {
        let resolved = try XCTUnwrap(StreamRequest.resolve(
            rawURL: "/api/v2/stream/session?st=signed%2Breference&seek=12.5",
            serverURL: "https://server.example/silo",
            additionalHeaders: ["X-Profile-Id": "p"],
            accessToken: "account",
            requiresHeaderAuthenticatedMedia: true,
            nativeApiMajor: 2))
        XCTAssertEqual(resolved.url.absoluteString, "https://server.example/silo/api/v2/stream/session?st=signed%2Breference&seek=12.5")
        XCTAssertEqual(resolved.headers["Authorization"], "Bearer account")
        XCTAssertEqual(resolved.headers["X-Profile-Id"], "p")
        for rawURL in [
            "https://other.example/api/v2/stream/session?st=signed",
            "/api/v2/stream/session?token=account",
            "/api/v2/stream/session?st=a&st=b",
            "/api/v2/stream/../auth/me",
            "/api/v2/stream/session?seek=nan",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: rawURL, serverURL: "https://server.example", additionalHeaders: [:], accessToken: "account",
                requiresHeaderAuthenticatedMedia: true, nativeApiMajor: 2), rawURL)
        }
    }

    func testLegacyMediaRulesRemainUnchanged() {
        func resolve(_ rawURL: String) -> StreamRequest? {
            StreamRequest.resolve(
                rawURL: rawURL, serverURL: "https://server.example", additionalHeaders: [:], accessToken: "account",
                requiresHeaderAuthenticatedMedia: true)
        }
        XCTAssertNotNil(resolve("/stream/session?seek=12"))
        XCTAssertNil(resolve("/stream/session?st=signed"))
        XCTAssertNil(resolve("/api/v2/stream/session?st=signed"))
    }

    func testNativePlaybackDecisionDecodesIntoExistingPlayerModels() throws {
        let session = "11111111-1111-4111-8111-111111111111"
        let fixture = #"""
        {"protocol_version":3,
         "server_features":["playback_plan_v3","neutral_playback_v3_contract_v1","layout_aware_passthrough",
           "device_quirks_v1","output_display_evidence_v1","direct_stream_resume_v1","software_video_decode_v1",
           "plan_source_duration_v1","sequenced_progress_v1"],
         "outcome":"playable","session_id":"SESSION",
         "playback_plan":{
           "protocol_version":3,"plan_id":"plan:478677870860e5e5108c18bff749b34b","plan_attempt_key":"v3:f0144c47fa349e3e",
           "session_id":"SESSION","expires_at":"2030-01-01T00:00:00Z","delivery":"original_http",
           "stream":{"url":"/api/v2/stream/SESSION","protocol":"http_progressive","container":"mp4","mime_type":"video/mp4",
             "headers":{},"header_refresh":"none"},
           "timeline":{"source_start_seconds":12.5,"stream_origin_seconds":0,"player_start_seconds":12.5,
             "timeline_offset_seconds":0,"can_seek_anywhere":true,"seek_restoration":"player_position"},
           "selected_tracks":{"audio":{"id":"file:42:audio:0","index":0}},
           "effective_recipe":{"video_codec":"h264","audio_codec":"aac","width":1920,"height":1080,
             "frame_rate":23.976023976023978,"bitrate_kbps":8000,"dynamic_range":"sdr","audio_channels":2,"audio_layout":"stereo"},
           "claims":{
             "video":{"hdr10":false,"hdr10_plus":false,"hlg":false,"dolby_vision":false},
             "audio":{"codec":"aac","passthrough":false,"atmos_preserved":false,"reason":"client_decode_supported"},
             "subtitles":{"ass_styling_preserved":false,"bitmap_overlay":false,"bitmap_sidecar":false}},
           "subtitle":{"mode":"off","inventory":[
             {"track_id":"file:42:subtitle:0","combined_index":0,"source":"external","codec":"srt","language":"eng",
              "label":"English","forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar",
              "url":"/api/v2/stream/SESSION/subtitles/0.vtt?file_id=42&external_subtitle_key=f903db1c5624c46c4a2c20f2fd8cd247fc0d46e6471c91d4ddb651ae4e039448"},
             {"track_id":"file:42:subtitle:1","combined_index":1,"source":"embedded","codec":"ass","language":"eng",
              "label":"English (Signs)","forced":true,"default":false,"hearing_impaired":false,"delivery":"sidecar",
              "url":"/api/v2/stream/SESSION/subtitles/1.ass?file_id=42&embedded_stream_index=0",
              "font_bundle_url":"/api/v2/stream/SESSION/subtitles/1/fonts?file_id=42&embedded_stream_index=0"},
             {"track_id":"file:42:subtitle:2","combined_index":2,"source":"embedded","codec":"pgs","language":"jpn",
              "label":"Japanese","forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar",
              "url":"/api/v2/stream/SESSION/subtitles/2.sup?file_id=42&embedded_stream_index=1"},
             {"track_id":"file:42:subtitle:3","combined_index":3,"source":"embedded","codec":"dvd_subtitle","language":"fre",
              "label":"French","forced":false,"default":false,"hearing_impaired":false,"delivery":"burn_in_only"},
             {"track_id":"file:42:subtitle:4","combined_index":4,"source":"downloaded","codec":"srt","language":"spa",
              "label":"Spanish (downloaded)","forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar",
              "url":"/api/v2/stream/SESSION/subtitles/4.vtt?file_id=42"}]},
           "transformations":[],"applied_quirks":[],"runtime_corrections":[],"degradation_warnings":[],
           "available_qualities":[{"label":"original","height":1080,"bitrate_kbps":8000,"preserves_source":true}],
           "decision_reason":"validated_original_playback",
           "requested_media_file_id":"42","effective_media_file_id":"42",
           "source":{"media_file_id":"42","duration_seconds":7200,"container":"mp4","video_codec":"h264",
             "video_profile":"high","video_level":41,"bit_depth":8,"width":1920,"height":1080,
             "frame_rate":23.976023976023978,"bitrate_kbps":8000,"dynamic_range":"sdr","hdr10_plus":false,
             "dv_enhancement_layer":"none","audio_codec":"aac","audio_channels":2,"audio_layout":"stereo"},
           "subtitle_fidelity_policy":"allow_simplified_rendering"}}
        """#.replacingOccurrences(of: "SESSION", with: session)
        let converted = try SiloAPICompatibility.response(Data(fixture.utf8), path: "/api/v1/playback/start")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decision = try decoder.decode(PlaybackV3DecisionResponse.self, from: converted)
        XCTAssertEqual(decision.nativeApiMajor, 2)
        guard case .playable(let plan, _) = decision.validatedForApple() else {
            return XCTFail("The decision should be playable")
        }
        XCTAssertEqual(plan.nativeApiMajor, 2)
        XCTAssertEqual(plan.effectiveMediaFileId, 42)
        XCTAssertEqual(plan.requestedMediaFileId, 42)
        XCTAssertEqual(plan.source.mediaFileId, 42)
        XCTAssertTrue(plan.stream.url.hasPrefix("/api/v2/stream/"))
    }

    // MARK: - Discovery

    func testDiscoveryDistinguishesOldAndNewServersAndNeverSendsCredentials() async throws {
        let session = DiscoveryStubs.session(HostSwitchingDiscoveryStub.self)
        defer { session.invalidateAndCancel() }
        let discovery = SiloAPIDiscovery()
        let modern = try await discovery.usesV2(for: try XCTUnwrap(URL(string: "https://modern.example/silo/api/v1/auth/setup")), session: session)
        XCTAssertTrue(modern)
        let legacy = try await discovery.usesV2(for: try XCTUnwrap(URL(string: "https://legacy.example/silo/api/v1/auth/setup")), session: session)
        XCTAssertFalse(legacy)
        do {
            _ = try await discovery.usesV2(for: try XCTUnwrap(URL(string: "https://unavailable.example/silo/api/v1/auth/setup")), session: session)
            XCTFail("An unavailable server must not be treated as an answer")
        } catch {}
    }
}

/// Discovery answers stay fresh for a while, then refresh in the background.
final class SiloDiscoveryRefreshTests: XCTestCase {
    func testRecentAnswerIsServedWhileABackgroundCheckRefreshesIt() async throws {
        CountingDiscoveryStub.reset()
        let session = DiscoveryStubs.session(CountingDiscoveryStub.self)
        defer {
            session.invalidateAndCancel()
            CountingDiscoveryStub.reset()
        }
        let clock = FixedClock()
        let discovery = SiloAPIDiscovery(now: { clock.now })
        let url = try XCTUnwrap(URL(string: "https://upgrade.example/silo/api/v1/auth/setup"))

        CountingDiscoveryStub.status = 404
        var usesV2 = try await discovery.usesV2(for: url, session: session)
        XCTAssertFalse(usesV2)
        XCTAssertEqual(CountingDiscoveryStub.count, 1)

        clock.advance(30)
        usesV2 = try await discovery.usesV2(for: url, session: session)
        XCTAssertFalse(usesV2)
        XCTAssertEqual(CountingDiscoveryStub.count, 1)

        CountingDiscoveryStub.status = 200
        clock.advance(90)
        usesV2 = try await discovery.usesV2(for: url, session: session)
        XCTAssertFalse(usesV2)

        var refreshed = false
        for _ in 0..<200 {
            if try await discovery.usesV2(for: url, session: session) {
                refreshed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(CountingDiscoveryStub.count, 2)

        CountingDiscoveryStub.status = 404
        clock.advance(700)
        usesV2 = try await discovery.usesV2(for: url, session: session)
        XCTAssertFalse(usesV2)
        XCTAssertEqual(CountingDiscoveryStub.count, 3)
    }

    func testFailedCheckIsNotReusedByTheNextRequest() async throws {
        CountingDiscoveryStub.reset()
        let session = DiscoveryStubs.session(CountingDiscoveryStub.self)
        defer {
            session.invalidateAndCancel()
            CountingDiscoveryStub.reset()
        }
        let discovery = SiloAPIDiscovery()
        let url = try XCTUnwrap(URL(string: "https://flaky.example/silo/api/v1/auth/setup"))

        CountingDiscoveryStub.status = 503
        do {
            _ = try await discovery.usesV2(for: url, session: session)
            XCTFail("A failed check must not become an answer")
        } catch {}

        CountingDiscoveryStub.status = 200
        let usesV2 = try await discovery.usesV2(for: url, session: session)
        XCTAssertTrue(usesV2)
        XCTAssertEqual(CountingDiscoveryStub.count, 2)
    }
}

// MARK: - Test doubles

private enum DiscoveryStubs {
    static func session(_ stub: URLProtocol.Type) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [stub]
        return URLSession(configuration: configuration)
    }

    static func reply(to request: URLRequest, status: Int, from stub: URLProtocol) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else { return }
        stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
        stub.client?.urlProtocol(stub, didLoad: Data(#"{"api_major":2}"#.utf8))
        stub.client?.urlProtocolDidFinishLoading(stub)
    }
}

/// A clock the discovery tests move by hand.
private final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Answers every probe with the current status and a body that claims v2, so
/// only the status decides. Counts the probes it sees.
private final class CountingDiscoveryStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentStatus = 404
    nonisolated(unsafe) private static var probes = 0

    static var status: Int {
        get { lock.withLock { currentStatus } }
        set { lock.withLock { currentStatus = newValue } }
    }

    static var count: Int { lock.withLock { probes } }

    static func reset() {
        lock.withLock {
            currentStatus = 404
            probes = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.lock.withLock {
            Self.probes += 1
            return Self.currentStatus
        }
        DiscoveryStubs.reply(to: request, status: status, from: self)
    }

    override func stopLoading() {}
}

/// A v2 server, a v1 server and an unavailable one, told apart by host.
/// Every probe must go to system info without credentials.
private final class HostSwitchingDiscoveryStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/silo/api/v2/system/info")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Token"))
        let status = switch request.url?.host {
        case "modern.example": 200
        case "legacy.example": 404
        default: 503
        }
        DiscoveryStubs.reply(to: request, status: status, from: self)
    }

    override func stopLoading() {}
}
