import AVFoundation
import CryptoKit
import Foundation

/// One attempt's capability declaration, with the HDR facts it came from.
struct ApplePlaybackV3CapabilitySnapshot: Equatable {
    let capabilities: PlaybackV3CodecCapabilities
    let context: PlaybackV3ClientContext
    let hdrAvailability: ApplePlaybackHDRAvailability

    var outputContextId: String? { context.output.outputContextId }

    /// Log fields describing the output this attempt declared. Raw route UIDs
    /// and the output context id stay out of logs.
    var outputDiagnosticsLogFields: String {
        let hdr = context.output.hdrDetails
        let dolbyVisionProfiles = hdr?.dolbyVisionProfiles ?? []
        let profiles = dolbyVisionProfiles.isEmpty ? "none" : dolbyVisionProfiles.map(String.init).joined(separator: ",")
        let sinkType = context.output.sinkType.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        return "hdrOutputEligible=\(hdrAvailability.hdrPlaybackEligible) "
            + "hdr10=\(hdr?.hdr10 ?? false) "
            + "hdr10Plus=\(hdr?.hdr10Plus ?? false) "
            + "hlg=\(hdr?.hlg ?? false) "
            + "dolbyVision=\(!dolbyVisionProfiles.isEmpty) "
            + "dvModes=\(profiles) "
            + "sinkType=\(sinkType)"
    }
}

/// What the Apple apps declare to Silo in a Protocol V3 start or replan:
/// codecs, the active output, and what each delivery class can carry.
enum ApplePlaybackV3Capabilities {
    /// Features advertised on every request.
    ///
    /// `layout_aware_passthrough` isn't among them: the server grants
    /// passthrough only to a client that lists real sink channel layouts at
    /// `exact` audio evidence, which Apple can't attest.
    static let features = [
        PlaybackProtocolV3.planFeature,
        PlaybackProtocolV3.clientTransformFeature,
        PlaybackProtocolV3.routeDiagnosticsFeature,
        PlaybackProtocolV3.deviceQuirksFeature,
        PlaybackProtocolV3.seekReanchorFeature,
        PlaybackProtocolV3.outputChangeFeature,
        PlaybackProtocolV3.directStreamResumeFeature,
        PlaybackProtocolV3.headerAuthenticatedMediaFeature,
        PlaybackProtocolV3.softwareVideoDecodeFeature,
        PlaybackProtocolV3.embeddedSubtitlesFeature,
    ]

    /// The start features. `authorized_media_origins_v1` is negotiated per
    /// attempt, added only when the server advertises it.
    static func startFeatures(authorizedMediaOrigins: Bool) -> [String] {
        authorizedMediaOrigins ? features + [PlaybackProtocolV3.authorizedMediaOriginsFeature] : features
    }

    private static let commonClaims = ["authenticated_stream_headers"]

    /// The Dolby Vision Profile 7 recipes Lucid runs on a real device:
    /// Profile 7 to 8.1 when the panel takes Dolby Vision, otherwise down to
    /// the HDR10 base layer. They let the server keep a DV7 source on
    /// `original_http` instead of remuxing it, so they're declared on that
    /// delivery only. They need `client_video_transformations_v1` in the
    /// features, or the server rejects the whole request.
    static let deviceClientTransformations = [
        PlaybackV3Transformation(
            name: "client_dv7_to_dv81",
            executor: "client",
            recipeVersion: "1",
            validatedClaims: [
                "profile7_rpu_converted_to_profile81",
                "hdr10_base_layer_preserved",
                "enhancement_layer_discarded",
            ]
        ),
        PlaybackV3Transformation(
            name: "client_dv7_to_hdr10",
            executor: "client",
            recipeVersion: "1",
            validatedClaims: [
                "dolby_vision_metadata_removed",
                "hdr10_base_layer_preserved",
                "enhancement_layer_discarded",
            ]
        ),
    ]

