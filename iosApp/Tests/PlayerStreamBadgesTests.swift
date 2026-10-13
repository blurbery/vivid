import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// The player's Stream pills: the dynamic-range label from each provider's
/// metadata, and the audio pill following the playing track.
final class PlayerStreamBadgesTests: XCTestCase {

    // MARK: - Silo

    func testSiloDolbyVisionProfiles() {
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 8", "dv_profile": 8, "dv_bl_compat_id": 1, "video_range": "DolbyVision", "video_range_type": "DOVIWithHDR10""#), "DV P8.1")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 8", "dv_profile": 8, "dv_bl_compat_id": 2, "video_range": "DolbyVision", "video_range_type": "DOVIWithSDR""#, hdr: false), "DV P8.2")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 8", "dv_profile": 8, "dv_bl_compat_id": 4, "video_range": "DolbyVision", "video_range_type": "DOVIWithHLG""#), "DV P8.4")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 7", "dv_profile": 7, "dv_bl_compat_id": 6, "dv_el_present": true, "video_range": "DolbyVision", "video_range_type": "DOVIWithEL""#), "DV P7")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 5", "dv_profile": 5, "video_range": "DolbyVision", "video_range_type": "DOVI""#), "DV P5")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 10", "dv_profile": 10, "dv_bl_compat_id": 1, "video_range": "DolbyVision", "video_range_type": "DOVI""#), "DV P10")
    }

    func testSiloProfile8CompatibilityFallsBackToTheRangeType() {
        // Silo leaves `dv_bl_compat_id` out when it is 0 and derives the
        // range type from the colour transfer instead.
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 8", "dv_profile": 8, "video_range_type": "DOVIWithHDR10""#), "DV P8.1")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 8", "dv_profile": 8, "video_range_type": "DOVIWithHDR10Plus", "hdr10_plus": true"#), "DV P8.1")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 8", "dv_profile": 8, "video_range_type": "DOVIWithHLG""#), "DV P8.4")
    }

