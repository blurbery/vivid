import XCTest
@testable import Vivid

final class SiloAPICompatibilityTests: XCTestCase {
    private func request(_ path: String, method: String = "GET", body: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://server.example/silo" + path)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        request.setValue("Bearer account", forHTTPHeaderField: "Authorization")
        request.setValue("profile", forHTTPHeaderField: "X-Profile-Id")
        return try SiloAPICompatibility.request(request)
    }

    private func response(_ body: String, path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: SiloAPICompatibility.response(Data(body.utf8), path: path)) as? [String: Any])
    }

    func testRenamedEndpointsAndMethodsPreserveBasePathAndAuth() throws {
        let cases = [
            ("/api/v1/auth/setup", "GET", "/api/v2/system/setup", "GET"),
            ("/api/v1/auth/setup", "POST", "/api/v2/auth/setup", "POST"),
            ("/api/v1/auth/me", "GET", "/api/v2/account/me", "GET"),
            ("/api/v1/people/42", "GET", "/api/v2/catalog/people/42", "GET"),
            ("/api/v1/profiles/p", "PUT", "/api/v2/profiles/p", "PATCH"),
            ("/api/v1/collections/c", "PUT", "/api/v2/collections/c", "PATCH"),
            ("/api/v1/collections/sort-preference", "PUT", "/api/v2/collections/sort-preference", "PUT"),
            ("/api/v1/playback/capability", "GET", "/api/v2/playback/capabilities", "GET"),
        ]
        for (old, verb, path, mappedVerb) in cases {
            let mapped = try request(old, method: verb)
            XCTAssertEqual(mapped.url?.path, "/silo" + path)
            XCTAssertEqual(mapped.httpMethod, mappedVerb)
            XCTAssertEqual(mapped.value(forHTTPHeaderField: "Authorization"), "Bearer account")
            XCTAssertEqual(mapped.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        }
    }

    func testEscapedContentIdentifierAndOpaqueV2URLRemainIntact() throws {
        let mapped = try request("/api/v1/catalog/items/movie%3Aone%2Ftwo")
        XCTAssertEqual(URLComponents(url: mapped.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/silo/api/v2/catalog/items/movie%3Aone%2Ftwo")
        let opaque = URLRequest(url: URL(string: "https://cdn.example/api/v2/stream/token?signature=opaque")!)
        XCTAssertEqual(try SiloAPICompatibility.request(opaque), opaque)
    }

    func testCatalogueSortSeekAndGroupedFilters() throws {
        let mapped = try request("/api/v1/catalog?offset=60&limit=60&sort=year&order=desc&include_total=false&snapshot=window&groups%5B0%5D%5Bmatch%5D=any&groups%5B0%5D%5Brules%5D%5B0%5D%5Bfield%5D=genre&groups%5B0%5D%5Brules%5D%5B0%5D%5Bop%5D=contains&groups%5B0%5D%5Brules%5D%5B0%5D%5Bvalue%5D=Drama")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: mapped.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["seek"], "60")
        XCTAssertEqual(query["cursor"], "window")
        XCTAssertEqual(query["sort"], "-year")
        XCTAssertEqual(query["skip_total"], "true")
        XCTAssertNil(query["offset"])
        XCTAssertNil(query["order"])
        let groups = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(query["groups"]!.utf8)) as? [[String: Any]])
        XCTAssertEqual(groups.first?["match"] as? String, "any")
        XCTAssertEqual((groups.first?["rules"] as? [[String: Any]])?.first?["value"] as? String, "Drama")
    }

    func testPersonalListsUseHydratedCataloguePagination() throws {
        let mapped = try request("/api/v1/watchlist?offset=60&limit=60")
        let query = URLComponents(url: mapped.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(mapped.url?.path, "/silo/api/v2/catalog")
        XCTAssertTrue(query.contains(URLQueryItem(name: "source", value: "watchlist")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "seek", value: "60")))
    }

    func testIDsConvertOnlyAtTheWireBoundary() throws {
        let mapped = try request("/api/v1/playback/start", method: "POST", body: #"{"file_id":42,"profile_id":"007","client_playback_context":{"device":{"id":"009"}}}"#)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mapped.httpBody!) as? [String: Any])
        XCTAssertEqual(body["file_id"] as? String, "42")
        XCTAssertEqual(body["profile_id"] as? String, "007")
        let login = try response(#"{"user":{"id":"42","username":"viewer"},"access_token":"opaque"}"#, path: "/api/v1/auth/login")
        XCTAssertEqual((login["user"] as? [String: Any])?["id"] as? Int, 42)
        let profiles = try response(#"{"items":[{"id":"007","allowed_library_ids":["42"]}]}"#, path: "/api/v1/profiles")
        let profile = (profiles["profiles"] as? [[String: Any]])?.first
        XCTAssertEqual(profile?["id"] as? String, "007")
        XCTAssertEqual(profile?["allowed_library_ids"] as? [Int], [42])
    }

    func testSettingsValuesRemainOpaqueAndManifestRevisionIsUsed() throws {
        let input = #"{"key":"custom","value":{"library_id":42,"nested":{"file_id":"007"}}}"#
        let mapped = try request("/api/v1/settings/values/custom", method: "PUT", body: input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mapped.httpBody!) as? [String: Any])
        XCTAssertEqual((body["value"] as? [String: Any])?["library_id"] as? Int, 42)
        let result = try response(input, path: "/api/v1/settings/values/custom")
        XCTAssertEqual(((result["value"] as? [String: Any])?["nested"] as? [String: Any])?["file_id"] as? String, "007")
        XCTAssertEqual(try response(#"{"revision":"opaque","manifest_revision":12}"#, path: "/api/v1/settings/contract/capabilities")["revision"] as? Int, 12)
    }

    func testNativeItemDetailKeepsCreditIDsAsStrings() throws {
        // Upstream v2 get_catalog_item_ok fixture, with crew coverage added.
        let wire = #"""
        {
          "content_id": "movie:heat-1995",
          "type": "movie",
          "title": "Heat",
          "year": 1995,
          "genres": [
            "Crime"
          ],
          "keywords": [],
          "status": "",
          "overlay_summary": {
            "resolution": "4K"
          },
          "user_state": {
            "played": true,
            "is_favorite": true,
            "in_watchlist": false
          },
          "work_formats": [
            {
              "type": "ebook",
              "content_id": "ebook:heat",
              "library_id": "2"
            }
          ],
          "tagline": "A Los Angeles crime saga",
          "cast": [
            {
              "name": "Al Pacino",
              "character": "Vincent Hanna",
              "order": 0,
              "person_id": "7"
            }
          ],
          "crew": [],
          "user_data": {
            "watched_count": 1,
            "unplayed_count": 0,
            "in_progress_count": 0,
            "played": true,
            "last_file_id": "120"
          },
          "versions": [
            {
              "file_id": "120",
              "file_path": "/media/movies/Heat.mkv",
              "resolution": "2160p",
              "codec_video": "",
              "codec_audio": "",
              "hdr": false,
              "container": "",
              "file_size": 0,
              "duration": 0,
              "bitrate": 0,
              "added_at": "2026-01-02T03:04:05.678Z"
            }
          ],
          "subtitles": []
        }
        """#
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
        object["crew"] = [["name": "Director", "job": "Director", "person_id": "008"]]
        let data = try SiloAPICompatibility.response(JSONSerialization.data(withJSONObject: object), path: "/api/v1/catalog/items/movie:heat-1995")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(ItemDetail.self, from: data)
        XCTAssertEqual(item.title, "Heat")
        XCTAssertEqual(item.cast?.first?.personId, "7")
        XCTAssertEqual(item.crew?.first?.personId, "008")
        XCTAssertEqual(item.versions?.first?.fileId, 120)
        XCTAssertEqual(item.userData?.lastFileId, 120)
    }

    func testNativeWatchDetailDecodesMarkerTimesAndDuration() throws {
        let wire = #"""
        {
          "content_id": "movie:heat-1995",
          "type": "movie",
          "title": "Heat",
          "year": 1995,
          "versions": [
            {
              "file_id": "42",
              "resolution": "1080p",
              "codec_video": "h264",
              "codec_audio": "eac3",
              "hdr": false,
              "container": "mkv",
              "file_size": 1024,
              "duration_seconds": 10200,
              "bitrate": 8000000,
              "added_at": "2026-01-02T03:04:05.000Z",
              "video_tracks": [
                {
                  "codec": "h264",
                  "dv_config_present": false,
                  "dv_bl_compat_id_present": false,
                  "width": 1920,
                  "height": 1080,
                  "interlaced": false
                }
              ],
              "audio_tracks": [
                {
                  "language": "eng",
                  "codec": "eac3",
                  "channels": 6,
                  "default": true
                }
              ],
              "chapters": [
                {
                  "index": 1,
                  "title": "Opening",
                  "start_seconds": 0,
                  "end_seconds": 300,
                  "source": "embedded"
                }
              ],
              "intro": {
                "start_seconds": 0,
                "end_seconds": 90
              }
            }
          ],
          "playback_variants": [
            {
              "variant_id": "v1",
              "part_count": 1,
              "default_file_id": "42",
              "parts": [
                {
                  "part_index": 0,
                  "default_file_id": "42",
                  "versions": []
                }
              ]
            }
          ],
          "subtitles": [
            {
              "source": "embedded",
              "language": "eng",
              "forced": false,
              "hearing_impaired": false
            }
          ],
          "credits": {
            "start_seconds": 10000,
            "end_seconds": 10200
          },
          "user_data": {
            "position_seconds": 1325.5,
            "duration_seconds": 10200,
            "is_in_progress": true,
            "watched_count": 0,
            "unplayed_count": 0,
            "in_progress_count": 0,
            "played": false,
            "last_file_id": "3"
          },
          "effective_subtitle_language": "eng"
        }
        """#
        let data = try SiloAPICompatibility.response(Data(wire.utf8), path: "/api/v1/watch/movie:heat-1995")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(WatchDetail.self, from: data)
        XCTAssertEqual(item.versions.first?.duration, 10200)
        XCTAssertEqual(item.versions.first?.intro?.end, 90)
        XCTAssertEqual(item.credits?.start, 10000)
        XCTAssertEqual(item.versions.first?.chapters?.first?.endSeconds, 300)
        XCTAssertEqual(item.userData?.positionSeconds, 1325.5)
    }

    func testV2SettingsListsUseRepeatedQueryParameters() throws {
        let mapped = try request("/api/v1/settings/values/effective?keys=ui.theme,player.volume&library_ids=1,2&series_ids=tv:one,tv:two")
        let items = try XCTUnwrap(URLComponents(url: mapped.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "keys" }.compactMap(\.value), ["ui.theme", "player.volume"])
        XCTAssertEqual(items.filter { $0.name == "library_ids" }.compactMap(\.value), ["1", "2"])
        XCTAssertEqual(items.filter { $0.name == "series_ids" }.compactMap(\.value), ["tv:one", "tv:two"])
    }

    func testQRLoginUnwrapsTokens() throws {
        let result = try response(#"{"status":"approved","profile_id":"p","tokens":{"access_token":"a","refresh_token":"r","user":{"id":"42"}}}"#, path: "/api/v1/auth/device/poll")
        XCTAssertEqual(result["access_token"] as? String, "a")
        XCTAssertEqual(result["profile_id"] as? String, "p")
        XCTAssertEqual((result["user"] as? [String: Any])?["id"] as? Int, 42)
    }

    func testCatalogueAndEpisodeEnvelopes() throws {
        let catalogue = try response(#"{"items":[],"window_cursor":"window","page":{"has_more":true,"next_cursor":"next"}}"#, path: "/api/v1/catalog")
        XCTAssertEqual(catalogue["has_more"] as? Bool, true)
        XCTAssertEqual(catalogue["snapshot"] as? String, "window")
        let episodes = try response(#"{"items":[{"content_id":"episode:one","files":[{"file_id":"12"}]}]}"#, path: "/api/v1/catalog/series/s/seasons/1/episodes")
        let episode = (episodes["episodes"] as? [[String: Any]])?.first
        XCTAssertEqual(episode?["content_id"] as? String, "episode:one")
        XCTAssertEqual((episode?["files"] as? [[String: Any]])?.first?["file_id"] as? Int, 12)
    }

    func testPlaybackCapabilityRespectsAvailabilityAndPermission() throws {
        for (state, allowed, expected) in [("available", true, true), ("disabled", true, false), ("available", false, false)] {
            let result = try response("{\"state\":\"\(state)\",\"allowed\":\(allowed)}", path: "/api/v1/playback/capability")
            XCTAssertEqual(result["enabled"] as? Bool, expected)
        }
    }

    func testProgressUploadChangesSecondsToMilliseconds() throws {
        let mapped = try request("/api/v1/sync/progress", method: "POST", body: #"{"items":[{"media_item_id":"movie:one","position":1.5,"duration":60,"force_overwrite":false}]}"#)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mapped.httpBody!) as? [String: Any])
        let item = (body["items"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["position_ms"] as? Int, 1500)
        XCTAssertEqual(item?["duration_ms"] as? Int, 60000)
        XCTAssertNil(item?["position"])
        XCTAssertEqual((try response(#"{"items":[{"media_item_id":"movie:one","status":"success"}]}"#, path: "/api/v1/sync/progress")["results"] as? [[String: Any]])?.first?["status"] as? String, "ok")
    }

    func testNativeV2MediaPreservesSignedReferenceAndHeaderCredential() {
        let request = StreamRequest.resolve(rawURL: "/api/v2/stream/session?st=signed%2Breference&seek=12.5",
            serverURL: "https://server.example/silo", additionalHeaders: ["X-Profile-Id": "p"],
            accessToken: "account", requiresHeaderAuthenticatedMedia: true, nativeApiMajor: 2)
        XCTAssertEqual(request?.url.absoluteString, "https://server.example/silo/api/v2/stream/session?st=signed%2Breference&seek=12.5")
        XCTAssertEqual(request?.headers["Authorization"], "Bearer account")
        XCTAssertEqual(request?.headers["X-Profile-Id"], "p")
        for rejected in ["https://other.example/api/v2/stream/session?st=signed", "/api/v2/stream/session?token=account", "/api/v2/stream/session?st=a&st=b", "/api/v2/stream/../auth/me", "/api/v2/stream/session?seek=nan"] {
            XCTAssertNil(StreamRequest.resolve(rawURL: rejected, serverURL: "https://server.example", additionalHeaders: [:],
                accessToken: "account", requiresHeaderAuthenticatedMedia: true, nativeApiMajor: 2))
        }
    }

    func testLegacyMediaRulesRemainUnchanged() {
        XCTAssertNotNil(StreamRequest.resolve(rawURL: "/stream/session?seek=12", serverURL: "https://server.example", additionalHeaders: [:], accessToken: "account", requiresHeaderAuthenticatedMedia: true))
        XCTAssertNil(StreamRequest.resolve(rawURL: "/stream/session?st=signed", serverURL: "https://server.example", additionalHeaders: [:], accessToken: "account", requiresHeaderAuthenticatedMedia: true))
        XCTAssertNil(StreamRequest.resolve(rawURL: "/api/v2/stream/session?st=signed", serverURL: "https://server.example", additionalHeaders: [:], accessToken: "account", requiresHeaderAuthenticatedMedia: true))
    }

    // Native Silo contract fixture, upstream fa770b7f9f521ab81389350939eb57db9ef5db46.
    func testNativePlaybackDecisionDecodesIntoExistingPlayerModels() throws {
        let wire = #"""
        {
          "protocol_version": 3,
          "server_features": [
            "playback_plan_v3",
            "neutral_playback_v3_contract_v1",
            "layout_aware_passthrough",
            "device_quirks_v1",
            "output_display_evidence_v1",
            "direct_stream_resume_v1",
            "software_video_decode_v1",
            "plan_source_duration_v1",
            "sequenced_progress_v1"
          ],
          "outcome": "playable",
          "session_id": "11111111-1111-4111-8111-111111111111",
          "playback_plan": {
            "protocol_version": 3,
            "plan_id": "plan:478677870860e5e5108c18bff749b34b",
            "plan_attempt_key": "v3:f0144c47fa349e3e",
            "session_id": "11111111-1111-4111-8111-111111111111",
            "expires_at": "2030-01-01T00:00:00Z",
            "delivery": "original_http",
            "stream": {
              "url": "/api/v2/stream/11111111-1111-4111-8111-111111111111",
              "protocol": "http_progressive",
              "container": "mp4",
              "mime_type": "video/mp4",
              "headers": {},
              "header_refresh": "none"
            },
            "timeline": {
              "source_start_seconds": 12.5,
              "stream_origin_seconds": 0,
              "player_start_seconds": 12.5,
              "timeline_offset_seconds": 0,
              "can_seek_anywhere": true,
              "seek_restoration": "player_position"
            },
            "selected_tracks": {
              "audio": {
                "id": "file:42:audio:0",
                "index": 0
              }
            },
            "effective_recipe": {
              "video_codec": "h264",
              "audio_codec": "aac",
              "width": 1920,
              "height": 1080,
              "frame_rate": 23.976023976023978,
              "bitrate_kbps": 8000,
              "dynamic_range": "sdr",
              "audio_channels": 2,
              "audio_layout": "stereo"
            },
            "claims": {
              "video": {
                "hdr10": false,
                "hdr10_plus": false,
                "hlg": false,
                "dolby_vision": false
              },
              "audio": {
                "codec": "aac",
                "passthrough": false,
                "atmos_preserved": false,
                "reason": "client_decode_supported"
              },
              "subtitles": {
                "ass_styling_preserved": false,
                "bitmap_overlay": false,
                "bitmap_sidecar": false
              }
            },
            "subtitle": {
              "mode": "off",
              "inventory": [
                {
                  "track_id": "file:42:subtitle:0",
                  "combined_index": 0,
                  "source": "external",
                  "codec": "srt",
                  "language": "eng",
                  "label": "English",
                  "forced": false,
                  "default": false,
                  "hearing_impaired": false,
                  "delivery": "sidecar",
                  "url": "/api/v2/stream/11111111-1111-4111-8111-111111111111/subtitles/0.vtt?file_id=42&external_subtitle_key=f903db1c5624c46c4a2c20f2fd8cd247fc0d46e6471c91d4ddb651ae4e039448"
                },
                {
                  "track_id": "file:42:subtitle:1",
                  "combined_index": 1,
                  "source": "embedded",
                  "codec": "ass",
                  "language": "eng",
                  "label": "English (Signs)",
                  "forced": true,
                  "default": false,
                  "hearing_impaired": false,
                  "delivery": "sidecar",
                  "url": "/api/v2/stream/11111111-1111-4111-8111-111111111111/subtitles/1.ass?file_id=42&embedded_stream_index=0",
                  "font_bundle_url": "/api/v2/stream/11111111-1111-4111-8111-111111111111/subtitles/1/fonts?file_id=42&embedded_stream_index=0"
                },
                {
                  "track_id": "file:42:subtitle:2",
                  "combined_index": 2,
                  "source": "embedded",
                  "codec": "pgs",
                  "language": "jpn",
                  "label": "Japanese",
                  "forced": false,
                  "default": false,
                  "hearing_impaired": false,
                  "delivery": "sidecar",
                  "url": "/api/v2/stream/11111111-1111-4111-8111-111111111111/subtitles/2.sup?file_id=42&embedded_stream_index=1"
                },
                {
                  "track_id": "file:42:subtitle:3",
                  "combined_index": 3,
                  "source": "embedded",
                  "codec": "dvd_subtitle",
                  "language": "fre",
                  "label": "French",
                  "forced": false,
                  "default": false,
                  "hearing_impaired": false,
                  "delivery": "burn_in_only"
                },
                {
                  "track_id": "file:42:subtitle:4",
                  "combined_index": 4,
                  "source": "downloaded",
                  "codec": "srt",
                  "language": "spa",
                  "label": "Spanish (downloaded)",
                  "forced": false,
                  "default": false,
                  "hearing_impaired": false,
                  "delivery": "sidecar",
                  "url": "/api/v2/stream/11111111-1111-4111-8111-111111111111/subtitles/4.vtt?file_id=42"
                }
              ]
            },
            "transformations": [],
            "applied_quirks": [],
            "runtime_corrections": [],
            "available_qualities": [
              {
                "label": "original",
                "height": 1080,
                "bitrate_kbps": 8000,
                "preserves_source": true
              }
            ],
            "degradation_warnings": [],
            "decision_reason": "validated_original_playback",
            "requested_media_file_id": "42",
            "effective_media_file_id": "42",
            "source": {
              "media_file_id": "42",
              "duration_seconds": 7200,
              "container": "mp4",
              "video_codec": "h264",
              "video_profile": "high",
              "video_level": 41,
              "bit_depth": 8,
              "width": 1920,
              "height": 1080,
              "frame_rate": 23.976023976023978,
              "bitrate_kbps": 8000,
              "dynamic_range": "sdr",
              "hdr10_plus": false,
              "dv_enhancement_layer": "none",
              "audio_codec": "aac",
              "audio_channels": 2,
              "audio_layout": "stereo"
            },
            "subtitle_fidelity_policy": "allow_simplified_rendering"
          }
        }
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try SiloAPICompatibility.response(Data(wire.utf8), path: "/api/v1/playback/start")
        let response = try decoder.decode(PlaybackV3DecisionResponse.self, from: data)
        XCTAssertEqual(response.nativeApiMajor, 2)
        guard case .playable(let plan, _) = response.validatedForApple() else { return XCTFail("Expected a playable native v2 decision") }
        XCTAssertEqual(plan.nativeApiMajor, 2)
        XCTAssertEqual(plan.effectiveMediaFileId, 42)
        XCTAssertEqual(plan.requestedMediaFileId, 42)
        XCTAssertEqual(plan.source.mediaFileId, 42)
        XCTAssertTrue(plan.stream.url.hasPrefix("/api/v2/stream/"))
    }

    func testDiscoveryDistinguishesOldAndNewServersAndNeverSendsCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloDiscoveryStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let discovery = SiloAPIDiscovery()
        let modern = try await discovery.usesV2(for: URL(string: "https://modern.example/silo/api/v1/auth/setup")!, session: session)
        let legacy = try await discovery.usesV2(for: URL(string: "https://legacy.example/silo/api/v1/auth/setup")!, session: session)
        XCTAssertTrue(modern)
        XCTAssertFalse(legacy)
        do {
            _ = try await discovery.usesV2(for: URL(string: "https://unavailable.example/silo/api/v1/auth/setup")!, session: session)
            XCTFail("A service failure must not select the legacy API")
        } catch {}
    }
}

private final class SiloDiscoveryStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/silo/api/v2/system/info")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Token"))
        let status = request.url?.host == "modern.example" ? 200 : request.url?.host == "legacy.example" ? 404 : 503
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"api_major":2}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
