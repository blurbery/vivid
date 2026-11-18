import XCTest
@testable import Vivid

/// Emby and Jellyfin streams for an AirPlay receiver: the fixed receiver
/// profile, and stream URLs that carry exactly one credential of the name
/// each server accepts, on the server's own origin.
final class AirPlayReceiverStreamTests: XCTestCase {
    private var session: URLSession?
    private let item = "22222222222222222222222222222222"
    private let source = "33333333333333333333333333333333"

    override func tearDown() {
        session?.invalidateAndCancel()
        session = nil
        AirPlayReceiverRequestStub.handler = nil
        super.tearDown()
    }

    // MARK: - Receiver profile

    private let hevcMP4: [String: Any] = [
        "Container": "mov,mp4,m4a,3gp,3g2,mj2",
        "MediaStreams": [["Type": "Video", "Codec": "hevc", "Width": 3_840, "Height": 2_160, "BitDepth": 10,
                          "VideoRange": "HDR", "VideoRangeType": "HDR10"]],
    ]

    private func bodies(source: [String: Any], audioIndex: Int? = nil, subtitleIndex: Int? = nil,
                        bitrateKbps: Int? = nil) -> [(String, [String: Any])] {
        [
            ("Emby", EmbyPlayback.airPlayPlaybackInfoBody(
                userID: "user", sourceID: "source", audioIndex: audioIndex, subtitleIndex: subtitleIndex,
                bitrateKbps: bitrateKbps, source: source)),
            ("Jellyfin", JellyfinPlayback.airPlayPlaybackInfoBody(
                userID: "user", sourceID: "source", audioIndex: audioIndex, subtitleIndex: subtitleIndex,
                bitrateKbps: bitrateKbps, source: source)),
        ]
    }

    func testReceiverProfileAsksOnlyForWhatAReceiverPlays() throws {
        for (core, body) in bodies(source: hevcMP4, audioIndex: 2, subtitleIndex: 5, bitrateKbps: 8_000) {
            XCTAssertEqual(body["UserId"] as? String, "user", core)
            XCTAssertEqual(body["MediaSourceId"] as? String, "source", core)
            XCTAssertEqual(body["StartTimeTicks"] as? Int, 0, "The receiver's player seeks, \(core)")
            XCTAssertEqual(body["AutoOpenLiveStream"] as? Bool, false, core)
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, true, core)
            XCTAssertEqual(body["EnableTranscoding"] as? Bool, true, core)
            XCTAssertNil(body["AllowVideoStreamCopy"], core)
            XCTAssertEqual(body["MaxStreamingBitrate"] as? Int, 8_000_000, core)
            XCTAssertEqual(body["AudioStreamIndex"] as? Int, 2, core)
            XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, 5, core)

