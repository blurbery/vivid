import Foundation

/// A server stream an AirPlay receiver fetches and plays by itself.
///
/// The receiver can't send HTTP headers, so `url` carries its own credential
/// (a Jellyfin `ApiKey`, an Emby `api_key` or a Silo signed stream reference).
/// Never log, trace, persist or put it in diagnostics.
///
/// Its description, debug description and mirror leave the URL out, so
/// printing, `dump` or string interpolation never reveal it.
struct AirPlayReceiverStream: Sendable, Equatable {
    let url: URL
    /// Source-axis seconds at which the stream's time zero sits (0 for a stream that starts at the beginning).
    let sourceOffset: Double
    /// True when the server is transcoding (so stopping must also end the transcode).
    let isTranscode: Bool
    /// The server's play session the stream belongs to (an Emby or Jellyfin
    /// `PlaySessionId`, or a Silo session id), so an abandoned receiver
    /// session can be stopped. Not a secret.
    let serverSessionId: String?
    /// True only when the server delivers the chosen subtitle as an HLS
    /// WebVTT rendition that the player must select. False with no subtitle,
    /// or when it's drawn into the video.
    let showsSubtitleRendition: Bool
}

extension AirPlayReceiverStream: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "AirPlayReceiverStream(sourceOffset: \(sourceOffset), isTranscode: \(isTranscode), "
            + "serverSessionId: \(serverSessionId ?? "nil"), showsSubtitleRendition: \(showsSubtitleRendition), "
            + "url: [redacted])"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [
            "sourceOffset": sourceOffset, "isTranscode": isTranscode,
            "serverSessionId": serverSessionId as Any, "showsSubtitleRendition": showsSubtitleRendition,
            "url": "[redacted]",
        ], displayStyle: .struct)
    }
}

