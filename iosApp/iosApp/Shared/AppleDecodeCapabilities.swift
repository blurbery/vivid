import CoreMedia
import Foundation
import VideoToolbox

/// One video decoder the device can use, sent to servers as playback evidence.
struct AppleVideoDecodeCapability: Equatable, Sendable {
    let codec: String
    let decoderName: String?
    let profiles: [String]
    let levels: [Int]
    let bitDepths: [Int]
    let maxWidth: Int
    let maxHeight: Int
    let maxFrameRate: Double
    let maxBitrateKbps: Int
    let hardware: Bool
}

/// What this build and device can decode. The lists go to servers exactly as
/// written, so their order matters.
enum AppleDecodeCapabilities {
    enum StreamingVideoCapabilityMode: Equatable {
        /// Vivid's own engine declares everything it plays.
        case vividDeclared
        /// Only what the platform attests, for devices whose engine claim
        /// isn't trusted.
        case platformAttested
    }

    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    static let machineIdentifier: String = {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    private static let isTVOSBuild: Bool = {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }()

    private static let appleTVHD = "AppleTV5,3"

    static func streamingVideoCapabilityModeForDevice(
        isTVOS: Bool,
        isSimulator: Bool,
        machineIdentifier: String,
        usesLucid: Bool = false
    ) -> StreamingVideoCapabilityMode {
        if isSimulator { return .platformAttested }
        if isTVOS {
            let trusted = machineIdentifier.hasPrefix("AppleTV") && machineIdentifier != appleTVHD
            return trusted ? .vividDeclared : .platformAttested
        }
        let phoneOrTablet = machineIdentifier.hasPrefix("iPhone") || machineIdentifier.hasPrefix("iPad")
        return usesLucid && phoneOrTablet ? .vividDeclared : .platformAttested
    }

    static var streamingVideoCapabilityMode: StreamingVideoCapabilityMode {
        streamingVideoCapabilityModeForDevice(
            isTVOS: isTVOSBuild,
            isSimulator: isSimulator,
            machineIdentifier: machineIdentifier,
            usesLucid: true
        )
    }

    // MARK: - Lists

    private static let engineVideoCodecs = [
        "h264", "hevc", "av1", "vp9", "vp8", "mpeg4", "mpeg2video", "vc1", "qtrle",
        "msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "wmv1", "wmv2", "wmv3",
    ]
    private static let engineAudioCodecs = [
        "aac", "ac3", "eac3", "mp3", "mp2", "flac", "opus", "vorbis", "alac", "truehd",
        "mlp", "dts", "dca", "dts-hd", "dtshd", "pcm", "pcm_s16le", "pcm_s24le", "pcm_f32le", "pcm_bluray",
    ]
    private static let engineContainers = [
        "mp4", "m4v", "mov", "mkv", "matroska", "avi", "mpegts", "ts", "m2ts", "mts", "3gp", "3g2",
        "mpeg", "vob", "ogg", "webm", "flv", "mp3", "aac", "m4a", "flac", "alac", "wav", "opus",
    ]
    private static let bareAudioContainers = ["mp3", "m4a", "aac", "flac", "wav"]

    #if targetEnvironment(simulator)
    static let audioCodecs = ["aac", "ac3", "eac3", "mp3", "opus", "flac"]
    static let containers = ["mp4", "mov", "m4v", "mkv", "matroska", "ts", "m2ts", "mpegts"] + bareAudioContainers
    #else
    static let audioCodecs = [
        "aac", "ac3", "eac3", "dts", "truehd", "flac", "alac", "mp3", "opus", "vorbis", "pcm", "pcm_s16le", "pcm_s24le",
    ]
    static let containers = ["mp4", "mov", "m4v", "mkv", "matroska", "webm", "avi", "ts", "m2ts", "mpegts"] + bareAudioContainers
    #endif

    static let hardwareVideoCodecs: [String] = videoDecodeAttestation().filter(\.hardware).map(\.codec)
    static let packagedVideoCodecs: [String] = hardwareVideoCodecs

    /// Every attested codec once, in attestation order.
    private static var attestedVideoCodecs: [String] {
        var seen = Set<String>()
        return videoDecodeAttestation().map(\.codec).filter { seen.insert($0).inserted }
    }

    static func streamingVideoCodecs(for mode: StreamingVideoCapabilityMode) -> [String] {
        switch mode {
        case .vividDeclared: engineVideoCodecs
        case .platformAttested: attestedVideoCodecs
        }
    }

    static func streamingAudioCodecs(for mode: StreamingVideoCapabilityMode) -> [String] {
        switch mode {
        case .vividDeclared: engineAudioCodecs
        case .platformAttested: audioCodecs
        }
    }

    static func streamingContainers(for mode: StreamingVideoCapabilityMode) -> [String] {
        switch mode {
        case .vividDeclared: engineContainers
        case .platformAttested: containers
        }
    }

    static func streamingMaxResolutionToken(for mode: StreamingVideoCapabilityMode) -> String {
        switch mode {
        case .vividDeclared: "2160p"
        case .platformAttested: resolutionCeiling ?? "2160p"
        }
    }

    // MARK: - Ceilings

    private static var isConstrainedDevice: Bool {
        isSimulator || machineIdentifier == appleTVHD
    }

    /// Nil means no ceiling.
    private static var resolutionCeiling: String? {
        isConstrainedDevice ? "1080p" : nil
    }

    static var decodeHeight: Int { isConstrainedDevice ? 1_080 : 2_160 }
    static var decodeWidth: Int { decodeHeight >= 2_160 ? 3_840 : 1_920 }

    // MARK: - Attestation

    private static let attestation: [AppleVideoDecodeCapability] = makeAttestation()

    static func videoDecodeAttestation() -> [AppleVideoDecodeCapability] {
        attestation
    }

    private static func makeAttestation() -> [AppleVideoDecodeCapability] {
        let width = decodeWidth
        let height = decodeHeight
        let bitrate = height >= 2_160 ? 120_000 : 25_000
        var entries: [AppleVideoDecodeCapability] = []
        for (codec, bitDepths, type) in [("h264", [8], kCMVideoCodecType_H264), ("hevc", [8, 10], kCMVideoCodecType_HEVC)]
        where hasHardwareDecoder(codec: codec, type: type) {
            entries.append(AppleVideoDecodeCapability(
                codec: codec, decoderName: "VideoToolbox", profiles: [], levels: [], bitDepths: bitDepths,
                maxWidth: width, maxHeight: height, maxFrameRate: 60, maxBitrateKbps: bitrate, hardware: true))
        }
        entries += softwareDecoders
        return entries
    }

    private static func hasHardwareDecoder(codec: String, type: CMVideoCodecType) -> Bool {
        #if targetEnvironment(simulator)
        return codec == "h264"
        #else
        return VTIsHardwareDecodeSupported(type)
        #endif
    }

    private static let softwareDecoders: [AppleVideoDecodeCapability] = [
        software("h264", decoder: "libavcodec", profile: "high 10", bitDepth: 10, width: 1_920, height: 1_080, frameRate: 30, kbps: 10_000),
        software("av1", decoder: "dav1d", profile: "main", bitDepth: 10, width: 1_920, height: 1_080, frameRate: 30, kbps: 3_000),
        software("vp9", decoder: "libavcodec", profile: "profile 0", bitDepth: 8, width: 1_920, height: 1_080, frameRate: 30, kbps: 3_000),
        software("mpeg2video", decoder: "libavcodec", profile: "main", bitDepth: 8, width: 720, height: 480, frameRate: 31, kbps: 7_000),
        software("vc1", decoder: "libavcodec", profile: "advanced", bitDepth: 8, width: 1_920, height: 1_080, frameRate: 30, kbps: 32_000),
    ]

    private static func software(
        _ codec: String, decoder: String, profile: String, bitDepth: Int,
        width: Int, height: Int, frameRate: Double, kbps: Int
    ) -> AppleVideoDecodeCapability {
        AppleVideoDecodeCapability(
            codec: codec, decoderName: decoder, profiles: [profile], levels: [], bitDepths: [bitDepth],
            maxWidth: width, maxHeight: height, maxFrameRate: frameRate, maxBitrateKbps: kbps, hardware: false)
    }
}

/// The video limits sent in Emby and Jellyfin PlaybackInfo requests. Devices
/// whose engine claim is trusted send the plain codec list; the others send
/// one envelope per codec from their attestation.
struct DeviceProfileVideoLimits: Equatable, Sendable {
    struct Envelope: Equatable, Sendable {
        let codec: String
        let width: Int
        let height: Int
        let frameRate: Double
        let bitDepth: Int
        let profiles: [String]
        /// Bits per second. Nil for a hardware decoder.
        let bitrate: Int?
    }