    func testOlderSiloDolbyVisionLabelsWithoutProfileFields() {
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 8", "video_range": "DolbyVision""#), "DV P8")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 8.1""#), "DV P8.1")
        XCTAssertEqual(siloRange(#""dolby_vision": "Dolby Vision Profile 8.4 (HLG)""#), "DV P8.4")
        XCTAssertEqual(siloRange(#""dolby_vision": "Profile 7.6""#), "DV P7")
        XCTAssertEqual(siloRange(#""dolby_vision": "dvhe.08.06""#), "DV")
        XCTAssertEqual(siloRange(#""video_range": "DolbyVision""#), "DV")
    }

    func testSiloHDRTypes() {
        XCTAssertEqual(siloRange(#""video_range": "HDR", "video_range_type": "HDR10Plus", "hdr10_plus": true, "color_transfer": "smpte2084""#), "HDR10+")
        XCTAssertEqual(siloRange(#""video_range": "HDR", "video_range_type": "HDR10", "color_transfer": "smpte2084""#), "HDR10")
        XCTAssertEqual(siloRange(#""video_range": "HDR", "video_range_type": "HLG", "color_transfer": "arib-std-b67""#), "HLG")
        // Files probed before `video_range_type` existed.
        XCTAssertEqual(siloRange(#""video_range": "HDR", "color_transfer": "smpte2084""#), "HDR10")
        XCTAssertEqual(siloRange(#""video_range": "HDR", "color_transfer": "arib-std-b67""#), "HLG")
    }

    func testHDRFallbackAndSDR() {
        XCTAssertEqual(siloRange(#""video_range": "HDR""#), "HDR")
        XCTAssertEqual(PlayerStreamBadges.dynamicRange(siloVersion(hdr: true, tracks: nil)), "HDR")
        XCTAssertNil(siloRange(#""video_range_type": "SDR", "color_transfer": "bt709""#, hdr: false))
        XCTAssertNil(PlayerStreamBadges.dynamicRange(siloVersion(hdr: false, tracks: nil)))
        XCTAssertNil(PlayerStreamBadges.dynamicRange(siloVersion(hdr: nil, tracks: "[]")))
    }

    // MARK: - Jellyfin

    func testJellyfinDolbyVisionProfiles() throws {
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "DOVIWithHDR10", "DvProfile": 8, "DvBlSignalCompatibilityId": 1]), "DV P8.1")
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "DOVIWithHLG", "DvProfile": 8, "DvBlSignalCompatibilityId": 4]), "DV P8.4")
        // Jellyfin reports profile 8.2 as SDR, so the file's `hdr` flag is false.
        XCTAssertEqual(try jellyfinRange(["VideoRange": "SDR", "VideoRangeType": "DOVIWithSDR", "DvProfile": 8, "DvBlSignalCompatibilityId": 2]), "DV P8.2")
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "DOVIWithEL", "DvProfile": 7, "DvBlSignalCompatibilityId": 6]), "DV P7")
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "DOVI", "DvProfile": 5, "DvBlSignalCompatibilityId": 0]), "DV P5")
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "DOVIWithHDR10Plus", "DvProfile": 8, "DvBlSignalCompatibilityId": 1, "Hdr10PlusPresentFlag": true]), "DV P8.1")
        // A dvh1 codec tag without a configuration record has no profile.
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "DOVI"]), "DV")
    }

    func testJellyfinInvalidDolbyVisionShowsTheBaseLayer() throws {
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "DOVIInvalid", "DvProfile": 8, "DvBlSignalCompatibilityId": 6]), "HDR")
    }

    func testJellyfinHDRTypesAndSDR() throws {
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "HDR10Plus", "Hdr10PlusPresentFlag": true]), "HDR10+")
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "HDR10"]), "HDR10")
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR", "VideoRangeType": "HLG"]), "HLG")
        XCTAssertEqual(try jellyfinRange(["VideoRange": "HDR"]), "HDR")
        XCTAssertNil(try jellyfinRange(["VideoRange": "SDR", "VideoRangeType": "SDR"]))
    }

    // MARK: - Emby

    func testEmbyDolbyVisionProfiles() throws {
        XCTAssertEqual(try embyRange(["VideoRange": "Dolby Vision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubtype": "DoviProfile81"]), "DV P8.1")
        XCTAssertEqual(try embyRange(["VideoRange": "Dolby Vision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubtype": "DoviProfile76"]), "DV P7")
        XCTAssertEqual(try embyRange(["VideoRange": "Dolby Vision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubtype": "DoviProfile50"]), "DV P5")
        XCTAssertEqual(try embyRange(["VideoRange": "Dolby Vision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubType": "DoviProfile84"]), "DV P8.4")
        XCTAssertEqual(try embyRange(["VideoRange": "Dolby Vision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubtype": "None"]), "DV")
        // Servers without the extended fields only name the range.
        XCTAssertEqual(try embyRange(["VideoRange": "Dolby Vision"]), "DV")
    }

    func testEmbyHDRTypesAndSDR() throws {
        XCTAssertEqual(try embyRange(["VideoRange": "HDR 10+", "ExtendedVideoType": "Hdr10Plus", "ExtendedVideoSubtype": "Hdr10Plus0"]), "HDR10+")
        XCTAssertEqual(try embyRange(["VideoRange": "HDR 10", "ExtendedVideoType": "Hdr10", "ExtendedVideoSubtype": "Hdr10"]), "HDR10")
        XCTAssertEqual(try embyRange(["VideoRange": "HLG", "ExtendedVideoType": "HyperLogGamma", "ExtendedVideoSubtype": "HyperLogGamma"]), "HLG")
        XCTAssertEqual(try embyRange(["VideoRange": "HDR 10", "ExtendedVideoType": "None"]), "HDR10")
        XCTAssertEqual(try embyRange(["VideoRange": "HDR"]), "HDR")
        XCTAssertNil(try embyRange(["VideoRange": "SDR", "ExtendedVideoType": "None", "ExtendedVideoSubtype": "None"]))
    }

    func testProviderDolbyVisionLeavesTheDetailScreenLabelsAlone() throws {
        let emby: FileVersion = try EmbyAdapter.decode(embyAdapter.version(source(["VideoRange": "Dolby Vision", "ExtendedVideoType": "DolbyVision", "ExtendedVideoSubtype": "DoviProfile81"])))
        let jellyfin: FileVersion = try JellyfinAdapter.decode(jellyfinAdapter.version(source(["VideoRange": "HDR", "VideoRangeType": "DOVIWithHDR10", "DvProfile": 8, "DvBlSignalCompatibilityId": 1])))
        for version in [emby, jellyfin] {
            XCTAssertNil(version.videoTracks?.first?.dolbyVision)
            XCTAssertNil(version.videoTracks?.first?.videoRange)
            XCTAssertEqual(DetailPlaybackFormatting.dynamicRangeLabel(version), "HDR")
            XCTAssertEqual(PlayerStreamBadges.dynamicRange(version), "DV P8.1")
        }
    }

    // MARK: - Audio pill

    func testAudioPillFollowsThePlayingTrack() {
        let metadata = PlayerMetadata(
            seriesTitle: nil,
            episodeTag: nil,
            primaryTitle: "Example",
            year: 2024,
            overview: nil,
            videoBadges: ["4K", "DV P8.1", "HEVC"],
            fileAudioCodec: "TRUEHD"
        )
        XCTAssertEqual(metadata.streamBadges(playingAudio: audioTrack(id: 2, codec: "ac3")), ["4K", "DV P8.1", "HEVC", "AC3"])
        XCTAssertEqual(metadata.streamBadges(playingAudio: audioTrack(id: 3, codec: "eac3")), ["4K", "DV P8.1", "HEVC", "EAC3"])
        XCTAssertEqual(metadata.streamBadges(playingAudio: audioTrack(id: 1, codec: "truehd")), ["4K", "DV P8.1", "HEVC", "TRUEHD"])
        // Before the engine reports a selected track, the file's codec stands in.
        XCTAssertEqual(metadata.streamBadges(playingAudio: nil), ["4K", "DV P8.1", "HEVC", "TRUEHD"])
        // A playing track without a codec never falls back to the file's codec.
        XCTAssertEqual(metadata.streamBadges(playingAudio: audioTrack(id: 4, codec: nil)), ["4K", "DV P8.1", "HEVC"])
        XCTAssertEqual(PlayerMetadata.empty.streamBadges(playingAudio: nil), [])
    }

    func testAudioPillUsesTheAudioRowCodecText() {
        XCTAssertEqual(PlayerStreamBadges.audioCodec(audioTrack(id: 1, codec: "truehd")), "TRUEHD")
        XCTAssertEqual(PlayerStreamBadges.audioCodec(audioTrack(id: 1, codec: "dts")), "DTS")
        XCTAssertNil(PlayerStreamBadges.audioCodec(audioTrack(id: 1, codec: "")))
        XCTAssertNil(PlayerStreamBadges.audioCodec(nil))
    }

    // MARK: - Helpers

    private func siloRange(_ trackFields: String, hdr: Bool = true) -> String? {
        PlayerStreamBadges.dynamicRange(siloVersion(hdr: hdr, tracks: "[{ \(trackFields) }]"))
    }

    /// Decodes the way the Silo API client does, with snake_case keys.
    private func siloVersion(hdr: Bool?, tracks: String?) -> FileVersion {
        var fields = [#""file_id": 1"#, #""resolution": "2160p""#, #""codec_video": "hevc""#]
        if let hdr { fields.append(#""hdr": \#(hdr)"#) }
        if let tracks { fields.append(#""video_tracks": \#(tracks)"#) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(FileVersion.self, from: Data("{\(fields.joined(separator: ", "))}".utf8))
    }

    private func jellyfinRange(_ stream: [String: Any]) throws -> String? {
        let version: FileVersion = try JellyfinAdapter.decode(jellyfinAdapter.version(source(stream)))
        return PlayerStreamBadges.dynamicRange(version)
    }

    private func embyRange(_ stream: [String: Any]) throws -> String? {
        let version: FileVersion = try EmbyAdapter.decode(embyAdapter.version(source(stream)))
        return PlayerStreamBadges.dynamicRange(version)
    }

    private func source(_ stream: [String: Any]) -> [String: Any] {
        let base: [String: Any] = ["Type": "Video", "Index": 0, "Codec": "hevc", "Width": 3840, "Height": 2160]
        let video = stream.merging(base) { current, _ in current }
        let audio: [String: Any] = ["Type": "Audio", "Index": 1, "Codec": "truehd"]
        return ["Id": "source-1", "MediaStreams": [video, audio]]
    }

    private var embyAdapter: EmbyAdapter {
        EmbyAdapter(connection: EmbyConnection(serverURL: "https://media.example.test", token: nil, userID: "user-1", identity: nil))
    }

    private var jellyfinAdapter: JellyfinAdapter {
        JellyfinAdapter(connection: JellyfinConnection(serverURL: "https://media.example.test", token: nil, userID: "user-1", identity: nil))
    }

    private func audioTrack(id: Int64, codec: String?) -> PlayerTrack {
        PlayerTrack(
            trackId: id,
            kind: .audio,
            title: nil,
            lang: "eng",
            codec: codec,
            audioChannelCount: 6,
            bitrate: nil,
            isDefault: id == 1,
            isForced: false,
            isHearingImpaired: false,
            isExternal: false,
            isSelected: false,
            ffIndex: Int(id),
            srcId: nil
        )
    }
}
