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

    func testAppleTV4KIPhoneAndIPadKeepTheDeclaredProfile() throws {
        for (isTVOS, machine) in [(true, "AppleTV14,1"), (false, "iPhone17,1"), (false, "iPad16,3")] {
            let mode = AppleDecodeCapabilities.streamingVideoCapabilityModeForDevice(
                isTVOS: isTVOS, isSimulator: false, machineIdentifier: machine, usesLucid: true)
            let device = DeviceProfileVideoLimits.make(
                mode: mode, attestation: AppleDecodeCapabilities.videoDecodeAttestation(), maxWidth: 3_840, maxHeight: 2_160)
            XCTAssertEqual(device, .declared, machine)
            for (core, body) in bodies(source: uhdHEVC, quality: nil, device: device) {
                XCTAssertEqual(body["EnableDirectPlay"] as? Bool, true, "\(core) \(machine)")
                let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
                XCTAssertEqual(try directPlayCodecs(profile), ["h264", "hevc", "av1", "mpeg2video", "vp9"], "\(core) \(machine)")
                XCTAssertNil(profile["CodecProfiles"], "\(core) \(machine)")
                XCTAssertNil((profile["TranscodingProfiles"] as? [[String: Any]])?.first?["MaxHeight"], "\(core) \(machine)")
            }
            for (core, body) in bodies(source: uhdHEVC, quality: "1080p", device: device) {
                let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
                let codecProfiles = try XCTUnwrap(profile["CodecProfiles"] as? [[String: Any]])
                XCTAssertEqual(codecProfiles.count, 1, "\(core) \(machine)")
                XCTAssertEqual(limits(codecProfiles, codec: nil), ["Height": "1080"], "\(core) \(machine)")
                let transcode = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
                XCTAssertEqual(transcode["MaxHeight"] as? Int, 1_080, "\(core) \(machine)")
                XCTAssertNil(transcode["MaxWidth"], "\(core) \(machine)")
            }
        }
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
