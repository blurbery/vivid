import XCTest
@testable import Vivid

final class DownloadQualityTransferTests: XCTestCase {
    /// A transfer that finishes after a server or profile switch is matched
    /// by its tag, so it must round-trip exactly and ignore anything else.
    func testTransferTagRoundTripsAndIgnoresOtherDescriptions() throws {
        let tag = DownloadTaskTag(serverId: "emby:abc", profileId: "user-1", recordId: "emby-123")
        let parsed = try XCTUnwrap(DownloadTaskTag(taskDescription: tag.taskDescription))
        XCTAssertEqual(parsed, tag)
        XCTAssertTrue(parsed.isScope(serverId: "emby:abc", profileId: "user-1"))
        XCTAssertFalse(parsed.isScope(serverId: "silo-1", profileId: "user-1"))
        XCTAssertFalse(parsed.isScope(serverId: "emby:abc", profileId: "user-2"))
        for description in [nil, "", "media", "vivid-download-v1\nserver\nprofile", "other\nserver\nprofile\nrecord",
                            "vivid-download-v1\n\nprofile\nrecord"] as [String?] {
            XCTAssertNil(DownloadTaskTag(taskDescription: description))
        }
    }

    /// Silo advertises `bulk_quality` when season and series downloads take
    /// a smaller quality; servers that don't send it keep batches original.
    func testCapabilityReadsBulkQualityAndDefaultsToOff() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let withBulk = try decoder.decode(DownloadCapability.self, from: Data("""
        {"enabled":true,"download_allowed":true,"quality_presets":["original","10mbps"],"bulk_quality":true}
        """.utf8))
        XCTAssertTrue(withBulk.bulkQuality)
        let without = try decoder.decode(DownloadCapability.self, from: Data("""
        {"enabled":true,"download_allowed":true,"quality_presets":["original","10mbps"]}
        """.utf8))
        XCTAssertFalse(without.bulkQuality)
        let stored = try JSONDecoder().decode(DownloadCapability.self, from: JSONEncoder().encode(withBulk))
        XCTAssertTrue(stored.bulkQuality, "The flag survives the on-device store")
        XCTAssertFalse(DownloadCapability.unsupported.isUsable)
    }

    func testStreamedTranscodeNeedsDownloadAndPlaybackTranscodePermissions() {
        XCTAssertTrue(StreamedTranscodeDownload.isAllowed(policy: ["EnableContentDownloading": true]))
        XCTAssertTrue(StreamedTranscodeDownload.isAllowed(policy: ["EnableContentDownloading": true, "EnableVideoPlaybackTranscoding": true]))
        XCTAssertFalse(StreamedTranscodeDownload.isAllowed(policy: ["EnableContentDownloading": true, "EnableVideoPlaybackTranscoding": false]))
        XCTAssertFalse(StreamedTranscodeDownload.isAllowed(policy: ["EnableContentDownloading": false, "EnableVideoPlaybackTranscoding": true]))
        XCTAssertFalse(StreamedTranscodeDownload.isAllowed(policy: [:]))
    }

    func testStreamedTranscodeQueryCapsBitrateAndHeight() throws {
        let query = try XCTUnwrap(StreamedTranscodeDownload.query(format: .twoMbps, sourceID: "source-1", audioStreamIndex: 3, deviceID: "device-1"))
        XCTAssertEqual(query["Static"], "false")
        XCTAssertEqual(query["Container"], "mp4")
        XCTAssertEqual(query["VideoCodec"], "h264")
        XCTAssertEqual(query["AudioCodec"], "aac")
        XCTAssertEqual(query["VideoBitrate"], "2000000")
        XCTAssertEqual(query["AudioBitrate"], "128000")
        XCTAssertEqual(query["MaxHeight"], "720")
        XCTAssertEqual(query["MaxAudioChannels"], "2")
        XCTAssertEqual(query["MediaSourceId"], "source-1")
        XCTAssertEqual(query["AudioStreamIndex"], "3")
        XCTAssertEqual(query["DeviceId"], "device-1")
        let again = try XCTUnwrap(StreamedTranscodeDownload.query(format: .twoMbps, sourceID: "source-1", audioStreamIndex: nil, deviceID: "device-1"))
        XCTAssertNotEqual(query["PlaySessionId"], again["PlaySessionId"], "A retry never joins an abandoned transcode")
        XCTAssertNil(again["AudioStreamIndex"])
        XCTAssertNil(StreamedTranscodeDownload.query(format: .original, sourceID: "source-1", audioStreamIndex: nil, deviceID: "device-1"))
        XCTAssertEqual(StreamedTranscodeDownload.maxHeight(.twentyMbps), 1080)
        XCTAssertEqual(StreamedTranscodeDownload.maxHeight(.oneMbps), 480)
    }

    func testStreamedTranscodeDescribesTheSmallerFile() throws {
        let manifest: [String: Any] = [
            "quality": "original", "container": "mkv", "codecVideo": "hevc", "codecAudio": "truehd", "hdr": true,
            "resolution": "2160p", "durationSeconds": 3600.0, "fileSize": 40_000_000_000,
            "selectedAudioTrackIndex": 1,
            "audioTracks": [["index": 0, "codec": "eac3", "language": "fra", "channels": 6],
                            ["index": 1, "codec": "truehd", "language": "eng", "channels": 8]]
        ]
        let row: [String: Any] = ["id": "jellyfin-1", "quality": "10mbps", "fileSize": 40_000_000_000, "status": "ready"]
        var entry: [String: Any] = ["manifest": manifest, "row": row, "itemID": "movie-1", "sourceID": "source-1"]
        StreamedTranscodeDownload.apply(.tenMbps, to: &entry, source: ["DefaultAudioStreamIndex": 4])

        let expectedSize = Int64((10_000 + 192) * 1000 / 8 * 3600)
        let rewritten = try XCTUnwrap(entry["manifest"] as? [String: Any])
        XCTAssertEqual(rewritten["quality"] as? String, "10mbps")
        XCTAssertEqual(rewritten["effectiveQuality"] as? String, "10mbps")
        XCTAssertEqual(rewritten["container"] as? String, "mp4")
        XCTAssertEqual(rewritten["codecVideo"] as? String, "h264")
        XCTAssertEqual(rewritten["codecAudio"] as? String, "aac")
        XCTAssertEqual(rewritten["hdr"] as? Bool, false)
        XCTAssertEqual(rewritten["resolution"] as? String, "1080p")
        XCTAssertEqual(rewritten["fileSize"] as? Int64, expectedSize)
        XCTAssertEqual(rewritten["targetBitrateKbps"] as? Int, 10_000)
        let tracks = try XCTUnwrap(rewritten["audioTracks"] as? [[String: Any]])
        XCTAssertEqual(tracks.count, 1, "The transcode carries one audio track")
        XCTAssertEqual(tracks[0]["language"] as? String, "eng", "It is the selected track")
        XCTAssertEqual(tracks[0]["index"] as? Int, 0)
        XCTAssertEqual(tracks[0]["channels"] as? Int, 2)
        XCTAssertEqual(rewritten["selectedAudioTrackIndex"] as? Int, 0)

        let rewrittenRow = try XCTUnwrap(entry["row"] as? [String: Any])
        XCTAssertEqual(rewrittenRow["quality"] as? String, "10mbps")
        XCTAssertEqual(rewrittenRow["deliveryFormat"] as? String, "mp4")
        XCTAssertEqual(rewrittenRow["fileSize"] as? Int64, expectedSize)
        XCTAssertEqual(StreamedTranscodeDownload.format(of: entry), .tenMbps)
        XCTAssertEqual(entry["audioStreamIndex"] as? Int, 4)

        // A source already at or under the cap keeps its resolution label.
        var small: [String: Any] = ["manifest": ["resolution": "720p", "durationSeconds": 60.0], "row": [:]]
        StreamedTranscodeDownload.apply(.tenMbps, to: &small, source: [:])
        XCTAssertEqual((small["manifest"] as? [String: Any])?["resolution"] as? String, "720p")

        var original: [String: Any] = ["manifest": manifest, "row": row]
        StreamedTranscodeDownload.apply(.original, to: &original, source: [:])
        XCTAssertNil(StreamedTranscodeDownload.format(of: original))
        XCTAssertEqual((original["manifest"] as? [String: Any])?["container"] as? String, "mkv")
    }
}
