import XCTest
@testable import Vivid

/// Streaming, downloads and the device profile describe decoding with the
/// same vocabulary, and each device claims only what it should.
final class AppleDecodeCapabilitiesTests: XCTestCase {
    private typealias Capabilities = AppleDecodeCapabilities

    private var engineVideoCodecs: [String] { Capabilities.streamingVideoCodecs(for: .vividDeclared) }
    private var engineAudioCodecs: [String] { Capabilities.streamingAudioCodecs(for: .vividDeclared) }
    private var engineContainers: [String] { Capabilities.streamingContainers(for: .vividDeclared) }
    private var attestedVideoCodecs: [String] { Capabilities.streamingVideoCodecs(for: .platformAttested) }
    private var bareAudioContainers: [String] { Array(Capabilities.containers.suffix(5)) }

    private func softwareEntries() -> [String: PlaybackV3VideoDecodeCapability] {
        Dictionary(uniqueKeysWithValues: DownloadCaps.current().videoDecode.filter { !$0.hardware }.map { ($0.codec, $0) })
    }

    func testV3SnapshotReportsTheSharedVocabulary() {
        let mode = Capabilities.streamingVideoCapabilityMode
        let capabilities = ApplePlaybackV3Capabilities.snapshot().capabilities
        XCTAssertEqual(capabilities.codecsAudio, Capabilities.streamingAudioCodecs(for: mode))
        XCTAssertEqual(capabilities.containers, Capabilities.streamingContainers(for: mode))
        XCTAssertEqual(capabilities.codecsVideo, Capabilities.streamingVideoCodecs(for: mode))
    }

    func testDownloadCapsReportTheSharedVocabulary() {
        let caps = DownloadCaps.current()
        XCTAssertEqual(caps.codecsAudio, Capabilities.audioCodecs)
        XCTAssertEqual(caps.containers, Capabilities.containers)
        XCTAssertEqual(caps.codecsVideo, Capabilities.hardwareVideoCodecs)
        XCTAssertEqual(caps.maxResolution, "1080p")
        XCTAssertEqual(caps.videoEvidence, "platform_attested")
        XCTAssertEqual(caps.videoDecode, AppleDecodeCapabilities.playbackV3VideoDecodeAttestation())
        XCTAssertEqual(caps.clientFeatures, ["software_video_decode_v1"])
        XCTAssertTrue(Set(caps.codecsVideo).isDisjoint(with: ["av1", "vp9", "mpeg2video", "vc1"]))
    }

    func testDownloadSoftwareClaimsRetainTheirOwnBounds() {
        let bounds = softwareEntries().mapValues { [$0.maxWidth, $0.maxHeight, Int($0.maxFrameRate), $0.maxBitrateKbps] }
        XCTAssertEqual(bounds["h264"], [1_920, 1_080, 30, 10_000])
        XCTAssertEqual(bounds["av1"], [1_920, 1_080, 30, 3_000])
        XCTAssertEqual(bounds["vp9"], [1_920, 1_080, 30, 3_000])
        XCTAssertEqual(bounds["mpeg2video"], [720, 480, 31, 7_000])
        XCTAssertEqual(bounds["vc1"], [1_920, 1_080, 30, 32_000])
    }

    func testSoftwareClaimsStayWithinTheExercisedProfilesAndBitDepths() {
        let entries = softwareEntries()
        let expected: [(String, [String], [Int])] = [
            ("h264", ["high 10"], [10]),
            ("av1", ["main"], [10]),
            ("vp9", ["profile 0"], [8]),
            ("mpeg2video", ["main"], [8]),
            ("vc1", ["advanced"], [8]),
        ]
        for (codec, profiles, bitDepths) in expected {
            XCTAssertEqual(entries[codec]?.profiles, profiles, codec)
            XCTAssertEqual(entries[codec]?.bitDepths, bitDepths, codec)
        }
    }

