import XCTest
import Foundation
@testable import Vivid

/// Contract coverage for the offline manifest → player metadata mapping in
/// `OfflinePlaybackBuilder`.
///
/// The manifest's `index` is the ordinal within its own audio list, while
/// `AudioTrack.index` means a source stream identifier. VividEngine probes
/// the delivered file and maps the ordinal at load time. These tests lock down
/// the stored-manifest boundary and decode through the same
/// `.convertFromSnakeCase` strategy the API client uses.
final class OfflinePlaybackMappingTests: XCTestCase {

    // MARK: - Factories

    private func manifest(
        audioTracksJSON: String? = nil,
        selectedAudioTrackIndex: Int? = nil,
        targetBitrateKbps: Int? = nil,
        fileSize: Int64? = 1_000_000_000,
        durationSeconds: Double? = 1358.176,
        subtitlesJSON: String? = nil
    ) throws -> OfflineManifest {
        var fields = [
            "\"download_id\": \"d1\"",
            "\"content_id\": \"c1\"",
            "\"type\": \"episode\"",
            "\"title\": \"Test Episode\"",
            "\"quality\": \"original\"",
            "\"media_file_id\": 42",
            "\"container\": \"mkv\"",
            "\"codec_video\": \"hevc\"",
            "\"codec_audio\": \"eac3\""
        ]
        if let fileSize { fields.append("\"file_size\": \(fileSize)") }
        if let durationSeconds { fields.append("\"duration_seconds\": \(durationSeconds)") }
        if let audioTracksJSON { fields.append("\"audio_tracks\": \(audioTracksJSON)") }
        if let subtitlesJSON { fields.append("\"subtitles\": \(subtitlesJSON)") }
        if let selectedAudioTrackIndex {
            fields.append("\"selected_audio_track_index\": \(selectedAudioTrackIndex)")
        }
        if let targetBitrateKbps {
            fields.append("\"target_bitrate_kbps\": \(targetBitrateKbps)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            OfflineManifest.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    private func prepared(_ manifest: OfflineManifest) -> PreparedPlayback {
        OfflinePlaybackBuilder.makePreparedPlayback(
            leafContentId: "leaf",
            manifest: manifest,
            mediaURL: URL(fileURLWithPath: "/tmp/media.mkv"),
            subtitleURLs: [],
            resumePosition: nil
        )
    }

    /// One 5.1 EAC-3 track, shaped exactly as the server writes it: `index` is
    /// the loop counter over the audio list, not the probed stream index.
    private let singleEAC3Track = """
    [{
      "index": 0,
      "title": "Surround 5.1",
      "language": "eng",
      "codec": "eac3",
      "layout": "5.1(side)",
      "channels": 6,
      "bitrate": 640000,
      "sample_rate": 48000,
      "default": true
    }]
    """

    // MARK: - Saved subtitle files

    func testSavedSubtitleFilesBecomeLocalSidecars() throws {
        let manifest = try manifest(subtitlesJSON: """
        [{"language": "en", "title": "English", "format": "subrip", "external": true, "fetch_url": "/api/v2/downloads/d1/subtitles/external:0"},
         {"language": "fr", "format": "pgs", "fetch_url": "/api/v2/downloads/d1/subtitles/embedded:1"},
         {"language": "de", "format": "ass", "fetch_url": "/api/v2/downloads/d1/subtitles/embedded:2"},
         {"language": "es", "format": "vtt", "fetch_url": "/api/v2/downloads/d1/subtitles/downloaded:7"},
         {"language": "it", "format": "srt", "external": true, "index": 9, "title": "Italian (SRT)", "fetch_url": "https://media.example.com/emby/Videos/1/ms/Subtitles/9/Stream.srt"},
         {"language": "pt", "format": "srt", "external": true, "fetch_url": "https://media.example.com/emby/Videos/1/ms/Subtitles/11/Stream.srt"}]
        """)
        // Embedded tracks are in the media file already, and PGS isn't text.
        XCTAssertEqual(OfflineSubtitleFiles.savable(manifest.subtitles ?? []).map(\.index), [0, 3, 4, 5])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["subtitle-0.srt", "subtitle-3.vtt", "subtitle-4.srt"] {
            try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        let filenames = [
            "/api/v2/downloads/d1/subtitles/external:0": "subtitle-0.srt",
            "/api/v2/downloads/d1/subtitles/downloaded:7": "subtitle-3.vtt",
            "https://media.example.com/emby/Videos/1/ms/Subtitles/9/Stream.srt": "subtitle-4.srt",
            // Recorded but missing on disk, so it isn't offered.
            "https://media.example.com/emby/Videos/1/ms/Subtitles/11/Stream.srt": "subtitle-5.srt",
        ]
        let sidecars = OfflineSubtitleFiles.sidecars(manifest: manifest, filenames: filenames) { directory.appendingPathComponent($0) }
        // Silo files use their manifest position; an Emby or Jellyfin file
        // keeps its server stream index, the ID it has when streaming.
        XCTAssertEqual(sidecars.map(\.index), [0, 3, 9])
        XCTAssertEqual(sidecars.map(\.codec), ["srt", "vtt", "srt"])
        XCTAssertEqual(sidecars.map(\.label), ["English", "External", "Italian (SRT)"])
        XCTAssertEqual(sidecars.map(\.language), ["en", "es", "it"])
        XCTAssertTrue(sidecars.allSatisfy { URL(string: $0.url)?.isFileURL == true })

        let session = OfflinePlaybackBuilder.makePreparedPlayback(leafContentId: "leaf", manifest: manifest,
            mediaURL: URL(fileURLWithPath: "/tmp/media.mkv"), subtitleURLs: sidecars, resumePosition: nil).session
        XCTAssertEqual(session.subtitleUrls?.count, 3)
    }

    // MARK: - Audio track identity

    func testManifestOrdinalIsNotForwardedAsAStreamIndex() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        // The manifest said `index: 0`. Forwarding it would claim the audio
        // lives on stream 0, which on any normal file is the video stream.
        XCTAssertNil(track.index)
    }

    func testAudioTrackDetailSurvivesTheWire() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        XCTAssertEqual(track.codec, "eac3")
        XCTAssertEqual(track.language, "eng")
        XCTAssertEqual(track.channels, 6)
        XCTAssertEqual(track.title, "Surround 5.1")
        // `layout` feeds the detail badge; `sample_rate` only survives
        // `.convertFromSnakeCase` if the coding key
        // is spelled in its converted camelCase form.
        XCTAssertEqual(track.channelLayout, "5.1(side)")
        XCTAssertEqual(track.bitrate, 640_000)
        XCTAssertEqual(track.sampleRate, 48_000)
        XCTAssertEqual(track.isDefault, true)
    }

    func testEmbeddedTitleIsNotFabricated() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        // The server collapsed title and embedded title into one field. Echoing
        // the same string back as both would corrupt the audio-pref signature,
        // which compares them separately.
        XCTAssertNil(track.embeddedTitle)
    }