    /// A subtitle codec under its FFmpeg name.
    static func normalizedSubtitleCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "srt": return "subrip"
        case "vtt": return "webvtt"
        case "tx3g": return "mov_text"
        case "pgs", "pgssub": return "hdmv_pgs_subtitle"
        case "dvdsub", "vobsub": return "dvd_subtitle"
        case "dvbsub": return "dvb_subtitle"
        default: return codec.lowercased()
        }
    }

    /// The embedded subtitles Lucid reads from each container it opens, by
    /// FFmpeg stream index. Its demuxer drains text and bitmap packets from
    /// the source; XSUB has no decoder.
    static func nativeEmbeddedSubtitleCapabilities(containers: [String]) -> [PlaybackV3NativeEmbeddedSubtitleCapability] {
        var seen = Set<String>()
        return containers
            .map { $0.lowercased() == "matroska" ? "mkv" : $0.lowercased() }
            .filter { ["mkv", "mp4", "mov", "m4v", "webm"].contains($0) && seen.insert($0).inserted }
            .map { container in
                PlaybackV3NativeEmbeddedSubtitleCapability(
                    container: container,
                    codecs: container == "mkv"
                        ? ["subrip", "ass", "ssa", "webvtt", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]
                        : (container == "webm" ? ["webvtt"] : ["mov_text"]),
                    trackIdentity: "ffmpeg_stream_index",
                    assStyling: false,
                    fontAttachments: false
                )
            }
    }

    static func snapshot(
        videoCapabilityMode requestedMode: AppleDecodeCapabilities.StreamingVideoCapabilityMode? = nil
    ) -> ApplePlaybackV3CapabilitySnapshot {
        let hdrAvailability = ApplePlaybackHDRAvailability.probe()
        let output = outputSnapshot(hdrAvailability: hdrAvailability)
        let mode = requestedMode ?? AppleDecodeCapabilities.streamingVideoCapabilityMode
        let usesLucidDeclaration = mode == .vividDeclared
        let videoCodecs = AppleDecodeCapabilities.streamingVideoCodecs(for: mode)
        // On original HTTP Lucid owns demux and decode. With the Lucid
        // declaration this describes the build, not the exact source: the
        // load-time probe picks native or software decode, and a typed load
        // failure takes the bounded V3 replan path.
        let audioCodecs = AppleDecodeCapabilities.streamingAudioCodecs(for: mode)
        let containers = AppleDecodeCapabilities.streamingContainers(for: mode)

        let capabilities = PlaybackV3CodecCapabilities(
            videoEvidence: usesLucidDeclaration
                ? PlaybackProtocolV3.Evidence.declared
                : PlaybackProtocolV3.Evidence.platformAttested,
            // The codecs the pinned engine build accepts, not ones an Apple
            // audio decoder probe attested.
            audioEvidence: PlaybackProtocolV3.Evidence.declared,
            codecsVideo: videoCodecs,
            codecsVideoHardware: AppleDecodeCapabilities.hardwareVideoCodecs,
            codecsAudio: audioCodecs,
            containers: containers,
            maxResolution: AppleDecodeCapabilities.streamingMaxResolutionToken(for: mode),
            hdr: output.hdrDetails.map { $0.hdr10 || $0.hlg || !$0.dolbyVisionProfiles.isEmpty } ?? false,
            hdrDetails: output.hdrDetails,
            audioPassthrough: output.audioPassthrough,
            videoDecode: usesLucidDeclaration ? [] : AppleDecodeCapabilities.playbackV3VideoDecodeAttestation()
        )
        // The app version, build and channel come from the same readers as the
        // HTTP headers, so the two can't disagree. Not through
        // `AppleDeviceIdentity.current`, which also reads the Keychain device
        // id that a capability snapshot needn't wait for.
        let context = PlaybackV3ClientContext(
            protocolVersion: PlaybackProtocolV3.version,
            formFactor: formFactor,
            appVersion: AppleDeviceIdentity.bundleAppVersion,
            appBuild: AppleDeviceIdentity.bundleAppBuild,
            appChannel: AppleDeviceIdentity.buildChannel,
            device: deviceContext,
            output: output,
            deliveries: deliveries(output: output, videoCodecs: videoCodecs, audioCodecs: audioCodecs,
                                   containers: containers, usesLucidDeclaration: usesLucidDeclaration)
        )
        return ApplePlaybackV3CapabilitySnapshot(capabilities: capabilities, context: context,
                                                 hdrAvailability: hdrAvailability)
    }

    /// What each delivery class can carry. Original HTTP is everything Lucid
    /// plays from the source; the packaged progressive and HLS deliveries are
    /// narrower, describing what the server may send straight to the native
    /// receiver path.
    private static func deliveries(
        output: PlaybackV3OutputContext,
        videoCodecs: [String],
        audioCodecs: [String],
        containers: [String],
        usesLucidDeclaration: Bool
    ) -> [String: PlaybackV3DeliveryCapability] {
        let lucidSubtitles = PlaybackV3DeliverySubtitleCapabilities(
            nativeEmbedded: nativeEmbeddedSubtitleCapabilities(containers: containers),
            embeddedText: true,
            sidecarText: true,
            // The overlay keeps text and placement, not every authored ASS style.
            assStyling: false,
            embeddedBitmap: true,
            sidecarBitmap: false,
            fontAttachments: false
        )
        let packagedSubtitles = PlaybackV3DeliverySubtitleCapabilities(
            embeddedText: true,
            sidecarText: true,
            assStyling: false,
            embeddedBitmap: false,
            sidecarBitmap: false,
            fontAttachments: false
        )
        let originalHTTPClaims = commonClaims + ["client_subtitle_overlay"] + (usesLucidDeclaration
            ? [PlaybackProtocolV3.clientManagedDynamicRangeClaim, PlaybackProtocolV3.clientSelectedAudioTrackClaim]
            : [])
        // The simulator has no real display or hardware HEVC decoder, so it
        // claims neither recipe. The server checks them against the same
        // output snapshot's Dolby Vision profiles and HDR10 flag.
        let clientTransformations = AppleDecodeCapabilities.isSimulator ? [] : deviceClientTransformations

        func delivery(containers: [String], videoCodecs: [String], audioCodecs: [String],
                      subtitles: PlaybackV3DeliverySubtitleCapabilities, claims: [String],
                      transformations: [PlaybackV3Transformation]) -> PlaybackV3DeliveryCapability {
            PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: containers,
                videoCodecs: videoCodecs,
                audioDecodeCodecs: audioCodecs,
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: output.hdrDetails,
                subtitles: subtitles,
                features: [],
                authHeaderRefresh: false,
                validatedClaims: claims,
                transformations: transformations
            )
        }

        return [
            PlaybackProtocolV3.DeliveryClass.originalHTTP: delivery(
                containers: containers, videoCodecs: videoCodecs, audioCodecs: audioCodecs,
                subtitles: lucidSubtitles, claims: originalHTTPClaims, transformations: clientTransformations),
            PlaybackProtocolV3.DeliveryClass.progressive: delivery(
                containers: ["mp4", "mov", "m4v"], videoCodecs: AppleDecodeCapabilities.packagedVideoCodecs,
                audioCodecs: ["aac", "ac3", "eac3", "alac", "mp3"],
                subtitles: packagedSubtitles, claims: commonClaims, transformations: []),
            PlaybackProtocolV3.DeliveryClass.hls: delivery(
                containers: ["hls", "mpegts", "fmp4", "mp4"], videoCodecs: AppleDecodeCapabilities.packagedVideoCodecs,
                audioCodecs: ["aac", "ac3", "eac3"],
                subtitles: packagedSubtitles, claims: commonClaims, transformations: []),
        ]
    }

    /// The active output, not just what the decoder can open: the server
    /// trusts output HDR evidence over decoder evidence, so a device-wide
    /// claim could pick an HDR route for an SDR display chain.
    private static func outputSnapshot(hdrAvailability: ApplePlaybackHDRAvailability) -> PlaybackV3OutputContext {
        let hdr = hdrDetails(
            hdr10: hdrAvailability.supportsHDR10,
            hlg: hdrAvailability.supportsHLG,
            dolbyVision: hdrAvailability.supportsDolbyVision
        )
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let sink = outputs.map { $0.uid }.sorted().joined(separator: ",")
        let sinkType = outputs.map { $0.portType.rawValue }.sorted().joined(separator: ",")
        let hdrIdentity = "\(hdr.hdr10)|\(hdr.hdr10Plus)|\(hdr.hlg)|"
            + hdr.dolbyVisionProfiles.map(String.init).joined(separator: ",")
        let identity = [platformName, formFactor, sink, sinkType, hdrIdentity].joined(separator: "|")
        return PlaybackV3OutputContext(
            hdrDetails: hdr,
            // Apple can't list a receiver's passthrough codecs and layouts, and
            // platform-attested audio evidence never earns passthrough.
            audioPassthrough: nil,
            currentSink: boundedField(sink),
            sinkType: boundedField(sinkType),
            outputContextId: outputContextId(identity)
        )
    }

    /// Apple attests no separate HDR10+ output, and Dolby Vision means
    /// profiles 5 and 8.
    static func hdrDetails(hdr10: Bool, hlg: Bool, dolbyVision: Bool) -> PlaybackV3HDRCapabilities {
        PlaybackV3HDRCapabilities(
            hdr10: hdr10,
            hdr10Plus: false,
            hlg: hlg,
            dolbyVisionProfiles: dolbyVision ? [5, 8] : []
        )
    }

    /// A stable, opaque token for the output route: `apple:` and the first 16
    /// hex digits of the route identity's SHA-256. The server only compares
    /// it for equality, and the digest stays within the field's 128-byte
    /// limit however many sinks are attached.
    private static func outputContextId(_ identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "apple:" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    /// Cut to the contract's 128-character limit for free-form strings (the
    /// server rejects longer ones), or nil when empty.
    private static func boundedField(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return String(value.prefix(128))
    }

    private static var platformName: String {
        #if os(tvOS)
        "tvos"
        #else
        "ios"
        #endif
    }

    private static var formFactor: String {
        #if os(tvOS)
        "tv"
        #else
        "mobile"
        #endif
    }

    private static var deviceContext: PlaybackV3DeviceContext {
        let machine = AppleDecodeCapabilities.machineIdentifier
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var details = ["os_name": platformName]
        if !machine.isEmpty { details["machine"] = machine }
        #if targetEnvironment(simulator)
        details["simulator"] = "true"
        #endif
        return PlaybackV3DeviceContext(
            platform: platformName,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            manufacturer: "Apple",
            model: boundedField(machine),
            platformDetails: details
        )
    }
}
