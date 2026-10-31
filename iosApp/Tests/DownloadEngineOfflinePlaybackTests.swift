import XCTest
@testable import Vivid

/// A saved manifest becomes the player's prepared playback: local subtitle
/// files, audio tracks, the starting track and the bitrate.
@MainActor
final class DownloadEngineOfflinePlaybackTests: XCTestCase {
    private static let surround: [String: Any] = [
        "index": 0, "title": "Surround 5.1", "language": "eng", "codec": "eac3", "layout": "5.1(side)",
        "channels": 6, "bitrate": 640_000, "sample_rate": 48_000, "default": true,
    ]

    /// The fixture manifest with `changes` applied; a nil value removes the key.
    private func manifest(_ changes: [String: Any?] = [:]) throws -> OfflineManifest {
        var fields: [String: Any] = [
            "download_id": "d1", "content_id": "c1", "type": "episode", "title": "Test Episode",
            "quality": "original", "media_file_id": 42, "container": "mkv", "codec_video": "hevc",
            "codec_audio": "eac3", "file_size": 1_000_000_000, "duration_seconds": 1358.176,
        ]
        for (key, value) in changes { fields[key] = value }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OfflineManifest.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func playback(_ manifest: OfflineManifest, sidecars: [SubtitleUrl] = [], manual: Int? = nil,
                          viewing: String? = nil, settings: String? = nil) -> PreparedPlayback {
        OfflinePlaybackBuilder.preparedPlayback(
            manifest: manifest, leafId: "leaf", mediaURL: URL(fileURLWithPath: "/tmp/media.mkv"), sidecars: sidecars,
            resumePosition: nil, preferredAudioTrackIndex: manual, viewingAudioLanguage: viewing, audioLanguage: settings
        )
    }

    // MARK: Subtitles

    func testSavedSubtitleFilesBecomeLocalSidecars() throws {
        let base = "/api/v2/downloads/d1/subtitles/"
        let emby = "https://media.example.com/emby/Videos/1/ms/Subtitles/"
        let subtitles: [[String: Any]] = [
            ["language": "en", "title": "English", "format": "subrip", "external": true, "fetch_url": base + "external:0"],
            ["language": "fr", "format": "pgs", "fetch_url": base + "embedded:1"],
            ["language": "de", "format": "ass", "fetch_url": base + "embedded:2"],
            ["language": "es", "format": "vtt", "fetch_url": base + "downloaded:7"],
            ["language": "it", "format": "srt", "external": true, "index": 9, "title": "Italian (SRT)", "is_default": true,
             "fetch_url": emby + "9/Stream.srt"],
            ["language": "pt", "format": "srt", "external": true, "fetch_url": emby + "11/Stream.srt"],
        ]
        let manifest = try manifest(["subtitles": subtitles])
        XCTAssertEqual(DownloadEngine.SubtitleFiles.savable(in: manifest).map(\.position), [0, 3, 4, 5],
                       "The bitmap format and the embedded tracks aren't saved")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["subtitle-0.srt", "subtitle-3.vtt", "subtitle-4.srt"] {
            try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        let saved = [
            base + "external:0": "subtitle-0.srt", base + "downloaded:7": "subtitle-3.vtt",
            emby + "9/Stream.srt": "subtitle-4.srt", emby + "11/Stream.srt": "subtitle-5.srt",
        ]
        let sidecars = OfflinePlaybackBuilder.sidecars(for: manifest, savedFiles: saved) {
            folder.appendingPathComponent($0)
        }
        XCTAssertEqual(sidecars.map(\.index), [0, 3, 9], "Silo uses the list position, Emby and Jellyfin their stream index")
        XCTAssertEqual(sidecars.map(\.codec), ["srt", "vtt", "srt"])
        XCTAssertEqual(sidecars.map(\.label), ["English", "External", "Italian (SRT)"])
        XCTAssertEqual(sidecars.map(\.language), ["en", "es", "it"])
        XCTAssertEqual(sidecars.map { $0.default }, [nil, nil, true])
        XCTAssertTrue(sidecars.allSatisfy { URL(string: $0.url)?.isFileURL == true })

        XCTAssertEqual(playback(manifest, sidecars: sidecars).session.subtitleUrls?.count, 3)
    }

    // MARK: Audio

    func testTheTrackOrdinalIsNotPassedOnAsAStreamIndex() throws {
        let version = playback(try manifest(["audio_tracks": [Self.surround]])).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)
        XCTAssertNil(track.index)
    }

    func testAudioDetailSurvives() throws {
        let track = try XCTUnwrap(playback(try manifest(["audio_tracks": [Self.surround]])).selectedVersion.audioTracks?.first)
        XCTAssertEqual(track.codec, "eac3")
        XCTAssertEqual(track.language, "eng")
        XCTAssertEqual(track.channels, 6)
        XCTAssertEqual(track.title, "Surround 5.1")
        XCTAssertEqual(track.channelLayout, "5.1(side)")
        XCTAssertEqual(track.bitrate, 640_000)
        XCTAssertEqual(track.sampleRate, 48_000)
        XCTAssertEqual(track.isDefault, true)
    }

    func testTheEmbeddedTitleIsNotInvented() throws {
        let track = try XCTUnwrap(playback(try manifest(["audio_tracks": [Self.surround]])).selectedVersion.audioTracks?.first)
        XCTAssertNil(track.embeddedTitle)
    }

    func testNoAudioListStaysAbsent() throws {
        XCTAssertNil(playback(try manifest()).selectedVersion.audioTracks, "Absent, not empty")
    }

    func testTheSelectedTrackReachesTheSession() throws {
        let manifest = try manifest(["audio_tracks": [Self.surround], "selected_audio_track_index": 0])
        XCTAssertEqual(playback(manifest).session.audioTrackIndex, 0)
    }

    func testAudioFollowsTheAudioSettings() throws {
        let tracks: [[String: Any]] = [
            ["index": 0, "language": "eng", "codec": "truehd", "channels": 8, "default": true],
            ["index": 1, "language": "eng", "codec": "eac3", "channels": 6],
            ["index": 2, "language": "jpn", "codec": "eac3", "channels": 6],
        ]
        let manifest = try manifest(["audio_tracks": tracks, "selected_audio_track_index": 2])
        XCTAssertEqual(playback(manifest, settings: "en").session.audioTrackIndex, 1, "English the device plays directly")
        XCTAssertEqual(playback(manifest, settings: "ja").session.audioTrackIndex, 2)
        XCTAssertEqual(playback(manifest, manual: 0, settings: "ja").session.audioTrackIndex, 0, "A pick wins")
        XCTAssertEqual(playback(manifest, viewing: "jpn", settings: "en").session.audioTrackIndex, 2)
        XCTAssertEqual(playback(manifest).session.audioTrackIndex, 2, "Without a Settings language the manifest's choice stands")
    }

    // MARK: Bitrate

    func testBitrateComesFromTheDeliveredFile() throws {
        XCTAssertEqual(playback(try manifest()).selectedVersion.bitrate, 5_890)
    }

    func testTargetBitrateIsTheFallback() throws {
        let manifest = try manifest(["target_bitrate_kbps": 4_000, "duration_seconds": 0])
        XCTAssertEqual(playback(manifest).selectedVersion.bitrate, 4_000)
    }

    func testASubSecondDurationDoesNotTrap() throws {
        XCTAssertNil(playback(try manifest(["duration_seconds": 0.000001])).selectedVersion.bitrate)
    }

    func testNoSizeAndNoDurationGiveNoBitrate() throws {
        XCTAssertNil(playback(try manifest(["file_size": nil, "duration_seconds": nil])).selectedVersion.bitrate)
    }
}
