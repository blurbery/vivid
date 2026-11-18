#if os(iOS)
import CryptoKit
import Foundation

/// Why a Silo plan or plan URL can't be handed to an AirPlay receiver.
///
/// The cases never carry the URL or any part of its query: a receiver URL
/// holds a signed stream reference.
enum SiloAirPlayReceiverError: Error, Equatable {
    /// The API base isn't a credential-free `http(s)` URL ending in `/api/v2`.
    case unsupportedAPIBase
    case emptySessionId
    case malformedURL
    /// An account credential (`token`, `api_key`, `access_token` and the like)
    /// is in the query. The receiver must only ever get the session-scoped
    /// reference.
    case credentialInQuery
    /// A query parameter other than `st` and `seek` on an API URL, or any
    /// query on a proxy URL.
    case unexpectedQuery
    /// An API-origin URL without its signed `st` reference, which the
    /// receiver could only fetch with headers it can't send.
    case missingStreamReference
    case sessionMismatch
    /// Not one of the receiver route shapes, or it has dot segments or
    /// encoded separators.
    case unsupportedPath
    /// An absolute URL on an origin the receiver may not be sent to.
    case unsupportedOrigin
    case unsupportedDelivery(String)
    /// The plan asks for request headers or header refresh.
    case requiresHeaders
    case clientTransformation(String)
    case unsupportedContainer(String)
    case invalidTimeline
}

/// Silo's side of the AirPlay video hand-off: what a receiver attempt
/// declares, and how its plan becomes a URL the receiver fetches by itself.
///
/// The receiver can't send headers, so its attempt leaves out
/// `header_authenticated_media_v1`. Silo then signs every plan URL with a
/// session-scoped stream reference (`st`) that the `/api/v2` delivery routes
/// accept without an account credential. The reference names the attempt's
/// own playback session, is bound to the login session that started it,
/// lasts at most 24 hours and dies when the session is stopped.
enum SiloAirPlayReceiver {
    /// The identity behind the receiver's `output_context_id`.
    static let outputContextLabel = "airplay-receiver"

    /// The only API version whose delivery routes take `st` without headers.
    /// The v1 routes still require the account's Authorization header.
    static let apiPathSuffix = "/api/v2"

    // MARK: - Capabilities

    /// The receiver attempt's start features.
    ///
    /// - No `header_authenticated_media_v1`: that's what makes Silo sign the
    ///   plan URLs with `st`.
    /// - No `authorized_media_origins_v1`: it only means something with
    ///   header authentication, and a legacy attempt gets self-authenticating
    ///   proxy URLs anyway.
    /// - No client transformations, software decode or embedded subtitles:
    ///   those describe Lucid, not the receiver.
    /// - No device quirks: they'd be the phone's, not the receiver's.
    /// - No seek re-anchor, output change or direct stream resume: the
    ///   hand-off never replans its receiver attempt.
    static let startFeatures = [
        PlaybackProtocolV3.planFeature,
        PlaybackProtocolV3.routeDiagnosticsFeature,
    ]

    /// What every AirPlay video receiver is assumed to show: SDR, HDR10 and
    /// HLG in HEVC. HDR10+ isn't attested, and Dolby Vision is left out
    /// because nothing tells a phone whether the receiver (or the TV behind
    /// it) presents it, and a Profile 7 source must never be copied to it.
    static let hdrDetails = PlaybackV3HDRCapabilities(
        hdr10: true,
        hdr10Plus: false,
        hlg: true,
        dolbyVisionProfiles: []
    )

    /// H.264 and HEVC are the only video codecs AirPlay receivers decode.
    static let videoCodecs = ["h264", "hevc"]
    /// A direct file the receiver fetches with byte ranges. Never Matroska.
    static let originalContainers = ["mp4", "mov", "m4v"]
    static let originalAudioCodecs = ["aac", "ac3", "eac3", "alac"]
    /// `hls` is the plan container for both server HLS deliveries, so it has
    /// to stay in the list; `mpegts` and `fmp4` are the segment formats.
    static let hlsContainers = ["hls", "mpegts", "fmp4"]
    static let hlsAudioCodecs = ["aac", "ac3", "eac3"]

