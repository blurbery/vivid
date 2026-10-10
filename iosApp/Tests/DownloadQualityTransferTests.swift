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

    /// Emby serves everything under /emby, and Foundation reports that base
    /// without a trailing slash, which used to reject every Emby image.
    func testServerAssetPathKeepsImagesOnTheAccountsServer() throws {
        let emby = try EmbyConnection.url(serverURL: "https://media.example.test", path: "/")
        XCTAssertEqual(ServerAssetPath.relative(URL(string: "https://media.example.test/emby/Items/1/Images/Primary?tag=a")!, base: emby),
                       "/Items/1/Images/Primary")
        let root = URL(string: "https://media.example.test/")!
        XCTAssertEqual(ServerAssetPath.relative(URL(string: "https://media.example.test/Items/1/Images/Primary")!, base: root),
                       "/Items/1/Images/Primary")
        let nested = URL(string: "https://media.example.test/jellyfin/")!
        XCTAssertEqual(ServerAssetPath.relative(URL(string: "https://MEDIA.example.test/jellyfin/Videos/1/stream")!, base: nested),
                       "/Videos/1/stream")
        for other in ["https://other.example.test/emby/Items/1/Images/Primary", "http://media.example.test/emby/Items/1/Images/Primary",
                      "https://media.example.test/embyx/Items/1/Images/Primary", "https://media.example.test/emby/Users/1",
                      "https://user:pass@media.example.test/emby/Items/1/Images/Primary", "https://media.example.test:8443/emby/Items/1"] {
            XCTAssertNil(ServerAssetPath.relative(URL(string: other)!, base: emby), other)
        }
    }

    /// Each choice names the resolution its bitrate brings the file down to,
    /// from the server's own description when it gives one (Silo).
    func testQualityLabelsNameTheResolution() throws {
        XCTAssertEqual(DownloadFormat.twentyMbps.qualityLabel(maxHeight: nil), "4K · 20 Mbps")
        XCTAssertEqual(DownloadFormat.tenMbps.qualityLabel(maxHeight: nil), "1080p · 10 Mbps")
        XCTAssertEqual(DownloadFormat.fiveMbps.qualityLabel(maxHeight: nil), "1080p · 5 Mbps")
        XCTAssertEqual(DownloadFormat.twoMbps.qualityLabel(maxHeight: nil), "720p · 2 Mbps")
        XCTAssertEqual(DownloadFormat.oneMbps.qualityLabel(maxHeight: nil), "480p · 1 Mbps")
        XCTAssertEqual(DownloadFormat.original.qualityLabel(maxHeight: 2160), "Original")
        // A Silo server without 4K transcoding reports 1080p for 20 Mbps.
        XCTAssertEqual(DownloadFormat.twentyMbps.qualityLabel(maxHeight: 1080), "1080p · 20 Mbps")

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let capability = try decoder.decode(DownloadCapability.self, from: Data("""
        {"enabled":true,"download_allowed":true,"quality_presets":["original","20mbps"],
         "quality_options":[{"preset":"original"},{"preset":"20mbps","bitrate_kbps":20000,"max_height":1080}]}
        """.utf8))
        XCTAssertEqual(capability.qualityOptions.first { $0.preset == "20mbps" }?.maxHeight, 1080)
        let stored = try JSONDecoder().decode(DownloadCapability.self, from: JSONEncoder().encode(capability))
        XCTAssertEqual(stored.qualityOptions, capability.qualityOptions)
    }

    /// The Live Activity animates from where the bar is now to the estimated
    /// finish, so it keeps moving while Vivid is suspended.
    func testLiveActivityTimelineStartsAtTheCurrentProgress() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let range = try XCTUnwrap(DownloadLiveActivityController.timeline(
            fraction: 0.25, remainingBytes: 600_000_000, bytesPerSecond: 1_000_000, now: now))
        XCTAssertEqual(range.upperBound.timeIntervalSince(now), 600, accuracy: 5)
        XCTAssertEqual(range.lowerBound.timeIntervalSince(now), -200, accuracy: 5)
        XCTAssertNil(DownloadLiveActivityController.timeline(fraction: 0.5, remainingBytes: 0, bytesPerSecond: 1_000, now: now))
        XCTAssertNil(DownloadLiveActivityController.timeline(fraction: 0.5, remainingBytes: 1_000, bytesPerSecond: 0, now: now))
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
        XCTAssertEqual(StreamedTranscodeDownload.maxHeight(.twentyMbps), 2160)
        XCTAssertEqual(StreamedTranscodeDownload.maxHeight(.tenMbps), 1080)
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

    /// Silo reports how far it has got preparing a download. A malformed
    /// report must never fail the row it's attached to.
    func testSiloPreparationDecodesAndDescribesProgress() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func row(_ preparation: String) throws -> ServerDownloadRow {
            try decoder.decode(ServerDownloadRow.self, from: Data("""
            {"id":"d1","content_id":"c1","media_file_id":7,"status":"preparing","quality":"2mbps"\(preparation)}
            """.utf8))
        }
        let running = try XCTUnwrap(row(#","preparation":{"state":"running","progress":0.654,"remaining_seconds":250}"#).preparation)
        XCTAssertEqual(running.statusText, "Preparing on server · 65% · 4 min left")
        let queued = try XCTUnwrap(row(#","preparation":{"state":"queued","queue_position":2}"#).preparation)
        XCTAssertEqual(queued.queuePosition, 2)
        XCTAssertTrue(queued.statusText.hasPrefix("Waiting on server · "))
        XCTAssertEqual(try XCTUnwrap(row(#","preparation":{"state":"running"}"#).preparation).statusText, "Preparing on server…")
        XCTAssertNil(try row("").preparation)
        XCTAssertNil(try row(#","preparation":{"progress":"half"}"#).preparation)
        let stored = try JSONDecoder().decode(DownloadPreparationStatus.self, from: JSONEncoder().encode(running))
        XCTAssertEqual(stored, running, "The report survives the on-device store")
    }

    /// While Silo prepares a smaller quality it reports the source file's
    /// size, which must not be shown; the prepared file's size replaces it
    /// once ready, until bytes arrive. Other servers keep their first size.
    func testSiloDownloadSizeFollowsThePreparedFile() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func row(status: String, quality: String, size: Int64) throws -> ServerDownloadRow {
            try decoder.decode(ServerDownloadRow.self, from: Data("""
            {"id":"d1","content_id":"c1","media_file_id":7,"status":"\(status)","quality":"\(quality)","file_size":\(size)}
            """.utf8))
        }
        let source: Int64 = 7_300_000_000
        let prepared: Int64 = 800_000_000
        let preparing = try row(status: "preparing", quality: "2mbps", size: source)
        XCTAssertNil(DownloadManager.serverFileSize(preparing, provider: .silo, currentSize: 0, bytesDownloaded: 0, localStatus: .registering))
        XCTAssertNil(DownloadManager.serverFileSize(preparing, provider: .silo, currentSize: 900_000_000, bytesDownloaded: 0, localStatus: .preparing))
        let ready = try row(status: "ready", quality: "2mbps", size: prepared)
        XCTAssertEqual(DownloadManager.serverFileSize(ready, provider: .silo, currentSize: 900_000_000, bytesDownloaded: 0, localStatus: .preparing), prepared)
        XCTAssertNil(DownloadManager.serverFileSize(ready, provider: .silo, currentSize: prepared, bytesDownloaded: 1, localStatus: .downloading))
        let original = try row(status: "preparing", quality: "original", size: source)
        XCTAssertEqual(DownloadManager.serverFileSize(original, provider: .silo, currentSize: 0, bytesDownloaded: 0, localStatus: .registering), source)
        XCTAssertNil(DownloadManager.serverFileSize(ready, provider: .emby, currentSize: 900_000_000, bytesDownloaded: 0, localStatus: .queued))
        XCTAssertEqual(DownloadManager.serverFileSize(ready, provider: .jellyfin, currentSize: 0, bytesDownloaded: 0, localStatus: .queued), prepared)
    }

    /// Versions are matched by resolution class, whatever spelling the
    /// server uses: Silo's "2160p", Emby's and Jellyfin's heights, or "4K".
    func testVersionClassesAcceptEachServersResolution() {
        let cases: [(String?, Int?)] = [("2160p", 2160), ("4K", 2160), ("uhd", 2160), ("1920x1080", 1080), ("1080", 1080),
                                        ("720p", 720), ("576p", 480), ("480p", 480), (nil, nil), ("", nil), ("unknown", nil)]
        for (resolution, height) in cases {
            XCTAssertEqual(DownloadVersionPreference.heightClass(of: resolution), height, "\(resolution ?? "nil")")
        }
    }

    /// Versions list one per class, highest first, and only tell HDR apart
    /// where a class has both.
    func testVersionOptionsComeFromTheEpisodesFiles() throws {
        func file(_ id: Int, _ resolution: String?, hdr: Bool?) -> EpisodeFile {
            EpisodeFile(fileId: id, resolution: resolution, codecVideo: nil, hdr: hdr, audioChannels: nil, container: nil, fileSize: nil)
        }
        let files = [file(1, "1080p", hdr: false), file(2, "2160p", hdr: true), file(3, "2160p", hdr: false),
                     file(4, "1080p", hdr: nil), file(5, "720p", hdr: nil), file(6, nil, hdr: true)]
        let options = DownloadVersionPreference.options(for: files)
        XCTAssertEqual(options.map(\.label), ["4K HDR", "4K", "1080p", "720p"])
    }

    /// A 4K version only offers 4K transcodes; a smaller one offers the
    /// ladder below it; Auto offers everything. Silo's own heights count.
    func testQualitiesFollowTheChosenVersion() {
        let all = DownloadFormat.allCases
        let ladder: (DownloadFormat) -> Int? = { $0.ladderMaxHeight }
        func offered(_ height: Int?, maxHeight: ((DownloadFormat) -> Int?)? = nil) -> [String] {
            DownloadVersionPreference.formats(all, versionHeight: height, maxHeight: maxHeight ?? ladder).map(\.rawValue)
        }
        XCTAssertEqual(offered(nil), all.map(\.rawValue))
        XCTAssertEqual(offered(2160), ["original", "20mbps"])
        XCTAssertEqual(offered(1080), ["original", "10mbps", "5mbps", "2mbps", "1mbps"])
        XCTAssertEqual(offered(720), ["original", "2mbps", "1mbps"])
        XCTAssertEqual(offered(480), ["original", "1mbps"])
        // A server that caps 20 Mbps at 1080p has no 4K transcode to offer.
        let capped: (DownloadFormat) -> Int? = { $0 == .twentyMbps ? 1080 : $0.ladderMaxHeight }
        XCTAssertEqual(offered(2160, maxHeight: capped), ["original"])
        XCTAssertEqual(offered(1080, maxHeight: capped), ["original", "20mbps", "10mbps", "5mbps", "2mbps", "1mbps"])
    }

    /// Season and series versions are named like a movie's, with how many
    /// episodes have one and roughly how much they'd download.
    func testSeriesVersionsCountTheirEpisodes() {
        func episode(_ number: Int, _ files: [EpisodeFile]?) -> EpisodeListItem {
            EpisodeListItem(contentId: "e\(number)", seasonNumber: 1, episodeNumber: number, title: nil, overview: nil, airDate: nil,
                            runtime: nil, imdbId: nil, tmdbId: nil, tvdbId: nil, stillUrl: nil, stillThumbhash: nil, userData: nil, files: files)
        }
        func file(_ id: Int, _ resolution: String, _ codec: String, hdr: Bool, size: Int64) -> EpisodeFile {
            EpisodeFile(fileId: id, resolution: resolution, codecVideo: codec, hdr: hdr, audioChannels: nil, container: nil, fileSize: size)
        }
        let gb: Int64 = 1_000_000_000
        let versions = SeriesDownloadVersion.versions(in: [
            episode(1, [file(1, "2160p", "hevc", hdr: true, size: 10 * gb), file(2, "1080p", "h264", hdr: false, size: 5 * gb)]),
            episode(2, [file(3, "2160p", "hevc", hdr: true, size: 10 * gb), file(4, "1080p", "hevc", hdr: false, size: 4 * gb)]),
            episode(3, [file(5, "2160p", "hevc", hdr: true, size: 10 * gb)]),
            episode(4, []),
            episode(5, nil),
        ])
        XCTAssertEqual(versions.map(\.title), ["2160p · HEVC · HDR", "1080p"])
        XCTAssertEqual(versions.map(\.episodes), [3, 2])
        XCTAssertEqual(versions.map(\.totalEpisodes), [3, 3])
        XCTAssertEqual(versions.map(\.bytes), [30 * gb, 9 * gb])
        XCTAssertTrue(versions[0].detail.hasPrefix("All 3 episodes · about "))
        XCTAssertTrue(versions[1].detail.hasPrefix("2 of 3 episodes · about "))
        XCTAssertEqual(SeriesDownloadVersion.rowDetail(versions, chosen: nil), "Auto · 2160p · HEVC · HDR, 1080p")
        XCTAssertTrue(SeriesDownloadVersion.rowDetail(versions, chosen: versions[1].version).hasPrefix("1080p · 2 of 3 episodes"))
    }

    /// Each episode gets the file with the same class and HDR, then the same
    /// class either way; without one the server picks.
    func testVersionMatchingFallsBackWithinTheClassThenToTheServer() {
        func file(_ id: Int, _ resolution: String, hdr: Bool) -> EpisodeFile {
            EpisodeFile(fileId: id, resolution: resolution, codecVideo: nil, hdr: hdr, audioChannels: nil, container: nil, fileSize: nil)
        }
        let sdr4K = DownloadVersionPreference(height: 2160, hdr: false)
        XCTAssertEqual(sdr4K.file(in: [file(1, "2160p", hdr: true), file(2, "2160p", hdr: false)])?.fileId, 2)
        XCTAssertEqual(sdr4K.file(in: [file(1, "2160p", hdr: true), file(3, "1080p", hdr: false)])?.fileId, 1)
        XCTAssertNil(DownloadVersionPreference(height: 720, hdr: nil).file(in: [file(1, "2160p", hdr: true)]))

        // A file that doesn't say whether it's HDR is neither: an SDR pick
        // takes the file known to be SDR, and it doesn't split the menu.
        let unknown = EpisodeFile(fileId: 4, resolution: "2160p", codecVideo: nil, hdr: nil, audioChannels: nil, container: nil, fileSize: nil)
        XCTAssertEqual(sdr4K.file(in: [file(1, "2160p", hdr: true), unknown, file(5, "2160p", hdr: false)])?.fileId, 5)
        XCTAssertEqual(sdr4K.file(in: [file(1, "2160p", hdr: true), unknown])?.fileId, 1)
        XCTAssertEqual(DownloadVersionPreference.options(for: [file(1, "2160p", hdr: true), unknown]).map(\.label), ["4K HDR"])
    }

    /// A list of episodes reports what wasn't added rather than failing whole.
    @MainActor
    func testEpisodeListReportsWhatWasNotAdded() {
        var result = DownloadManager.EpisodeRegistrationResult()
        result.added = 3
        XCTAssertNil(result.problem)
        result.failures = [DownloadError.emptyRegistrationResponse]
        XCTAssertEqual(result.problem, "1 episode couldn't be added: The server didn't create a download. 3 episodes were added.")
        var skippedOnly = DownloadManager.EpisodeRegistrationResult()
        skippedOnly.skipped = 2
        XCTAssertEqual(skippedOnly.problem, "Nothing new to add. These episodes are already downloaded, on their way, or don't have a file yet.")
        var switched = DownloadManager.EpisodeRegistrationResult()
        switched.added = 1
        switched.stoppedBySwitch = true
        XCTAssertEqual(switched.problem, "The server or profile changed, so the rest weren't added. 1 episode was added.")
    }
}
