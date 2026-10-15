import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Emby and Jellyfin PlaybackInfo requests carry the device's decode limits.
/// Apple TV HD only direct plays what its attestation covers, up to 1080p;
/// Apple TV 4K, iPhone and iPad keep the profile they had before.
final class ServerDeviceProfileTests: XCTestCase {

    /// Apple TV HD's A8 decodes H.264 in hardware and nothing else, so its
    /// attestation is that entry plus the shared software envelopes.
    private var appleTVHD: DeviceProfileVideoLimits {
        let hardwareH264 = AppleVideoDecodeCapability(
            codec: "h264", decoderName: "VideoToolbox", profiles: [], levels: [], bitDepths: [8],
            maxWidth: 1_920, maxHeight: 1_080, maxFrameRate: 60, maxBitrateKbps: 25_000, hardware: true)
        let mode = AppleDecodeCapabilities.streamingVideoCapabilityModeForDevice(
            isTVOS: true, isSimulator: false, machineIdentifier: "AppleTV5,3", usesLucid: true)
        XCTAssertEqual(mode, .platformAttested)
        return .make(mode: mode,
                     attestation: [hardwareH264] + AppleDecodeCapabilities.videoDecodeAttestation().filter { !$0.hardware },
                     maxWidth: 1_920, maxHeight: 1_080)
    }

    private let uhdHEVC: [String: Any] = ["MediaStreams": [["Type": "Video", "Codec": "hevc", "Width": 3_840,
                                                             "Height": 2_160, "BitDepth": 10, "VideoRange": "HDR"]]]
    private let fullHDH264: [String: Any] = ["MediaStreams": [["Type": "Video", "Codec": "h264", "Width": 1_920,
                                                                "Height": 1_080, "BitDepth": 8, "VideoRange": "SDR"]]]