    /// The receiver attempt's capability snapshot, built on the current
    /// app, device and route.
    static func snapshot() -> ApplePlaybackV3CapabilitySnapshot {
        snapshot(base: ApplePlaybackV3Capabilities.snapshot())
    }

    /// The receiver attempt's capability snapshot. Only the app, device and
    /// route identity come from `base`; every media fact describes the
    /// receiver instead of the phone.
    static func snapshot(base: ApplePlaybackV3CapabilitySnapshot) -> ApplePlaybackV3CapabilitySnapshot {
        let baseOutput = base.context.output
        let output = PlaybackV3OutputContext(
            hdrDetails: hdrDetails,
            // Apple can't list a receiver's passthrough codecs or layouts.
            audioPassthrough: nil,
            currentSink: baseOutput.currentSink,
            sinkType: baseOutput.sinkType,
            outputContextId: outputContextId(sink: baseOutput.currentSink, sinkType: baseOutput.sinkType)
        )
        let capabilities = PlaybackV3CodecCapabilities(
            // Nothing on the phone attests the receiver's decoders, so the
            // codec lists are declared and no `video_decode` entries (which
            // would be the phone's) are sent.
            videoEvidence: PlaybackProtocolV3.Evidence.declared,
            audioEvidence: PlaybackProtocolV3.Evidence.declared,
            codecsVideo: videoCodecs,
            codecsVideoHardware: videoCodecs,
            codecsAudio: originalAudioCodecs,
            containers: originalContainers + hlsContainers,
            // Current Apple TVs and AirPlay TVs are 4K; an HD receiver
            // downscales or refuses, and the hand-off's start timeout covers
            // the refusal.
            maxResolution: "2160p",
            hdr: hdrDetails.claimsAnyHDR,
            hdrDetails: hdrDetails,
            audioPassthrough: nil,
            videoDecode: []
        )
        let context = PlaybackV3ClientContext(
            protocolVersion: base.context.protocolVersion,
            formFactor: base.context.formFactor,
            appVersion: base.context.appVersion,
            appBuild: base.context.appBuild,
            appChannel: base.context.appChannel,
            device: base.context.device,
            output: output,
            deliveries: deliveries
        )
        return ApplePlaybackV3CapabilitySnapshot(
            capabilities: capabilities,
            context: context,
            hdrAvailability: ApplePlaybackHDRAvailability(
                hdrPlaybackEligible: true,
                supportsHDR10: true,
                supportsHLG: true,
                supportsDolbyVision: false
            )
        )
    }

    /// What each delivery class can carry to the receiver.
    ///
    /// Every subtitle flag is off: the receiver can't fetch or draw a
    /// sidecar, so a selected subtitle has to be burnt in by the server.
    /// No delivery carries validated claims: `authenticated_stream_headers`
    /// would promise headers the receiver can't send, and the Lucid claims
    /// (subtitle overlay, client-managed dynamic range, client-selected
    /// audio track) describe the phone's engine. Without the audio claim the
    /// server won't keep a multi-audio file direct when a non-default track
    /// is selected, which the receiver would ignore.
    static var deliveries: [String: PlaybackV3DeliveryCapability] {
        let noSubtitles = PlaybackV3DeliverySubtitleCapabilities(
            embeddedText: false,
            sidecarText: false,
            assStyling: false,
            embeddedBitmap: false,
            sidecarBitmap: false,
            fontAttachments: false
        )
        func delivery(enabled: Bool, failureReason: String?, containers: [String], videoCodecs: [String],
                      audioCodecs: [String]) -> PlaybackV3DeliveryCapability {
            PlaybackV3DeliveryCapability(
                enabled: enabled,
                supportedOnDevice: enabled,
                failureReason: failureReason,
                containers: containers,
                videoCodecs: videoCodecs,
                audioDecodeCodecs: audioCodecs,
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: hdrDetails,
                subtitles: noSubtitles,
                features: [],
                authHeaderRefresh: false,
                validatedClaims: [],
                transformations: []
            )
        }
        return [
            // A direct MP4 family file the receiver range-requests itself.
            PlaybackProtocolV3.DeliveryClass.originalHTTP: delivery(
                enabled: true, failureReason: nil, containers: originalContainers,
                videoCodecs: videoCodecs, audioCodecs: originalAudioCodecs),
            // Silo's progressive remux is a piped fragmented MP4 with no byte
            // ranges, which an AirPlay receiver can't seek or resume.
            PlaybackProtocolV3.DeliveryClass.progressive: delivery(
                enabled: false, failureReason: "airplay_receiver_requires_byte_ranges", containers: [],
                videoCodecs: [], audioCodecs: []),
            PlaybackProtocolV3.DeliveryClass.hls: delivery(
                enabled: true, failureReason: nil, containers: hlsContainers,
                videoCodecs: videoCodecs, audioCodecs: hlsAudioCodecs),
        ]
    }

