import Foundation
import OSLog

/// What an Emby or Jellyfin transcode does with bitmap subtitles. Only text
/// subtitles travel beside an HLS transcode, so PGS, VobSub and DVB tracks
/// show there only when the server draws them into the video.
struct ServerTranscodeSubtitles: Equatable {
    /// The subtitle stream the server confirmed it draws into the video.
    var burnedIndex: Int?
    /// A stream that was asked for but not confirmed. Playback goes on
    /// without it.
    var failedIndex: Int?
    /// The burn-in request didn't get an answer (a dropped connection, a
    /// timeout, a server error), so asking again later may work.
    var failureIsTemporary = false
    /// The transcode only repackages the video, so drawing a subtitle in
    /// would add a full video encode on the server.
    var copiesVideo: Bool
}

enum ServerSubtitleBurnIn {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "Playback"
    )

    /// One PlaybackInfo answer for the requested media source.
    struct Offer {
        let playable: [String: Any]
        let playSessionID: String

        init?(_ info: [String: Any], sourceID: String) {
            guard info["ErrorCode"] == nil || info["ErrorCode"] is NSNull,
                  let playable = (info["MediaSources"] as? [[String: Any]])?.first(where: { $0["Id"] as? String == sourceID }),
                  let playSessionID = info["PlaySessionId"] as? String else { return nil }
            self.playable = playable
            self.playSessionID = playSessionID
        }

        var direct: Bool { playable["SupportsDirectPlay"] as? Bool == true }
        var transcodingURL: String? { playable["TranscodingUrl"] as? String }
        var mediaStreams: [[String: Any]] { playable["MediaStreams"] as? [[String: Any]] ?? [] }
    }

    /// The load's subtitle pick, when it names a bitmap track of this file.
    static func bitmapStreamIndex(_ index: Int?, in version: FileVersion) -> Int? {
        guard let index, index >= 0,
              let track = (version.subtitleTracks ?? []).first(where: { $0.index == index }),
              SubtitleCodecClassifier.isBitmap(track.codec) else { return nil }
        return index
    }

    /// Asks for the bitmap subtitle `index` to be drawn into the video, but
    /// only once `offer` (asked without a subtitle) says the server will
    /// transcode. A direct play keeps the file as it is: Lucid Engine draws
    /// PGS, VobSub and DVB itself, and asking the server for a subtitle it
    /// can't embed would make it transcode just for that. When the server
    /// doesn't confirm the burn-in, or the request gets no answer, playback
    /// goes on with `offer`.
    @MainActor
    static func negotiate(
        _ offer: Offer,
        burnIn index: Int?,
        sourceVideoCodec: String?,
        body: [String: Any],
        sourceID: String,
        post: ([String: Any]) async throws -> [String: Any]
    ) async throws -> (offer: Offer, subtitles: ServerTranscodeSubtitles?) {
        guard !offer.direct else { return (offer, nil) }
        // Vivid itself rules out a copy when the size or range must change.
        let copiesVideo = body["AllowVideoStreamCopy"] as? Bool != false
            && copiesVideo(transcodingURL: offer.transcodingURL, sourceVideoCodec: sourceVideoCodec)
        guard let index else {
            return (offer, ServerTranscodeSubtitles(burnedIndex: nil, failedIndex: nil, copiesVideo: copiesVideo))
        }
        var burnBody = body
        burnBody["SubtitleStreamIndex"] = index
        let answer: [String: Any]
        do {
            answer = try await post(burnBody)
        } catch {
            try Task.checkCancellation()
            logger.warning("[CMP-SUB] server burn-in request failed; playing without it this time")
            return (offer, ServerTranscodeSubtitles(burnedIndex: nil, failedIndex: index, failureIsTemporary: true,
                                                    copiesVideo: copiesVideo))
        }
        if let burned = Offer(answer, sourceID: sourceID), !burned.direct,
           confirms(index, transcodingURL: burned.transcodingURL, mediaStreams: burned.mediaStreams) {
            logger.info("[CMP-SUB] server burn-in confirmed copiesVideo=\(copiesVideo, privacy: .public)")
            return (burned, ServerTranscodeSubtitles(burnedIndex: index, failedIndex: nil, copiesVideo: copiesVideo))
        }
        logger.warning("[CMP-SUB] server burn-in not confirmed; playing without it")
        return (offer, ServerTranscodeSubtitles(burnedIndex: nil, failedIndex: index, copiesVideo: copiesVideo))
    }

    /// Emby and Jellyfin name a burn-in in the transcode URL:
    /// `SubtitleStreamIndex` with `SubtitleMethod=Encode`. Without a method
    /// in the URL, the subtitle's `DeliveryMethod` in the same answer decides.
    static func confirms(_ index: Int, transcodingURL: String?, mediaStreams: [[String: Any]]) -> Bool {
        let query = queryValues(transcodingURL)
        guard query["subtitlestreamindex"].flatMap({ Int($0) }) == index else { return false }
        if let method = query["subtitlemethod"] {
            return method.caseInsensitiveCompare("Encode") == .orderedSame
        }
        let stream = mediaStreams.first { $0["Type"] as? String == "Subtitle" && $0["Index"] as? Int == index }
        return (stream?["DeliveryMethod"] as? String)?.caseInsensitiveCompare("Encode") == .orderedSame
    }

    /// `TranscodeReasons` that leave the video stream as it is.
    private static let videoCopyReasons: Set<String> = [
        "containernotsupported", "audiocodecnotsupported", "audioisexternal", "secondaryaudionotsupported",
        "audiochannelsnotsupported", "audioprofilenotsupported", "audiosampleratenotsupported",
        "audiobitdepthnotsupported", "audiobitratenotsupported", "unknownaudiostreaminfo", "directplayerror",
    ]

    /// Whether the transcode only repackages the video. Vivid's transcoding
    /// profile asks for H.264, so any other source is encoded again, and so
    /// is H.264 when a reason touches the video (bitrate, size, range).
    static func copiesVideo(transcodingURL: String?, sourceVideoCodec: String?) -> Bool {
        guard ["h264", "avc"].contains(sourceVideoCodec?.lowercased() ?? "") else { return false }
        let query = queryValues(transcodingURL)
        if query["allowvideostreamcopy"]?.lowercased() == "false" { return false }
        let reasons = (query["transcodereasons"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return !reasons.isEmpty && reasons.allSatisfy(videoCopyReasons.contains)
    }

    /// Picker rows for the file's bitmap tracks on a transcode. They use the
    /// server sidecar id space, keyed by the server stream index, and have no
    /// FFmpeg index, so they never match an engine track. Callers append them
    /// after the tracks Vivid plays itself, so a text track wins a tie.
    static func rows(version: FileVersion?, excluding failed: Set<Int>) -> [PlayerTrack] {
        (version?.subtitleTracks ?? []).compactMap { track in
            guard let index = track.index, index >= 0, !failed.contains(index),
                  SubtitleCodecClassifier.isBitmap(track.codec) else { return nil }
            return PlayerTrack(
                trackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: index),
                kind: .sub,
                title: track.title ?? track.embeddedTitle,
                lang: track.language,
                codec: track.codec,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: track.isDefault ?? false,
                isForced: track.forced ?? false,
                isHearingImpaired: track.hearingImpaired ?? false,
                isExternal: track.external == true,
                isSelected: false,
                ffIndex: nil,
                srcId: index
            )
        }
    }

    /// What a subtitle choice on a transcode needs from the server.
    enum Reload: Equatable {
        /// The server already sends what was chosen.
        case none
        /// Reload with this stream drawn into the video.
        case burnIn(Int)
        /// Reload without the subtitle that's drawn in now.
        case removeBurnIn
    }

    /// `wanted` is the stream index of the chosen burn-in row, or nil for any
    /// other choice (Off, a text track, an OpenSubtitles file).
    static func reload(wanted: Int?, burned: Int?) -> Reload {
        if wanted == burned { return .none }
        if let wanted { return .burnIn(wanted) }
        return .removeBurnIn
    }

    private static func queryValues(_ raw: String?) -> [String: String] {
        guard let raw, let components = URLComponents(string: raw) else { return [:] }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name.lowercased()] == nil {
            values[item.name.lowercased()] = item.value ?? ""
        }
        return values
    }
}