    let videoCodecs: [String]
    let maxWidth: Int?
    let maxHeight: Int?
    let envelopes: [Envelope]

    private static let directPlayCodecs = ["h264", "hevc", "av1", "mpeg2video", "vp9"]

    static let declared = DeviceProfileVideoLimits(videoCodecs: directPlayCodecs, maxWidth: nil, maxHeight: nil, envelopes: [])

    static let current = make(
        mode: AppleDecodeCapabilities.streamingVideoCapabilityMode,
        attestation: AppleDecodeCapabilities.videoDecodeAttestation(),
        maxWidth: AppleDecodeCapabilities.decodeWidth,
        maxHeight: AppleDecodeCapabilities.decodeHeight
    )

    static func make(
        mode: AppleDecodeCapabilities.StreamingVideoCapabilityMode,
        attestation: [AppleVideoDecodeCapability],
        maxWidth: Int,
        maxHeight: Int
    ) -> DeviceProfileVideoLimits {
        guard mode == .platformAttested else { return declared }
        let envelopes = directPlayCodecs.compactMap { codec -> Envelope? in
            let entries = attestation.filter { $0.codec == codec }
            guard let entry = entries.first(where: \.hardware) ?? entries.first else { return nil }
            return Envelope(
                codec: codec,
                width: min(entry.maxWidth, maxWidth),
                height: min(entry.maxHeight, maxHeight),
                frameRate: entry.maxFrameRate,
                bitDepth: entry.bitDepths.max() ?? 8,
                profiles: entry.profiles,
                bitrate: entry.hardware ? nil : entry.maxBitrateKbps * 1_000
            )
        }
        return DeviceProfileVideoLimits(
            videoCodecs: envelopes.map(\.codec), maxWidth: maxWidth, maxHeight: maxHeight, envelopes: envelopes)
    }