    func testAbsentAudioTracksStayAbsent() throws {
        let version = prepared(try manifest()).selectedVersion

        // Manifests written before the client decoded these fields carry no
        // audio list at all; they must degrade to nil rather than an empty
        // array that would claim the file has no audio.
        XCTAssertNil(version.audioTracks)
    }

    // MARK: - Selected track

    func testSelectedAudioTrackIndexReachesTheSession() throws {
        let session = prepared(try manifest(
            audioTracksJSON: singleEAC3Track,
            selectedAudioTrackIndex: 0
        )).session

        // Ordinal into `version.audioTracks` — the same space the server's
        // `audio_track_index` uses.
        XCTAssertEqual(session.audioTrackIndex, 0)
    }

    // MARK: - Bitrate

    func testBitrateIsDerivedFromTheDeliveredFile() throws {
        let version = prepared(try manifest()).selectedVersion

        // 1_000_000_000 bytes * 8 / 1358.176s / 1000 ≈ 5890 kbps.
        XCTAssertEqual(version.bitrate, 5890)
    }

    func testBitrateFallsBackToTargetWhenDurationIsUnusable() throws {
        let version = prepared(try manifest(
            targetBitrateKbps: 4000,
            durationSeconds: 0
        )).selectedVersion

        XCTAssertEqual(version.bitrate, 4000)
    }

    func testUnusableDurationDoesNotTrapOnConversion() throws {
        // A sub-second duration divides into a value `Int(_:)` traps on.
        // Nothing to assert beyond "this returned at all", plus that it did
        // not invent a bitrate from the corrupt pair.
        let version = prepared(try manifest(durationSeconds: 0.000_001)).selectedVersion

        XCTAssertNil(version.bitrate)
    }

    func testBitrateIsAbsentWhenTheManifestCannotSupportIt() throws {
        let version = prepared(try manifest(fileSize: nil, durationSeconds: nil)).selectedVersion

        XCTAssertNil(version.bitrate)
    }
}