/// What an AirPlay receiver (Apple TV, an AirPlay smart TV or a car) is
/// trusted to play from an Emby or Jellyfin server. It's a fixed,
/// conservative profile rather than this device's own decode limits: a direct
/// MP4, MOV or M4V, or HLS, with H.264 or HEVC video in SDR, HDR10 or HLG, and
/// AAC, AC-3 or E-AC-3 audio.
enum MediaServerAirPlayReceiver {
    static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]
    static let videoCodecs: Set<String> = ["h264", "hevc"]
    /// Default `MaxStreamingBitrate` in kbps when the user hasn't capped it.
    static let defaultBitrateKbps = 200_000
    /// H.264 stays at 1080p, so a source re-encoded to H.264 (Dolby Vision or
    /// HDR10+ forced off HEVC) never becomes a 4K H.264 transcode. HEVC may
    /// go to 2160p.
    static let h264MaxWidth = 1_920
    static let h264MaxHeight = 1_080

    /// The profile's `MaxStreamingBitrate` in bits per second: the user's cap
    /// when it's positive, otherwise the default.
    static func maxStreamingBitrate(_ bitrateKbps: Int?) -> Int {
        (bitrateKbps.flatMap { $0 > 0 ? $0 : nil } ?? defaultBitrateKbps) * 1000
    }

    /// Caps an H.264-only transcoding profile at 1080p.
    static func cappingH264(_ profile: [String: Any]) -> [String: Any] {
        guard profile["VideoCodec"] as? String == "h264" else { return profile }
        var capped = profile
        capped["MaxWidth"] = h264MaxWidth
        capped["MaxHeight"] = h264MaxHeight
        return capped
    }

    /// Whether the server delivers subtitle `index` as an HLS WebVTT
    /// rendition: never for a direct play; for a transcode, its URL names the
    /// stream with `SubtitleMethod=Hls`, or without a method there, the
    /// stream's `DeliveryMethod` in the same answer is `Hls`.
    static func deliversSubtitleRendition(_ index: Int?, direct: Bool, transcodingURL: String?,
                                          mediaStreams: [[String: Any]]) -> Bool {
        guard let index, index >= 0, !direct else { return false }
        var query: [String: String] = [:]
        for item in URLComponents(string: transcodingURL ?? "")?.queryItems ?? [] where query[item.name.lowercased()] == nil {
            query[item.name.lowercased()] = item.value ?? ""
        }
        if let method = query["subtitlemethod"] {
            return query["subtitlestreamindex"].flatMap { Int($0) } == index
                && method.caseInsensitiveCompare("Hls") == .orderedSame
        }
        let stream = mediaStreams.first { $0["Type"] as? String == "Subtitle" && $0["Index"] as? Int == index }
        return (stream?["DeliveryMethod"] as? String)?.caseInsensitiveCompare("Hls") == .orderedSame
    }

    /// Text subtitles travel as HLS WebVTT renditions and bitmap ones are
    /// drawn into the video. A receiver can't fetch a sidecar or show an
    /// embedded track Vivid picked, so there are no External or Embed rows.
    static var subtitleProfiles: [[String: Any]] {
        let text = ["srt", "subrip", "ass", "ssa", "vtt", "mov_text"].map { ["Format": $0, "Method": "Hls"] }
        let bitmap = ["pgssub", "dvdsub", "dvbsub"].map { ["Format": $0, "Method": "Encode"] }
        return text + bitmap
    }

    /// The receiver's codec limits. `rangeTypes` adds Jellyfin's
    /// `VideoRangeType` conditions, which Emby doesn't define. A non-default
    /// audio track can't be picked inside a static file, so that forces HLS.
    static func codecProfiles(rangeTypes: Bool) -> [[String: Any]] {
        func condition(_ kind: String, _ property: String, _ value: String) -> [String: Any] {
            ["Condition": kind, "Property": property, "Value": value, "IsRequired": false]
        }
        var h264 = [condition("LessThanEqual", "Width", String(h264MaxWidth)),
                    condition("LessThanEqual", "Height", String(h264MaxHeight)),
                    condition("LessThanEqual", "VideoBitDepth", "8"),
                    condition("EqualsAny", "VideoProfile", "high|main|baseline|constrained baseline")]
        var hevc = [condition("LessThanEqual", "VideoBitDepth", "10"),
                    condition("EqualsAny", "VideoProfile", "main|main 10")]
        if rangeTypes {
            h264.append(condition("EqualsAny", "VideoRangeType", "SDR"))
            hevc.append(condition("EqualsAny", "VideoRangeType", "SDR|HDR10|HLG"))
        }
        return [
            ["Type": "Video", "Conditions": [condition("LessThanEqual", "Width", "3840"),
                                             condition("LessThanEqual", "Height", "2160")]],
            ["Type": "Video", "Codec": "h264", "Conditions": h264],
            ["Type": "Video", "Codec": "hevc", "Conditions": hevc],
            ["Type": "VideoAudio", "Conditions": [condition("Equals", "IsSecondaryAudio", "false")]],
        ]
    }

    /// The source's video stream.
    static func video(in source: [String: Any]) -> [String: Any] {
        (source["MediaStreams"] as? [[String: Any]] ?? []).first { $0["Type"] as? String == "Video" } ?? [:]
    }

    /// Whether the source's dynamic range is one a receiver is trusted to
    /// show as it is: SDR, HDR10 or HLG. Dolby Vision of any profile,
    /// HDR10+ and anything unrecognised are not, so they're re-encoded.
    static func hasReceiverSafeRange(_ source: [String: Any]) -> Bool {
        let video = Self.video(in: source)
        if (video["DvProfile"] as? Int ?? 0) > 0 { return false }
        let range = (video["VideoRange"] as? String ?? "").lowercased()
        // Jellyfin names the range type; "Unknown" with an SDR range is SDR.
        if let type = (video["VideoRangeType"] as? String)?.lowercased(), !type.isEmpty,
           !["sdr", "hdr10", "hlg"].contains(type), !(type == "unknown" && range == "sdr") { return false }
        // Emby names HDR formats as an extended video type.
        if let type = (video["ExtendedVideoType"] as? String)?.lowercased(), !type.isEmpty,
           !["none", "hdr10", "hyperloggamma"].contains(type) { return false }
        let rangeType = (video["VideoRangeType"] as? String ?? "").lowercased()
        let extendedType = (video["ExtendedVideoType"] as? String ?? "").lowercased()
        // HDR the server doesn't name could be Dolby Vision.
        if rangeType.isEmpty, extendedType.isEmpty, range.contains("hdr") { return false }
        let text = range + " " + rangeType
        return !["dovi", "dolby", "hdr10+", "hdr 10+", "hdr10plus"].contains { text.contains($0) }
    }

    /// Whether a static file can go to the receiver as it is: an MP4, M4V or
    /// MOV container (Jellyfin reports a comma list such as
    /// `mov,mp4,m4a,3gp,3g2,mj2`) with H.264 or HEVC video. Never MKV, and
    /// never HEVC tagged anything but `hvc1`, which Apple players won't open
    /// as a file (a transcode retags it).
    static func isDirectPlayable(_ source: [String: Any]) -> Bool {
        let containers = Set((source["Container"] as? String ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        let video = Self.video(in: source)
        let codec = (video["Codec"] as? String ?? "").lowercased()
        if codec == "hevc", let tag = (video["CodecTag"] as? String)?.lowercased(), !tag.isEmpty, tag != "hvc1" {
            return false
        }
        return !containers.isDisjoint(with: directPlayContainers) && videoCodecs.contains(codec)
    }

    /// Turns off what the receiver can't take from this source: direct play
    /// of anything but MP4, M4V or MOV with H.264 or HEVC, and any copy of a
    /// range it isn't trusted with, which also limits the transcode to H.264
    /// so the server tone maps rather than sending HDR or Dolby Vision.
    static func applySourceLimits(to body: inout [String: Any], source: [String: Any]) {
        if !isDirectPlayable(source) { body["EnableDirectPlay"] = false }
        guard !hasReceiverSafeRange(source) else { return }
        body["EnableDirectPlay"] = false
        body["EnableDirectStream"] = false
        body["AllowVideoStreamCopy"] = false
        var profile = body["DeviceProfile"] as? [String: Any] ?? [:]
        var transcodes = profile["TranscodingProfiles"] as? [[String: Any]] ?? []
        for index in transcodes.indices {
            transcodes[index]["VideoCodec"] = "h264"
            transcodes[index] = cappingH264(transcodes[index])
        }
        profile["TranscodingProfiles"] = transcodes
        body["DeviceProfile"] = profile
    }

    /// `url` with every credential query item removed and exactly one
    /// `name=token` added. Nil without a token.
    static func addingCredential(_ name: String, token: String?, to url: URL) -> URL? {
        guard let token, !token.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter {
            !StreamRequest.credentialQueryNames.contains($0.name.lowercased())
        }
        items.append(URLQueryItem(name: name, value: token))
        components.queryItems = items
        return components.url
    }

    /// A server `TranscodingUrl` resolved against `base`, kept only on the
    /// server's origin and without user info, and stripped of credential and
    /// start-time query items (the player seeks).
    static func cleanTranscodingURL(_ raw: String, base: URL) -> URL? {
        guard let candidate = URL(string: raw, relativeTo: base)?.absoluteURL,
              StreamRequest.hasSameOrigin(candidate, base),
              candidate.user == nil, candidate.password == nil,
              var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = components.queryItems?.filter {
            let name = $0.name.lowercased()
            return !StreamRequest.credentialQueryNames.contains(name) && name != "starttimeticks"
        }
        return components.url
    }
}