    /// The lower of the device ceiling and the chosen quality, when either is set.
    func effectiveMaxHeight(qualityHeight: Int?) -> Int? {
        [maxHeight, qualityHeight].compactMap { $0 }.min()
    }

    func codecProfiles(qualityHeight: Int?) -> [[String: Any]] {
        var profiles: [[String: Any]] = []
        var overall: [[String: Any]] = []
        if let maxWidth { overall.append(Self.limit("Width", String(maxWidth))) }
        if let height = effectiveMaxHeight(qualityHeight: qualityHeight) {
            overall.append(Self.limit("Height", String(height)))
        }
        if !overall.isEmpty { profiles.append(["Type": "Video", "Conditions": overall]) }
        for envelope in envelopes {
            var conditions = [
                Self.limit("Width", String(envelope.width)),
                Self.limit("Height", String(envelope.height)),
                Self.limit("VideoFramerate", Self.frameRateText(envelope.frameRate)),
                Self.limit("VideoBitDepth", String(envelope.bitDepth)),
            ]
            if let bitrate = envelope.bitrate { conditions.append(Self.limit("VideoBitrate", String(bitrate))) }
            if !envelope.profiles.isEmpty {
                conditions.append([
                    "Condition": "EqualsAny",
                    "Property": "VideoProfile",
                    "Value": envelope.profiles.joined(separator: "|"),
                    "IsRequired": false,
                ])
            }
            profiles.append(["Type": "Video", "Codec": envelope.codec, "Conditions": conditions])
        }
        return profiles
    }

    private static func limit(_ property: String, _ value: String) -> [String: Any] {
        ["Condition": "LessThanEqual", "Property": property, "Value": value, "IsRequired": false]
    }

    private static func frameRateText(_ rate: Double) -> String {
        rate.rounded(.towardZero) == rate ? String(Int(rate)) : String(rate)
    }
}