            let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any], core)
            XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, 8_000_000, core)
            let direct = try XCTUnwrap((profile["DirectPlayProfiles"] as? [[String: Any]])?.first, core)
            XCTAssertEqual(direct["Container"] as? String, "mp4,m4v,mov", core)
            XCTAssertEqual(direct["VideoCodec"] as? String, "h264,hevc", core)
            XCTAssertEqual(direct["AudioCodec"] as? String, "aac,ac3,eac3,alac", core)

            let transcodes = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]], core)
            XCTAssertFalse(transcodes.isEmpty, core)
            for transcode in transcodes {
                XCTAssertEqual(transcode["Protocol"] as? String, "hls", core)
                XCTAssertEqual(transcode["AudioCodec"] as? String, "aac,ac3,eac3", core)
                XCTAssertEqual(transcode["MaxAudioChannels"] as? String, "6", core)
                XCTAssertEqual(transcode["Context"] as? String, "Streaming", core)
            }
            XCTAssertEqual(transcodes.last?["Container"] as? String, "ts", core)
            XCTAssertEqual(transcodes.last?["VideoCodec"] as? String, "h264", core)
            XCTAssertEqual(transcodes.last?["MaxWidth"] as? Int, 1_920, "H.264 stays at 1080p, \(core)")
            XCTAssertEqual(transcodes.last?["MaxHeight"] as? Int, 1_080, core)

            let codecs = try XCTUnwrap(profile["CodecProfiles"] as? [[String: Any]], core)
            XCTAssertEqual(condition(codecs, codec: nil, "Width"), "3840", core)
            XCTAssertEqual(condition(codecs, codec: nil, "Height"), "2160", core)
            XCTAssertEqual(condition(codecs, codec: "h264", "Width"), "1920", core)
            XCTAssertEqual(condition(codecs, codec: "h264", "Height"), "1080", core)
            XCTAssertNil(condition(codecs, codec: "hevc", "Width"), "HEVC may go to 2160p, \(core)")

            let subtitles = try XCTUnwrap(profile["SubtitleProfiles"] as? [[String: Any]], core)
            let methods = Dictionary(uniqueKeysWithValues: subtitles.compactMap { row in
                (row["Format"] as? String).map { ($0, row["Method"] as? String ?? "") }
            })
            for format in ["srt", "subrip", "ass", "ssa", "vtt", "mov_text"] {
                XCTAssertEqual(methods[format], "Hls", "\(core) \(format)")
            }
            for format in ["pgssub", "dvdsub", "dvbsub"] {
                XCTAssertEqual(methods[format], "Encode", "\(core) \(format)")
            }
            XCTAssertEqual(Set(methods.values), ["Hls", "Encode"], "No External or Embed rows, \(core)")
        }
    }

    func testJellyfinAsksForFragmentedMP4HLSBeforeTheMPEGTSFallback() throws {
        let body = JellyfinPlayback.airPlayPlaybackInfoBody(userID: "user", sourceID: "source", audioIndex: nil,
                                                            subtitleIndex: nil, bitrateKbps: nil, source: hevcMP4)
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        let transcodes = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]])
        XCTAssertEqual(transcodes.map { $0["Container"] as? String }, ["mp4", "ts"])
        XCTAssertEqual(transcodes.first?["VideoCodec"] as? String, "hevc,h264")
        XCTAssertEqual(transcodes.first?["BreakOnNonKeyFrames"] as? Bool, true)
        XCTAssertEqual(transcodes.first?["MinSegments"] as? Int, 2)
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, -1)
        XCTAssertNil(body["AudioStreamIndex"])
        XCTAssertNil(body["MaxStreamingBitrate"])
        XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, 200_000_000)

        let codecs = try XCTUnwrap(profile["CodecProfiles"] as? [[String: Any]])
        XCTAssertEqual(rangeTypes(codecs, codec: "hevc"), "SDR|HDR10|HLG")
        XCTAssertEqual(rangeTypes(codecs, codec: "h264"), "SDR")
        XCTAssertNil(transcodes.first?["MaxWidth"], "The HEVC-capable profile isn't capped at 1080p")

        let emby = EmbyPlayback.airPlayPlaybackInfoBody(userID: "user", sourceID: "source", audioIndex: nil,
                                                        subtitleIndex: nil, bitrateKbps: nil, source: hevcMP4)
        let embyProfile = try XCTUnwrap(emby["DeviceProfile"] as? [String: Any])
        XCTAssertEqual((embyProfile["TranscodingProfiles"] as? [[String: Any]])?.count, 1, "Emby's fMP4 HLS isn't verified")
        let embyCodecs = try XCTUnwrap(embyProfile["CodecProfiles"] as? [[String: Any]])
        XCTAssertNil(rangeTypes(embyCodecs, codec: "hevc"), "Emby doesn't define VideoRangeType")
    }

    /// Dolby Vision (any profile), HDR10+ and an unrecognised range are never
    /// copied to a receiver, and their transcode is H.264 only.
    func testDolbyVisionAndUnrecognisedHDRAreReEncodedAsH264() throws {
        let sources: [[String: Any]] = [
            ["Container": "mp4", "MediaStreams": [["Type": "Video", "Codec": "hevc", "VideoRangeType": "DOVIWithHDR10"]]],
            ["Container": "mp4", "MediaStreams": [["Type": "Video", "Codec": "hevc", "DvProfile": 7]]],
            ["Container": "mp4", "MediaStreams": [["Type": "Video", "Codec": "hevc", "VideoRangeType": "HDR10Plus"]]],
            ["Container": "mp4", "MediaStreams": [["Type": "Video", "Codec": "hevc", "ExtendedVideoType": "DolbyVision"]]],
            ["Container": "mp4", "MediaStreams": [["Type": "Video", "Codec": "hevc", "VideoRange": "HDR"]]],
        ]
        for source in sources {
            for (core, body) in bodies(source: source) {
                XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false, core)
                XCTAssertEqual(body["EnableDirectStream"] as? Bool, false, core)
                XCTAssertEqual(body["AllowVideoStreamCopy"] as? Bool, false, core)
                let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any], core)
                let transcodes = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]], core)
                XCTAssertEqual(Set(transcodes.compactMap { $0["VideoCodec"] as? String }), ["h264"], core)
                XCTAssertEqual(Set(transcodes.compactMap { $0["MaxWidth"] as? Int }), [1_920],
                               "A re-encode to H.264 is never 4K, \(core)")
                XCTAssertEqual(transcodes.compactMap { $0["MaxHeight"] as? Int }.count, transcodes.count, core)
                XCTAssertTrue(transcodes.allSatisfy { $0["MaxHeight"] as? Int == 1_080 }, core)
            }
        }
        let hlg: [String: Any] = ["Container": "mp4",
                                  "MediaStreams": [["Type": "Video", "Codec": "hevc", "VideoRangeType": "HLG"]]]
        for (core, body) in bodies(source: hlg) {
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, true, core)
            XCTAssertNil(body["AllowVideoStreamCopy"], core)
        }
    }

    func testMKVAndOtherCodecsNeverDirectPlayButMayStillBeRepackaged() {
        let sources: [[String: Any]] = [
            ["Container": "mkv", "MediaStreams": [["Type": "Video", "Codec": "h264", "VideoRange": "SDR"]]],
            ["Container": "mp4", "MediaStreams": [["Type": "Video", "Codec": "av1", "VideoRange": "SDR"]]],
            ["Container": "mp4", "MediaStreams": [["Type": "Video", "Codec": "hevc", "CodecTag": "hev1",
                                                   "VideoRange": "SDR"]]],
        ]
        for source in sources {
            for (core, body) in bodies(source: source) {
                XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false, core)
                XCTAssertEqual(body["EnableDirectStream"] as? Bool, true, core)
                XCTAssertNil(body["AllowVideoStreamCopy"], core)
            }
        }
    }

    func testANonPositiveBitrateCapFallsBackToTheDefault() throws {
        for bitrate in [0, -5] {
            for (core, body) in bodies(source: hevcMP4, bitrateKbps: bitrate) {
                XCTAssertNil(body["MaxStreamingBitrate"], core)
                let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any], core)
                XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, 200_000_000, core)
            }
        }
    }

    func testOnlyAnHLSDeliveredSubtitleIsARendition() {
        let hls = "/videos/x/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Hls"
        let encode = "/videos/x/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Encode"
        let delivered: [[String: Any]] = [["Type": "Subtitle", "Index": 3, "DeliveryMethod": "Hls"]]
        XCTAssertTrue(MediaServerAirPlayReceiver.deliversSubtitleRendition(3, direct: false, transcodingURL: hls,
                                                                           mediaStreams: []))
        XCTAssertFalse(MediaServerAirPlayReceiver.deliversSubtitleRendition(3, direct: false, transcodingURL: encode,
                                                                            mediaStreams: delivered))
        XCTAssertFalse(MediaServerAirPlayReceiver.deliversSubtitleRendition(4, direct: false, transcodingURL: hls,
                                                                            mediaStreams: []))
        XCTAssertTrue(MediaServerAirPlayReceiver.deliversSubtitleRendition(
            3, direct: false, transcodingURL: "/videos/x/master.m3u8", mediaStreams: delivered))
        XCTAssertFalse(MediaServerAirPlayReceiver.deliversSubtitleRendition(3, direct: true, transcodingURL: hls,
                                                                            mediaStreams: delivered))
        XCTAssertFalse(MediaServerAirPlayReceiver.deliversSubtitleRendition(nil, direct: false, transcodingURL: hls,
                                                                            mediaStreams: delivered))
        XCTAssertFalse(MediaServerAirPlayReceiver.deliversSubtitleRendition(-1, direct: false, transcodingURL: hls,
                                                                            mediaStreams: delivered))
    }

    /// Printing, interpolating, reflecting or dumping a receiver stream never
    /// shows its URL, which carries the credential.
    func testAReceiverStreamNeverPrintsItsURL() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.test/videos/x/master.m3u8?ApiKey=test-token"))
        let stream = AirPlayReceiverStream(url: url, sourceOffset: 12, isTranscode: true, serverSessionId: "play",
                                           showsSubtitleRendition: true)
        var dumped = ""
        dump(stream, to: &dumped)
        let mirrored = Mirror(reflecting: stream).children.map { "\($0.label ?? ""): \($0.value)" }.joined()
        for text in ["\(stream)", String(describing: stream), String(reflecting: stream), dumped, mirrored] {
            XCTAssertFalse(text.contains("test-token"), text)
            XCTAssertFalse(text.contains("media.example.test"), text)
        }
        XCTAssertTrue("\(stream)".contains("serverSessionId: play"))
        XCTAssertTrue(dumped.contains("isTranscode"))
    }

    // MARK: - Receiver URLs

    func testDirectPlayURLsKeepTheBasePathAndCarryOneCredential() throws {
        let jellyfin = try JellyfinPlayback.receiverURL(
            JellyfinPlayback.airPlayStreamURL(serverURL: "https://media.example.test/jellyfin", itemPathID: item,
                                              sourceID: source, playSessionID: "play", transcodingURL: nil),
            token: "test-token")
        XCTAssertEqual(jellyfin.path, "/jellyfin/Videos/\(item)/stream")
        try assertOneCredential(jellyfin, name: "ApiKey")
        XCTAssertEqual(query(jellyfin)["Static"], "true")
        XCTAssertEqual(query(jellyfin)["MediaSourceId"], source)
        XCTAssertEqual(query(jellyfin)["PlaySessionId"], "play")

        let emby = try EmbyPlayback.receiverURL(
            EmbyPlayback.airPlayStreamURL(serverURL: "https://media.example.test/media", itemPathID: "item-1",
                                          sourceID: "source-1", playSessionID: "play", transcodingURL: nil),
            token: "test-token")
        XCTAssertEqual(emby.path, "/media/emby/Videos/item-1/stream")
        try assertOneCredential(emby, name: "api_key")
        XCTAssertEqual(query(emby)["Static"], "true")
    }

    /// A modern Jellyfin `TranscodingUrl` carries the server's own token as
    /// both `ApiKey` and `api_key`, and a start time. The receiver URL swaps
    /// both for exactly one credential and drops the start time.
    func testTranscodeURLsCarryExactlyOneCredentialAndNoStartTime() throws {
        let raw = "/videos/\(item)/master.m3u8?DeviceId=device&MediaSourceId=\(source)&VideoCodec=hevc,h264"
            + "&AudioCodec=aac&PlaySessionId=play&ApiKey=secret&api_key=secret&StartTimeTicks=123"
            + "&SegmentContainer=mp4&TranscodeReasons=ContainerNotSupported"
        let cases: [(String, URL, String)] = try [
            ("Jellyfin", JellyfinPlayback.receiverURL(
                JellyfinPlayback.airPlayStreamURL(serverURL: "https://media.example.test/jellyfin", itemPathID: item,
                                                  sourceID: source, playSessionID: "play", transcodingURL: raw),
                token: "test-token"), "ApiKey"),
            ("Emby", EmbyPlayback.receiverURL(
                EmbyPlayback.airPlayStreamURL(serverURL: "https://media.example.test", itemPathID: item,
                                              sourceID: source, playSessionID: "play", transcodingURL: raw),
                token: "test-token"), "api_key"),
        ]
        for (core, url, name) in cases {
            try assertOneCredential(url, name: name, core)
            XCTAssertEqual(url.scheme, "https", core)
            XCTAssertEqual(url.host, "media.example.test", core)
            XCTAssertNil(url.port, core)
            // Resolved the same way as Lucid Engine's transcode URL.
            XCTAssertTrue(url.path.hasSuffix("/videos/\(item)/master.m3u8"), core)
            let values = query(url)
            XCTAssertNil(values.keys.first { $0.lowercased() == "starttimeticks" }, core)
            XCTAssertEqual(values["DeviceId"], "device", "The transcode stays this device's job, \(core)")
            XCTAssertEqual(values["PlaySessionId"], "play", core)
            XCTAssertEqual(values["SegmentContainer"], "mp4", core)
            XCTAssertFalse(url.absoluteString.contains("secret"), core)
        }

        // A transcode URL relative to the server address keeps its base path.
        let relative = try JellyfinPlayback.receiverURL(
            JellyfinPlayback.airPlayStreamURL(serverURL: "https://media.example.test/jellyfin", itemPathID: item,
                                              sourceID: source, playSessionID: "play",
                                              transcodingURL: "videos/\(item)/master.m3u8?ApiKey=secret"),
            token: "test-token")
        XCTAssertEqual(relative.path, "/jellyfin/videos/\(item)/master.m3u8")
        try assertOneCredential(relative, name: "ApiKey")
    }

    func testTranscodeURLsOffTheServersOriginAreRefused() {
        let unsafe = [
            "https://other.example.test/videos/\(item)/master.m3u8?ApiKey=secret",
            "http://media.example.test/videos/\(item)/master.m3u8",
            "https://media.example.test:8920/videos/\(item)/master.m3u8",
            "https://user:pass@media.example.test/videos/\(item)/master.m3u8",
            "//other.example.test/videos/\(item)/master.m3u8",
        ]
        for raw in unsafe {
            XCTAssertThrowsError(try JellyfinPlayback.airPlayStreamURL(
                serverURL: "https://media.example.test/jellyfin", itemPathID: item, sourceID: source,
                playSessionID: "play", transcodingURL: raw), raw)
            XCTAssertThrowsError(try EmbyPlayback.airPlayStreamURL(
                serverURL: "https://media.example.test", itemPathID: item, sourceID: source,
                playSessionID: "play", transcodingURL: raw), raw)
        }
    }

    func testAReceiverURLNeedsAToken() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.test/videos/x/stream?Static=true"))
        for token in [nil, ""] as [String?] {
            XCTAssertThrowsError(try JellyfinPlayback.receiverURL(url, token: token))
            XCTAssertThrowsError(try EmbyPlayback.receiverURL(url, token: token))
        }
    }

    // MARK: - Preparing a receiver session

    /// The server offers a static MKV, which a receiver can't open, so its
    /// transcode is used instead. The new play session reports like any
    /// other, and only the receiver URL holds the credential.
    @MainActor
    func testJellyfinReceiverSessionUsesTheTranscodeAndReportsUnderItsOwnPlaySession() async throws {
        var requests: [URLRequest] = []
        var infoBodies: [[String: Any]] = []
        let media: [String: Any] = [
            "Id": source, "Container": "mkv", "RunTimeTicks": 6_000_000_000,
            "SupportsDirectPlay": true, "SupportsTranscoding": true,
            "MediaStreams": [["Type": "Video", "Index": 0, "Codec": "h264", "VideoRange": "SDR"],
                             ["Type": "Audio", "Index": 1, "Codec": "dts"],
                             ["Type": "Audio", "Index": 2, "Codec": "aac"],
                             ["Type": "Subtitle", "Index": 3, "Codec": "subrip"]],
        ]
        let connection = jellyfinConnection { request in
            requests.append(request)
            guard request.url!.path.hasSuffix("/PlaybackInfo") else { return (200, [:]) }
            infoBodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]))
            var playable = media
            playable["TranscodingUrl"] = "/videos/\(self.item)/master.m3u8?DeviceId=device&MediaSourceId=\(self.source)"
                + "&PlaySessionId=receiver&SubtitleStreamIndex=3&SubtitleMethod=Hls&SegmentContainer=mp4"
                + "&ApiKey=secret&api_key=secret&StartTimeTicks=123"
            return (200, ["MediaSources": [playable], "PlaySessionId": "receiver"])
        }
        let adapter = JellyfinAdapter(connection: connection)
        let raw: [String: Any] = ["Id": item, "Name": "Example", "Type": "Movie", "MediaSources": [media]]
        let detail: WatchDetail = try JellyfinAdapter.decode(adapter.watch(raw, preferences: [:]))
        let metadata = JellyfinPlayback.Metadata(connection: connection, raw: raw, detail: detail)
        let (stream, prepared, playback) = try await JellyfinPlayback.prepareAirPlayReceiver(
            metadata: metadata, detail: detail, version: XCTUnwrap(detail.versions.first), audioOrdinal: 1,
            subtitleIndex: 3, bitrateKbps: 20_000, position: 120)

        let body = try XCTUnwrap(infoBodies.first)
        XCTAssertEqual(infoBodies.count, 1, "No separate burn-in request")
        XCTAssertEqual(body["StartTimeTicks"] as? Int, 0)
        XCTAssertEqual(body["AudioStreamIndex"] as? Int, 2)
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, 3)
        XCTAssertEqual(body["MaxStreamingBitrate"] as? Int, 20_000_000)
        XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false, "An MKV never direct plays to a receiver")

        XCTAssertTrue(stream.isTranscode)
        XCTAssertEqual(stream.sourceOffset, 0)
        XCTAssertEqual(stream.serverSessionId, "receiver")
        XCTAssertTrue(stream.showsSubtitleRendition, "The text subtitle arrives as a WebVTT rendition")
        try assertOneCredential(stream.url, name: "ApiKey")
        XCTAssertEqual(query(stream.url)["SubtitleMethod"], "Hls")
        XCTAssertEqual(prepared.session.sessionId, "receiver")
        XCTAssertEqual(prepared.session.playMethod, "Transcode")
        XCTAssertFalse(prepared.session.streamUrl.contains("test-token"))
        XCTAssertFalse(playback.stream.url.absoluteString.contains("test-token"))
        XCTAssertEqual(playback.playSessionID, "receiver")
        XCTAssertEqual(playback.method, "Transcode")
        XCTAssertEqual(playback.audioIndex, 2)
        XCTAssertEqual(playback.subtitleIndex, 3)

        try await playback.report(position: 125, isPaused: false)
        try await playback.report(position: 130, isPaused: true, stopping: true)
        XCTAssertEqual(requests.suffix(3).map { $0.url!.path },
                       ["/jellyfin/Sessions/Playing", "/jellyfin/Sessions/Playing/Progress",
                        "/jellyfin/Sessions/Playing/Stopped"])
        let stop = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(stop["PlaySessionId"] as? String, "receiver")
        XCTAssertEqual(stop["PositionTicks"] as? Int64, 1_300_000_000)
        for request in requests {
            XCTAssertNil(request.url?.query?.range(of: "test-token"), "Vivid's own requests keep the token in headers")
        }
    }

    /// An MP4 the receiver can open plays as it is; a stop ends the session
    /// and, for a transcode, clears this device's encoding job.
    @MainActor
    func testEmbyReceiverSessionDirectPlaysAnMP4AndClearsATranscodeOnStop() async throws {
        var requests: [URLRequest] = []
        var transcode = false
        let media: [String: Any] = [
            "Id": "source-1", "Container": "mp4", "RunTimeTicks": 6_000_000_000,
            "SupportsDirectPlay": true, "SupportsTranscoding": true,
            "MediaStreams": [["Type": "Video", "Index": 0, "Codec": "h264", "VideoRange": "SDR"],
                             ["Type": "Audio", "Index": 1, "Codec": "aac"]],
        ]
        let connection = embyConnection { request in
            requests.append(request)
            guard request.url!.path.hasSuffix("/PlaybackInfo") else { return (200, [:]) }
            var playable = media
            if transcode {
                playable["SupportsDirectPlay"] = false
                playable["TranscodingUrl"] = "/videos/item-1/master.m3u8?DeviceId=device&MediaSourceId=source-1"
                    + "&PlaySessionId=receiver-hls&api_key=secret&StartTimeTicks=123"
            }
            return (200, ["MediaSources": [playable], "PlaySessionId": transcode ? "receiver-hls" : "receiver"])
        }
        let adapter = EmbyAdapter(connection: connection)
        let raw: [String: Any] = ["Id": "item-1", "Name": "Example", "Type": "Movie", "MediaSources": [media]]
        let detail: WatchDetail = try EmbyAdapter.decode(adapter.watch(raw, preferences: [:]))
        let metadata = EmbyPlayback.Metadata(connection: connection, raw: raw, detail: detail)
        let version = try XCTUnwrap(detail.versions.first)

        let (direct, prepared, playback) = try await EmbyPlayback.prepareAirPlayReceiver(
            metadata: metadata, detail: detail, version: version, audioOrdinal: nil, subtitleIndex: nil, bitrateKbps: nil)
        XCTAssertFalse(direct.isTranscode)
        XCTAssertEqual(direct.serverSessionId, "receiver")
        XCTAssertFalse(direct.showsSubtitleRendition)
        XCTAssertEqual(direct.url.path, "/emby/Videos/item-1/stream")
        try assertOneCredential(direct.url, name: "api_key")
        XCTAssertEqual(prepared.session.playMethod, "DirectPlay")
        XCTAssertEqual(playback.method, "DirectPlay")
        XCTAssertFalse(playback.stream.url.absoluteString.contains("test-token"))

        transcode = true
        let (hls, _, hlsPlayback) = try await EmbyPlayback.prepareAirPlayReceiver(
            metadata: metadata, detail: detail, version: version, audioOrdinal: nil, subtitleIndex: nil, bitrateKbps: nil)
        XCTAssertTrue(hls.isTranscode)
        XCTAssertEqual(hls.serverSessionId, "receiver-hls")
        XCTAssertFalse(hls.showsSubtitleRendition)
        try assertOneCredential(hls.url, name: "api_key")
        try await hlsPlayback.report(position: 10, isPaused: false)
        try await hlsPlayback.report(position: 12, isPaused: true, stopping: true)
        XCTAssertEqual(requests.suffix(4).map { "\($0.httpMethod ?? "") \($0.url!.path)" },
                       ["POST /emby/Sessions/Playing", "POST /emby/Sessions/Playing/Progress",
                        "POST /emby/Sessions/Playing/Stopped", "DELETE /emby/Videos/ActiveEncodings"])
        XCTAssertEqual(query(try XCTUnwrap(requests.last?.url))["PlaySessionId"], "receiver-hls")
    }

    // MARK: - Helpers

    private func assertOneCredential(_ url: URL, name: String, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                                  file: file, line: line)
        let credentials = items.filter { StreamRequest.credentialQueryNames.contains($0.name.lowercased()) }
        XCTAssertEqual(credentials.map(\.name), [name], message, file: file, line: line)
        XCTAssertEqual(credentials.first?.value, "test-token", message, file: file, line: line)
    }

    private func query(_ url: URL) -> [String: String] {
        var values: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        return values
    }

    /// The value of `property` in the codec profile for `codec` (nil for the
    /// profile that applies to every codec).
    private func condition(_ profiles: [[String: Any]], codec: String?, _ property: String) -> String? {
        let profile = profiles.first { $0["Codec"] as? String == codec && $0["Type"] as? String == "Video" }
        let conditions = profile?["Conditions"] as? [[String: Any]] ?? []
        return conditions.first { $0["Property"] as? String == property }?["Value"] as? String
    }

    private func rangeTypes(_ profiles: [[String: Any]], codec: String) -> String? {
        let profile = profiles.first { $0["Codec"] as? String == codec }
        let conditions = profile?["Conditions"] as? [[String: Any]] ?? []
        return conditions.first { $0["Property"] as? String == "VideoRangeType" }?["Value"] as? String
    }

    private func stubbedSession(_ handler: @escaping (URLRequest) throws -> (Int, Any)) -> URLSession {
        AirPlayReceiverRequestStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AirPlayReceiverRequestStub.self]
        let session = URLSession(configuration: configuration)
        self.session = session
        return session
    }

    private func jellyfinConnection(_ handler: @escaping (URLRequest) throws -> (Int, Any)) -> JellyfinConnection {
        JellyfinConnection(serverURL: "https://media.example.test/jellyfin", token: "test-token",
                           userID: "11111111111111111111111111111111", identity: nil,
                           sessionOverride: stubbedSession(handler))
    }

    private func embyConnection(_ handler: @escaping (URLRequest) throws -> (Int, Any)) -> EmbyConnection {
        EmbyConnection(serverURL: "https://media.example.test", token: "test-token", userID: "user-1", identity: nil,
                       sessionOverride: stubbedSession(handler))
    }
}

private final class AirPlayReceiverRequestStub: URLProtocol {
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
            // A request still in flight after its test's tearDown cleared the
            // handler fails on its own instead of asserting into the next test.
            guard let handler = Self.handler else { throw URLError(.cancelled) }
            // URLSession hands a POST body to the protocol as a stream.
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                request.httpBody = data
            }
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