    func testDownloadSoftwareEvidenceUsesTheServerWireKeys() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(DownloadCaps.current())) as? [String: Any])
        XCTAssertEqual(object["client_features"] as? [String], ["software_video_decode_v1"])
        XCTAssertEqual(object["video_evidence"] as? String, "platform_attested")
        XCTAssertNotNil(object["video_decode"] as? [[String: Any]])
        XCTAssertNil(object["clientFeatures"])
        XCTAssertNil(object["videoDecode"])
    }

    func testConservativeStreamingAndDownloadsShareAudioCodecs() {
        let streaming = Set(ApplePlaybackV3Capabilities.snapshot(videoCapabilityMode: .platformAttested).capabilities.codecsAudio)
        XCTAssertEqual(streaming, Set(DownloadCaps.current().codecsAudio))
        XCTAssertEqual(streaming, Set(Capabilities.audioCodecs))
    }

    func testBareAudioContainersReachTheFlatAndOriginalHTTPClaims() throws {
        let bare = Set(bareAudioContainers)
        XCTAssertEqual(bare, ["mp3", "m4a", "aac", "flac", "wav"])
        XCTAssertTrue(bare.isSubset(of: Capabilities.containers))
        let snapshot = ApplePlaybackV3Capabilities.snapshot(videoCapabilityMode: .platformAttested)
        let original = try XCTUnwrap(snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP])
        XCTAssertTrue(bare.isSubset(of: original.containers))
        XCTAssertFalse(original.containers.contains("ogg"))
    }

    func testAppleTV4KUsesTheVividBuildDeclaration() throws {
        let snapshot = ApplePlaybackV3Capabilities.snapshot(videoCapabilityMode: .vividDeclared)
        let capabilities = snapshot.capabilities
        XCTAssertEqual(capabilities.videoEvidence, "declared")
        XCTAssertTrue(capabilities.videoDecode.isEmpty)
        XCTAssertEqual(capabilities.codecsVideoHardware, Capabilities.hardwareVideoCodecs)
        XCTAssertEqual(capabilities.codecsVideo, engineVideoCodecs)
        XCTAssertEqual(capabilities.codecsAudio, engineAudioCodecs)
        XCTAssertEqual(capabilities.containers, engineContainers)
        XCTAssertEqual(capabilities.maxResolution, "2160p")

        let original = try XCTUnwrap(snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP])
        XCTAssertEqual(original.videoCodecs, engineVideoCodecs)
        XCTAssertEqual(original.audioDecodeCodecs, engineAudioCodecs)
        XCTAssertEqual(original.containers, engineContainers)
        XCTAssertTrue(original.validatedClaims.contains(PlaybackProtocolV3.clientManagedDynamicRangeClaim))
        XCTAssertTrue(original.validatedClaims.contains(PlaybackProtocolV3.clientSelectedAudioTrackClaim))

        let progressive = try XCTUnwrap(snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.progressive])
        XCTAssertEqual(progressive.videoCodecs, Capabilities.packagedVideoCodecs)
        XCTAssertEqual(progressive.containers, ["mp4", "mov", "m4v"])
        XCTAssertEqual(progressive.audioDecodeCodecs, ["aac", "ac3", "eac3", "alac", "mp3"])

        let hls = try XCTUnwrap(snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.hls])
        XCTAssertEqual(hls.videoCodecs, Capabilities.packagedVideoCodecs)
        XCTAssertEqual(hls.containers, ["hls", "mpegts", "fmp4", "mp4"])
        XCTAssertEqual(hls.audioDecodeCodecs, ["aac", "ac3", "eac3"])
    }

    func testConservativeSnapshotDoesNotClaimClientManagedDynamicRange() throws {
        let snapshot = ApplePlaybackV3Capabilities.snapshot(videoCapabilityMode: .platformAttested)
        let original = try XCTUnwrap(snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP])
        XCTAssertFalse(original.validatedClaims.contains(PlaybackProtocolV3.clientManagedDynamicRangeClaim))
        XCTAssertFalse(original.validatedClaims.contains(PlaybackProtocolV3.clientSelectedAudioTrackClaim))
    }

    func testVividDeclarationKeepsV3WireShapeWithoutDetailedPredictions() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let capabilities = ApplePlaybackV3Capabilities.snapshot(videoCapabilityMode: .vividDeclared).capabilities
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(capabilities)) as? [String: Any])
        XCTAssertEqual(object["video_evidence"] as? String, "declared")
        XCTAssertEqual((object["video_decode"] as? [Any])?.count, 0)
        XCTAssertEqual(object["codecs_video"] as? [String], engineVideoCodecs)
        XCTAssertNil(object["videoEvidence"])
        XCTAssertNil(object["videoDecode"])
    }

    func testEngineDeclarationCoversPinnedVividFFmpegManifest() {
        XCTAssertEqual(Set(engineVideoCodecs), [
            "h264", "hevc", "av1", "vp9", "vp8", "mpeg4", "mpeg2video", "vc1", "qtrle",
            "msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "wmv1", "wmv2", "wmv3",
        ])
        XCTAssertEqual(Set(engineAudioCodecs), [
            "aac", "ac3", "eac3", "mp3", "mp2", "flac", "opus", "vorbis", "alac", "truehd",
            "mlp", "dts", "dca", "dts-hd", "dtshd", "pcm", "pcm_s16le", "pcm_s24le", "pcm_f32le", "pcm_bluray",
        ])
        let containers = Set(engineContainers)
        XCTAssertEqual(containers, [
            "mp4", "m4v", "mov", "mkv", "matroska", "avi", "mpegts", "ts", "m2ts", "mts", "3gp", "3g2",
            "mpeg", "vob", "ogg", "webm", "flv", "mp3", "aac", "m4a", "flac", "alac", "wav", "opus",
        ])
        XCTAssertFalse(containers.contains("asf"))
        XCTAssertTrue(containers.contains("mpeg"))
    }

    func testPersistentDownloadsDoNotInheritOptimisticEngineClaims() {
        let caps = DownloadCaps.current()
        XCTAssertFalse(caps.codecsVideo.contains("qtrle"))
        XCTAssertFalse(caps.codecsAudio.contains("mlp"))
        XCTAssertFalse(caps.containers.contains("flv"))
        XCTAssertFalse(caps.videoDecode.isEmpty)
    }

    func testLucidPhonesAndTabletsDeclareTheirOriginalFilePipeline() {
        for machine in ["iPhone19,1", "iPad16,6"] {
            XCTAssertEqual(Capabilities.streamingVideoCapabilityModeForDevice(
                isTVOS: false, isSimulator: false, machineIdentifier: machine, usesLucid: true), .vividDeclared, machine)
            XCTAssertEqual(Capabilities.streamingVideoCapabilityModeForDevice(
                isTVOS: false, isSimulator: true, machineIdentifier: machine, usesLucid: true), .platformAttested, machine)
            XCTAssertEqual(Capabilities.streamingVideoCapabilityModeForDevice(
                isTVOS: false, isSimulator: false, machineIdentifier: machine, usesLucid: false), .platformAttested, machine)
        }
        XCTAssertEqual(Capabilities.streamingVideoCapabilityModeForDevice(
            isTVOS: true, isSimulator: false, machineIdentifier: "AppleTV5,3", usesLucid: true), .platformAttested)
    }

    func testStreamingPolicyTrustsAppleTV4KButNotAppleTVHDOrSimulators() {
        func mode(_ isTVOS: Bool, _ isSimulator: Bool, _ machine: String) -> AppleDecodeCapabilities.StreamingVideoCapabilityMode {
            Capabilities.streamingVideoCapabilityModeForDevice(isTVOS: isTVOS, isSimulator: isSimulator, machineIdentifier: machine)
        }
        XCTAssertEqual(mode(true, false, "AppleTV5,3"), .platformAttested)
        XCTAssertEqual(mode(true, false, "AppleTV6,2"), .vividDeclared)
        XCTAssertEqual(mode(true, false, "AppleTV11,1"), .vividDeclared)
        XCTAssertEqual(mode(true, false, "AppleTV14,1"), .vividDeclared)
        XCTAssertEqual(mode(true, false, "AppleTV99,1"), .vividDeclared)
        XCTAssertEqual(mode(true, true, "arm64"), .platformAttested)
        XCTAssertEqual(mode(false, false, "iPhone19,1"), .platformAttested)
        XCTAssertEqual(mode(true, false, "unknown"), .platformAttested)
    }

    func testDeviceListsCoverTheFormatsTheStackDecodes() {
        let containers = Capabilities.containers
        for container in ["mkv", "mp4", "mp3", "flac", "wav"] {
            XCTAssertTrue(containers.contains(container), container)
        }
        XCTAssertEqual(containers.contains("mkv"), containers.contains("matroska"))
        XCTAssertEqual(containers.contains("ts"), containers.contains("mpegts"))
        XCTAssertTrue(Capabilities.audioCodecs.contains("aac"))
        XCTAssertTrue(Capabilities.audioCodecs.contains("flac"))
    }

    func testHardwareCodecsAreASubsetOfClaimedCodecs() {
        let hardware = Set(Capabilities.hardwareVideoCodecs)
        XCTAssertTrue(hardware.isSubset(of: attestedVideoCodecs))
        XCTAssertTrue(hardware.isSubset(of: engineVideoCodecs))
    }

    func testDecodeEntriesNameTheDecoderTheyActuallyUse() {
        for entry in Capabilities.videoDecodeAttestation() {
            let expected = entry.hardware ? "VideoToolbox" : (entry.codec == "av1" ? "dav1d" : "libavcodec")
            XCTAssertEqual(entry.decoderName, expected, entry.codec)
        }
    }

    func testSimulatorClaimStaysConservative() throws {
        try XCTSkipUnless(Capabilities.isSimulator, "Only the simulator build has the conservative claim")
        XCTAssertEqual(Capabilities.streamingVideoCodecs(for: Capabilities.streamingVideoCapabilityMode),
                       ["h264", "av1", "vp9", "mpeg2video", "vc1"])
        XCTAssertEqual(Capabilities.streamingMaxResolutionToken(for: .platformAttested), "1080p")
        XCTAssertFalse(DownloadCaps.current().hdr)
        XCTAssertEqual(DownloadCaps.current().audioPassthroughCodecs, [])
    }
}
