import XCTest
@testable import Vivid

/// On Silo, the audio and subtitle defaults on a title come from Vivid's own
/// per-series memory, never from Silo's profile or its apps' choices.
final class SiloLocalTrackPreferencesTests: XCTestCase {

    private static let siloResponse: [String: Any] = [
        "content_id": "episode-1",
        "series_id": "series-1",
        "effective_subtitle_language": "fr",
        "effective_subtitle_mode": "always",
        "effective_show_forced_subtitles": false,
        "effective_subtitle_track_signature": ["language": "fr", "forced": false, "hearing_impaired": false],
        "versions": [[
            "file_id": 7,
            "audio_tracks": [["language": "eng"], ["language": "jpn"], ["language": "jpn"]],
            "effective_audio_track_index": 0,
            "effective_audio_language": "eng",
        ]],
    ]

    func testSilosDefaultsAreRemovedWhenNothingIsRememberedHere() throws {
        let result = SiloLocalTrackPreferences.applying(subtitle: [:], audio: [:], to: Self.siloResponse)

        for field in [
            "effective_subtitle_language", "effective_subtitle_mode",
            "effective_show_forced_subtitles", "effective_subtitle_track_signature",
        ] {
            XCTAssertNil(result[field], field)
        }
        let version = try XCTUnwrap((result["versions"] as? [[String: Any]])?.first)
        XCTAssertNil(version["effective_audio_track_index"])
        XCTAssertNil(version["effective_audio_language"])
        // Everything else is left exactly as Silo sent it.
        XCTAssertEqual(result["content_id"] as? String, "episode-1")
        XCTAssertEqual(version["file_id"] as? Int, 7)
        XCTAssertEqual((version["audio_tracks"] as? [[String: Any]])?.count, 3)
    }

    func testRememberedChoicesReplaceSilosDefaults() throws {
        let result = SiloLocalTrackPreferences.applying(
            subtitle: [
                "subtitle_language": "en",
                "subtitle_mode": "auto",
                "show_forced_subtitles": true,
                "track_signature": ["language": "en", "forced": false, "hearing_impaired": true],
            ],
            audio: ["audio_language": "jpn", "audio_track_index": 2],
            to: Self.siloResponse
        )

        XCTAssertEqual(result["effective_subtitle_language"] as? String, "en")
        XCTAssertEqual(result["effective_subtitle_mode"] as? String, "auto")
        XCTAssertEqual(result["effective_show_forced_subtitles"] as? Bool, true)
        let version = try XCTUnwrap((result["versions"] as? [[String: Any]])?.first)
        XCTAssertEqual(version["effective_audio_track_index"] as? Int, 2)
        XCTAssertEqual(version["effective_audio_language"] as? String, "jpn")

        // A remembered track that's gone falls back to the first track in
        // that language.
        let moved = SiloLocalTrackPreferences.applying(
            subtitle: [:],
            audio: ["audio_language": "jpn", "audio_track_index": 9],
            to: Self.siloResponse
        )
        let movedVersion = try XCTUnwrap((moved["versions"] as? [[String: Any]])?.first)
        XCTAssertEqual(movedVersion["effective_audio_track_index"] as? Int, 1)
    }

    func testRewrittenDetailsDecodeWithVividsChoice() async throws {
        let store = SiloLocalTrackPreferences(defaults: try makeDefaults())
        try await store.save(
            .subtitle,
            key: "series-1",
            body: SubtitlePrefRequest(
                subtitleLanguage: "en",
                subtitleTrackIndex: 3,
                externalSubtitlePath: "",
                subtitleMode: "always",
                trackSignature: SubtitleTrackSignature(language: "en", hearingImpaired: true),
                showForcedSubtitles: false
            ),
            serverId: "silo",
            profileId: "profile"
        )
        let data = try JSONSerialization.data(withJSONObject: Self.siloResponse)

        let rewritten = try await store.rewrite(data, serverId: "silo", profileId: "profile")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])

        XCTAssertEqual(object["effective_subtitle_mode"] as? String, "always")
        let signature = try HTTPClient.makeJSONDecoder().decode(
            SubtitleTrackSignature.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["effective_subtitle_track_signature"]))
        )
        XCTAssertEqual(signature.language, "en")
        XCTAssertTrue(signature.hearingImpaired)
        // Another profile on the same server has its own memory.
        let other = try await store.rewrite(data, serverId: "silo", profileId: "someone-else")
        let otherObject = try XCTUnwrap(JSONSerialization.jsonObject(with: other) as? [String: Any])
        XCTAssertNil(otherObject["effective_subtitle_mode"])
    }

    func testResponsesWithNothingToChangePassThroughUntouched() async throws {
        let defaults = try makeDefaults()
        let store = SiloLocalTrackPreferences(defaults: defaults)
        let data = Data(#"{"content_id":"movie-1","title":"A","versions":[{"file_id":1}]}"#.utf8)

        let untouched = try await store.rewrite(data, serverId: "silo", profileId: "profile")
        XCTAssertEqual(untouched, data)

        // Once something is remembered for the movie, it's applied even
        // though Silo sent no defaults of its own.
        try await store.save(
            .audio,
            key: "movie-1",
            body: AudioPrefRequest(audioTrackIndex: 0, audioLanguage: "eng", trackSignature: nil),
            serverId: "silo",
            profileId: "profile"
        )
        let movie = Data(#"{"content_id":"movie-1","versions":[{"file_id":1,"audio_tracks":[{"language":"eng"}]}]}"#.utf8)
        let applied = try await store.rewrite(movie, serverId: "silo", profileId: "profile")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: applied) as? [String: Any])
        let version = try XCTUnwrap((object["versions"] as? [[String: Any]])?.first)
        XCTAssertEqual(version["effective_audio_track_index"] as? Int, 0)

        // Clearing it restores the untouched path.
        await store.clear(.audio, key: "movie-1", serverId: "silo", profileId: "profile")
        let cleared = try await store.rewrite(data, serverId: "silo", profileId: "profile")
        XCTAssertEqual(cleared, data)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "silo-track-preferences-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return suite
    }
}