    func testAppleTVHDRequestExcludesUHDDirectPlayAndUnattestedCodecs() throws {
        for (core, body) in bodies(source: uhdHEVC, quality: nil, device: appleTVHD) {
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false, core)
            XCTAssertEqual(body["EnableDirectStream"] as? Bool, false, core)
            XCTAssertEqual(body["AllowVideoStreamCopy"] as? Bool, false, core)
            let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any], core)
            let codecs = try directPlayCodecs(profile)
            XCTAssertEqual(codecs, ["h264", "av1", "mpeg2video", "vp9"], core)
            XCTAssertTrue(Set(codecs).isDisjoint(with: ["hevc", "vc1", "vp8", "mpeg4"]), core)
            let codecProfiles = try XCTUnwrap(profile["CodecProfiles"] as? [[String: Any]], core)
            XCTAssertEqual(limits(codecProfiles, codec: nil), ["Width": "1920", "Height": "1080"], core)
            XCTAssertEqual(limits(codecProfiles, codec: "h264"),
                           ["Width": "1920", "Height": "1080", "VideoFramerate": "60", "VideoBitDepth": "8"], core)
            XCTAssertEqual(limits(codecProfiles, codec: "av1"),
                           ["Width": "1920", "Height": "1080", "VideoFramerate": "30", "VideoBitDepth": "10",
                            "VideoBitrate": "3000000", "VideoProfile": "main"], core)
            XCTAssertEqual(limits(codecProfiles, codec: "vp9")?["VideoBitDepth"], "8", core)
            XCTAssertEqual(limits(codecProfiles, codec: "vp9")?["VideoProfile"], "profile 0", core)
            XCTAssertEqual(limits(codecProfiles, codec: "mpeg2video")?["Height"], "480", core)
            XCTAssertEqual(limits(codecProfiles, codec: "mpeg2video")?["VideoProfile"], "main", core)
            XCTAssertNil(limits(codecProfiles, codec: "hevc"), core)
            let transcode = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first, core)
            XCTAssertEqual(transcode["VideoCodec"] as? String, "h264", core)
            XCTAssertEqual(transcode["MaxHeight"] as? Int, 1_080, core)
            XCTAssertEqual(transcode["MaxWidth"] as? Int, 1_920, core)
        }
    }

    func testAppleTVHDStillDirectPlaysFullHDH264AndMergesTheQualityCap() throws {
        for (core, body) in bodies(source: fullHDH264, quality: nil, device: appleTVHD) {
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, true, core)
            XCTAssertNil(body["AllowVideoStreamCopy"], core)
        }
        for (core, body) in bodies(source: fullHDH264, quality: "720p", device: appleTVHD) {
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false, core)
            let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any], core)
            let codecProfiles = try XCTUnwrap(profile["CodecProfiles"] as? [[String: Any]], core)
            XCTAssertEqual(limits(codecProfiles, codec: nil), ["Width": "1920", "Height": "720"], core)
            XCTAssertEqual(limits(codecProfiles, codec: "h264")?["Height"], "1080", core)
            let transcode = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first, core)
            XCTAssertEqual(transcode["MaxHeight"] as? Int, 720, core)
        }
    }

    /// Apple TV 4K, iPhone and iPad must send exactly the request they sent
    /// before Apple TV HD had its own limits. Every Apple TV 4K generation and
    /// a range of iPhones and iPads are compared with `legacyBody`, across
    /// sources, every quality choice and both bitrate paths.
    func testAppleTV4KIPhoneAndIPadSendTheSameRequestAsBefore() {
        let machines = [(true, "AppleTV6,2"), (true, "AppleTV11,1"), (true, "AppleTV14,1"),
                        (false, "iPhone11,2"), (false, "iPhone17,1"), (false, "iPad8,1"), (false, "iPad16,3")]
        let sources: [[String: Any]] = [
            uhdHEVC, fullHDH264,
            ["MediaStreams": [["Type": "Video", "Codec": "hevc", "Width": 3_840, "Height": 2_160, "DvProfile": 8,
                               "VideoRangeType": "DOVIWithHDR10"]]],
            ["MediaStreams": [["Type": "Video", "Codec": "av1", "Width": 3_840, "Height": 1_600, "BitDepth": 10]]],
            ["MediaStreams": [["Type": "Video", "Codec": "mpeg2video", "Width": 720, "Height": 576]]],
            ["MediaStreams": [["Type": "Audio", "Codec": "aac"]]],
            [:],
        ]
        let qualities: [String?] = [nil, ApplePlaybackQuality.autoId, ApplePlaybackQuality.originalId]
            + ApplePlaybackQuality.requestOptions.map(\.id)
        for (isTVOS, machine) in machines {
            let mode = AppleDecodeCapabilities.streamingVideoCapabilityModeForDevice(
                isTVOS: isTVOS, isSimulator: false, machineIdentifier: machine, usesLucid: true)
            XCTAssertEqual(mode, .vividDeclared, machine)
            let device = DeviceProfileVideoLimits.make(
                mode: mode, attestation: AppleDecodeCapabilities.videoDecodeAttestation(), maxWidth: 3_840, maxHeight: 2_160)
            XCTAssertEqual(device, .declared, machine)
            for source in sources {
                for quality in qualities {
                    for bitrate in [nil, 10_000] as [Int?] {
                        let emby = EmbyPlayback.playbackInfoBody(
                            userID: "user", sourceID: "source", start: 754.5, audioIndex: 2, subtitleIndex: 3,
                            bitrateKbps: bitrate, source: source, quality: quality, device: device)
                        let jellyfin = JellyfinPlayback.playbackInfoBody(
                            userID: "user", sourceID: "source", start: 754.5, audioIndex: 2, subtitleIndex: 3,
                            bitrateKbps: bitrate, source: source, quality: quality, device: device)
                        let label = "\(machine) quality \(quality ?? "nil") bitrate \(bitrate.map(String.init) ?? "nil")"
                        XCTAssertEqual(emby as NSDictionary, Self.legacyBody(
                            name: "Vivid Vivid", start: 754.5, audioIndex: 2, subtitleIndex: 3, bitrateKbps: bitrate,
                            source: source, quality: quality) as NSDictionary, "Emby \(label)")
                        XCTAssertEqual(jellyfin as NSDictionary, Self.legacyBody(
                            name: "Vivid", start: 754.5, audioIndex: 2, subtitleIndex: 3, bitrateKbps: bitrate,
                            source: source, quality: quality) as NSDictionary, "Jellyfin \(label)")
                    }
                }
            }
        }
    }

    /// The Emby and Jellyfin PlaybackInfo body as `main` built it at 07ae0da,
    /// before the device limits, kept verbatim apart from the profile name the
    /// two cores used (and with `connection.userID` and `sourceID` inlined).
    private static func legacyBody(name: String, start: Double, audioIndex: Int?, subtitleIndex: Int?,
                                   bitrateKbps: Int?, source: [String: Any], quality: String?) -> [String: Any] {
        var body: [String: Any] = ["UserId":"user", "MediaSourceId":"source", "StartTimeTicks":EmbyPlayback.ticks(start),
            "IsPlayback":true, "AutoOpenLiveStream":false, "EnableDirectPlay":true, "EnableDirectStream":true, "EnableTranscoding":true,
            "SubtitleStreamIndex":subtitleIndex ?? -1,
            "DeviceProfile": ["Name":name, "MaxStreamingBitrate": (bitrateKbps ?? 200_000) * 1000,
                "DirectPlayProfiles":[["Type":"Video", "Container":"mkv,mp4,m4v,mov,avi,ts,m2ts,webm", "VideoCodec":"h264,hevc,av1,mpeg2video,vp9", "AudioCodec":"aac,ac3,eac3,flac,alac,mp3,opus,vorbis,truehd,dts,pcm_s16le,pcm_s24le"]],
                "TranscodingProfiles":[["Type":"Video", "Container":"ts", "Protocol":"hls", "VideoCodec":"h264", "AudioCodec":"aac", "Context":"Streaming", "MaxAudioChannels":"2", "MinSegments":2, "SegmentLength":6]],
                "SubtitleProfiles":[["Format":"srt", "Method":"External"], ["Format":"ass", "Method":"External"], ["Format":"ssa", "Method":"External"], ["Format":"vtt", "Method":"External"], ["Format":"pgssub", "Method":"Embed"], ["Format":"dvdsub", "Method":"Embed"]]]]
        if let bitrateKbps, bitrateKbps > 0 { body["MaxStreamingBitrate"] = bitrateKbps * 1000 }
        if let audioIndex { body["AudioStreamIndex"] = audioIndex }
        let hdr = true, dolbyVision = true
        let video = (source["MediaStreams"] as? [[String:Any]] ?? []).first { $0["Type"] as? String == "Video" } ?? [:]
        let range = ((video["VideoRangeType"] as? String ?? "") + " " + (video["VideoRange"] as? String ?? "")).lowercased()
        let isDV = (video["DvProfile"] as? Int ?? 0) > 0 || range.contains("dovi") || range.contains("dolby")
        let isHDR = isDV || range.contains("hdr") || range.contains("hlg")
        let height = ApplePlaybackQuality.requestOptions.first { $0.id == quality }?.resolution
            .split(separator:"p").first.flatMap { Int($0) }
        var profile = body["DeviceProfile"] as? [String:Any] ?? [:]
        if let height {
            profile["CodecProfiles"] = [["Type":"Video","Conditions":[["Condition":"LessThanEqual","Property":"Height","Value":String(height),"IsRequired":false]]]]
            var transcodes = profile["TranscodingProfiles"] as? [[String:Any]] ?? []
            for index in transcodes.indices { transcodes[index]["MaxHeight"] = height }
            profile["TranscodingProfiles"] = transcodes
        }
        let resize = height.map { (video["Height"] as? Int ?? 0) > $0 } ?? false
        if resize || (!hdr && isHDR) || (!dolbyVision && isDV) {
            body["EnableDirectPlay"] = false
            body["EnableDirectStream"] = false
            body["AllowVideoStreamCopy"] = false
        }
        body["DeviceProfile"] = profile
        return body
    }

    private func bodies(source: [String: Any], quality: String?,
                        device: DeviceProfileVideoLimits) -> [(String, [String: Any])] {
        [
            ("Emby", EmbyPlayback.playbackInfoBody(
                userID: "user", sourceID: "source", start: 0, audioIndex: nil, subtitleIndex: nil,
                bitrateKbps: nil, source: source, quality: quality, device: device)),
            ("Jellyfin", JellyfinPlayback.playbackInfoBody(
                userID: "user", sourceID: "source", start: 0, audioIndex: nil, subtitleIndex: nil,
                bitrateKbps: nil, source: source, quality: quality, device: device)),
        ]
    }

    private func directPlayCodecs(_ profile: [String: Any]) throws -> [String] {
        let directPlay = try XCTUnwrap((profile["DirectPlayProfiles"] as? [[String: Any]])?.first)
        return (directPlay["VideoCodec"] as? String ?? "").split(separator: ",").map(String.init)
    }

    /// Each condition's property and value, for the profile with that codec
    /// (nil for the profile that applies to every codec). Every condition is
    /// optional, and all but the profile list are upper bounds.
    private func limits(_ profiles: [[String: Any]], codec: String?) -> [String: String]? {
        guard let profile = profiles.first(where: { $0["Codec"] as? String == codec }) else { return nil }
        let conditions = profile["Conditions"] as? [[String: Any]] ?? []
        for condition in conditions {
            let isProfile = condition["Property"] as? String == "VideoProfile"
            XCTAssertEqual(condition["Condition"] as? String, isProfile ? "EqualsAny" : "LessThanEqual")
            XCTAssertEqual(condition["IsRequired"] as? Bool, false)
        }
        return Dictionary(uniqueKeysWithValues: conditions.compactMap { condition in
            (condition["Property"] as? String).map { ($0, condition["Value"] as? String ?? "") }
        })
    }
}