    /// An opaque token for the receiver route. Its `apple-airplay:` prefix
    /// keeps it from ever equalling the phone's `apple:` id for the same
    /// route, and the route identity keeps two receivers apart.
    static func outputContextId(sink: String?, sinkType: String?) -> String {
        let identity = [outputContextLabel, sink ?? "", sinkType ?? ""].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "apple-airplay:" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    // MARK: - API base

    /// The base the plan's API-relative URLs resolve against: the signed-in
    /// server URL (`VividAPI.shared.currentServerUrl()`, which may carry a
    /// reverse-proxy subpath) plus `/api/v2`. Nil unless the plan came from a
    /// native v2 server (`plan.nativeApiMajor == 2`, set by
    /// `SiloAPICompatibility` on every reply HTTPClient routed to v2), since
    /// only the v2 delivery routes accept `st` without headers.
    static func apiBase(serverURL: String, nativeApiMajor: Int?) -> URL? {
        guard nativeApiMajor == 2 else { return nil }
        let server = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: server + apiPathSuffix), validatedAPIBase(base) != nil else { return nil }
        return base
    }

    // MARK: - Resolver

    /// The absolute URL the receiver fetches for a plan's stream URL.
    ///
    /// Accepted:
    /// - `/stream/{session}?st=…` and `/playback/transcode/{session}/master.m3u8?st=…`,
    ///   relative (with or without the leading `/api/v2`) or absolute on the
    ///   API base, for exactly `sessionId`. The result is on `apiBase` with
    ///   the original `st` (and an optional `seek`) query, byte for byte.
    /// - A signed proxy-form URL, `/stream/direct/{token}`, `/stream/remux/{token}`,
    ///   `/stream/remux/audio-v2/{token}` or `/stream/transcode/{token}/master.m3u8`,
    ///   on the API base's own origin, with no userinfo and no query.
    ///
    /// A relative path under the server's reverse-proxy subpath
    /// (`/silo/api/v2/…`) is refused: Silo doesn't know that subpath and
    /// always emits `/api/v2/…`, and `StreamRequest` refuses it the same way.
    ///
    /// Anything else throws, including any account credential in the query.
    static func receiverURL(planStreamURL: String, apiBase: URL, sessionId: String) throws -> URL {
        guard let base = validatedAPIBase(apiBase) else { throw SiloAirPlayReceiverError.unsupportedAPIBase }
        let session = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { throw SiloAirPlayReceiverError.emptySessionId }

        let raw = planStreamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("//"), !raw.contains("\\"),
              let components = URLComponents(string: raw), components.fragment == nil else {
            throw SiloAirPlayReceiverError.malformedURL
        }
        let items = components.queryItems ?? []
        if items.contains(where: { StreamRequest.credentialQueryNames.contains($0.name.lowercased()) }) {
            throw SiloAirPlayReceiverError.credentialInQuery
        }

        guard components.scheme != nil || components.host != nil else {
            // API-relative, with or without the API's own path prefix.
            var path = components.percentEncodedPath
            guard path.hasPrefix("/") else { throw SiloAirPlayReceiverError.unsupportedPath }
            if path.hasPrefix(apiPathSuffix + "/") {
                path.removeFirst(apiPathSuffix.count)
            } else if path.hasPrefix("/api/") {
                throw SiloAirPlayReceiverError.unsupportedPath
            }
            return try apiOriginURL(path: path, components: components, base: base, sessionId: session)
        }

        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw SiloAirPlayReceiverError.unsupportedOrigin
        }
        // A receiver attempt never negotiates authorised media origins, so an
        // absolute URL has to stay on the API's own origin (scheme, host and
        // port). A proxy node on another origin is refused and the hand-off
        // falls back to the phone.
        guard let absolute = components.url, StreamRequest.hasSameOrigin(absolute, base.url) else {
            throw SiloAirPlayReceiverError.unsupportedOrigin
        }
        if components.percentEncodedPath.hasPrefix(base.path + "/") {
            let path = String(components.percentEncodedPath.dropFirst(base.path.count))
            return try apiOriginURL(path: path, components: components, base: base, sessionId: session)
        }
        return try proxyURL(components: components)
    }

    /// The plan's stream URL without its signed `st` reference, everything
    /// else (path, other query items, their order and encoding) unchanged.
    /// For session state that's stored or logged: only the receiver needs
    /// the reference, and `receiverURL` reads it from the plan itself.
    static func strippingStreamReference(_ planStreamURL: String) -> String {
        guard let questionMark = planStreamURL.firstIndex(of: "?") else { return planStreamURL }
        let head = planStreamURL[..<questionMark]
        var query = planStreamURL[planStreamURL.index(after: questionMark)...]
        var fragment = Substring("")
        if let hash = query.firstIndex(of: "#") {
            fragment = query[hash...]
            query = query[..<hash]
        }
        let kept = query.split(separator: "&", omittingEmptySubsequences: false).filter { pair in
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return (String(name).removingPercentEncoding ?? String(name)) != "st"
        }
        let rebuilt = kept.joined(separator: "&")
        return String(head) + (rebuilt.isEmpty ? "" : "?" + rebuilt) + fragment
    }

    /// An `http(s)` base with a host, no userinfo, query or fragment, whose
    /// path ends in `/api/v2`. Returns the base with its path's trailing
    /// slashes removed.
    private static func validatedAPIBase(_ url: URL) -> (url: URL, scheme: String, path: String)? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        guard path.hasSuffix(apiPathSuffix), !hasEncodedSeparator(path),
              !hasDotSegment(path) else { return nil }
        components.percentEncodedPath = path
        guard let normalized = components.url else { return nil }
        return (normalized, scheme, path)
    }

    /// An API delivery route for the attempt's own session, signed with `st`.
    private static func apiOriginURL(
        path: String,
        components: URLComponents,
        base: (url: URL, scheme: String, path: String),
        sessionId: String
    ) throws -> URL {
        guard !hasEncodedSeparator(path), !hasDotSegment(path) else {
            throw SiloAirPlayReceiverError.unsupportedPath
        }
        let segments = decodedSegments(path)
        let pathSession: String
        switch segments.count {
        case 3 where segments[1] == "stream":
            pathSession = segments[2]
        case 5 where segments[1] == "playback" && segments[2] == "transcode" && segments[4] == "master.m3u8":
            pathSession = segments[3]
        default:
            throw SiloAirPlayReceiverError.unsupportedPath
        }
        guard segments[0].isEmpty, !pathSession.isEmpty else { throw SiloAirPlayReceiverError.unsupportedPath }
        guard pathSession == sessionId else { throw SiloAirPlayReceiverError.sessionMismatch }

        var seen = Set<String>()
        for item in components.queryItems ?? [] {
            guard seen.insert(item.name).inserted, let value = item.value, !value.isEmpty else {
                throw SiloAirPlayReceiverError.unexpectedQuery
            }
            switch item.name {
            case "st": break
            case "seek":
                guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else {
                    throw SiloAirPlayReceiverError.unexpectedQuery
                }
            default:
                throw SiloAirPlayReceiverError.unexpectedQuery
            }
        }
        guard seen.contains("st"), let query = components.percentEncodedQuery else {
            throw SiloAirPlayReceiverError.missingStreamReference
        }
        // The query is copied as it came, so the signed reference can't be
        // re-encoded on the way through.
        guard let url = URL(string: base.url.absoluteString + path + "?" + query) else {
            throw SiloAirPlayReceiverError.malformedURL
        }
        return url
    }

    /// A self-authenticating proxy-form URL on the API origin: the signed
    /// token is in the path, so any query is refused (the V3 proxy forms
    /// carry none once progressive is disabled).
    private static func proxyURL(components: URLComponents) throws -> URL {
        let path = components.percentEncodedPath
        guard !hasEncodedSeparator(path), !hasDotSegment(path) else {
            throw SiloAirPlayReceiverError.unsupportedPath
        }
        let segments = decodedSegments(path)
        guard segments.count >= 4, segments[0].isEmpty, segments[1] == "stream",
              segments.dropFirst().allSatisfy({ !$0.isEmpty }) else {
            throw SiloAirPlayReceiverError.unsupportedPath
        }
        let isProxyShape: Bool
        switch (segments[2], segments.count) {
        case ("direct", 4), ("remux", 4): isProxyShape = true
        case ("remux", 5): isProxyShape = segments[3] == "audio-v2"
        case ("transcode", 5): isProxyShape = segments[4] == "master.m3u8"
        default: isProxyShape = false
        }
        guard isProxyShape else { throw SiloAirPlayReceiverError.unsupportedPath }
        guard components.percentEncodedQuery == nil else { throw SiloAirPlayReceiverError.unexpectedQuery }
        guard let url = components.url else { throw SiloAirPlayReceiverError.malformedURL }
        return url
    }

    private static func decodedSegments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).removingPercentEncoding ?? String($0)
        }
    }

    private static func hasEncodedSeparator(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains("%2f") || lowered.contains("%5c") || path.contains("\\")
    }

    private static func hasDotSegment(_ path: String) -> Bool {
        decodedSegments(path).contains { $0 == "." || $0 == ".." }
    }

    // MARK: - Plan

    /// Throws unless the receiver can play the plan by itself: a server HLS
    /// stream, or an original MP4 family file, with no request headers and
    /// no client transformation.
    static func validate(_ plan: PlaybackV3Plan) throws {
        try ApplePlaybackV3PlanAdapter.validate(plan)
        let delivery = plan.delivery
        guard [PlaybackProtocolV3.PlanDelivery.originalHTTP,
               PlaybackProtocolV3.PlanDelivery.remuxHLS,
               PlaybackProtocolV3.PlanDelivery.transcodeHLS].contains(delivery) else {
            throw SiloAirPlayReceiverError.unsupportedDelivery(delivery)
        }
        guard plan.stream.headers.isEmpty, plan.stream.headerRefresh == "none" else {
            throw SiloAirPlayReceiverError.requiresHeaders
        }
        if let transformation = plan.transformations.first(where: { $0.executor == "client" }) {
            throw SiloAirPlayReceiverError.clientTransformation(transformation.name)
        }
        if delivery == PlaybackProtocolV3.PlanDelivery.originalHTTP {
            let container = (plan.stream.container ?? "").lowercased()
            let names = container.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard names.contains(where: { originalContainers.contains($0) }) else {
                throw SiloAirPlayReceiverError.unsupportedContainer(container)
            }
        }
    }

    /// The stream the receiver plays for a validated receiver attempt.
    ///
    /// `sourceOffset` is the plan's timeline offset (source time is player
    /// time plus the offset), so a transcode that starts mid-title maps back
    /// onto the source axis. `isTranscode` is true for both server HLS
    /// deliveries: each runs a server job that stopping the session ends.
    static func receiverStream(plan: PlaybackV3Plan, sessionId: String, apiBase: URL) throws -> AirPlayReceiverStream {
        try validate(plan)
        let timeline: PlaybackTimelineMapper
        do {
            timeline = try PlaybackTimelineMapper(validating: plan.timeline)
        } catch {
            throw SiloAirPlayReceiverError.invalidTimeline
        }
        let url = try receiverURL(planStreamURL: plan.stream.url, apiBase: apiBase, sessionId: sessionId)
        return AirPlayReceiverStream(
            url: url,
            sourceOffset: timeline.timelineOffsetSeconds,
            isTranscode: plan.delivery != PlaybackProtocolV3.PlanDelivery.originalHTTP,
            serverSessionId: sessionId,
            // A Silo receiver subtitle is only ever burnt into the video.
            showsSubtitleRendition: false
        )
    }
}
#endif
