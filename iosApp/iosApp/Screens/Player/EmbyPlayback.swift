import Foundation

/// One Emby playback session: negotiating the stream through PlaybackInfo,
/// and the play session's start, progress, ping and stop reports.
@MainActor
final class EmbyPlayback {
    let connection: EmbyConnection
    let itemID: String
    let sourceID: String
    let playSessionID: String
    let stream: StreamRequest
    /// `DirectPlay` or `Transcode`, as the reports send it.
    let method: String
    /// The audio and subtitle stream indexes the session asked for.
    let audioIndex: Int?
    let subtitleIndex: Int?
    /// The server stream index of each catalogue audio track, by ordinal.
    let audioStreamIndexes: [Int?]
    /// What's playing now, once the player has said; reports name these.
    private(set) var playingTracks: MediaServerPlayingTracks?
    private var lastPosition: Double
    private var started = false
    private var stopped = false

    init(connection: EmbyConnection, itemID: String, sourceID: String, playSessionID: String,
         stream: StreamRequest, method: String, audioIndex: Int?, subtitleIndex: Int?, position: Double,
         audioStreamIndexes: [Int?] = []) {
        self.connection = connection
        self.itemID = itemID
        self.sourceID = sourceID
        self.playSessionID = playSessionID
        self.stream = stream
        self.method = method
        self.audioIndex = audioIndex
        self.subtitleIndex = subtitleIndex
        self.lastPosition = position
        self.audioStreamIndexes = audioStreamIndexes
    }

    func update(playingTracks: MediaServerPlayingTracks) {
        self.playingTracks = playingTracks
    }

    /// Seconds as Emby's 100-nanosecond ticks: 0 for anything not positive
    /// and finite, `Int64.max` past the range.
    nonisolated static func ticks(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        guard seconds < Double(Int64.max / 10_000_000) else { return Int64.max }
        return Int64(seconds * 10_000_000)
    }

    // MARK: - PlaybackInfo

    /// Applies the device's and the chosen quality's limits to a PlaybackInfo
    /// body: codec profiles, the transcode size cap (the lower of the device
    /// ceiling and the quality's height), and turning off direct play and
    /// stream copy when the source is larger than that, or is HDR or Dolby
    /// Vision the display can't show.
    nonisolated static func applyPlaybackLimits(to body: inout [String: Any], source: [String: Any], quality: String?,
                                                hdr: Bool, dolbyVision: Bool, device: DeviceProfileVideoLimits) {
        let video = (source["MediaStreams"] as? [[String: Any]] ?? []).first { $0["Type"] as? String == "Video" } ?? [:]
        let range = ((video["VideoRangeType"] as? String ?? "") + " " + (video["VideoRange"] as? String ?? "")).lowercased()
        let isDolbyVision = (video["DvProfile"] as? Int ?? 0) > 0 || range.contains("dovi") || range.contains("dolby")
        let isHDR = isDolbyVision || range.contains("hdr") || range.contains("hlg")
        let qualityHeight = ApplePlaybackQuality.requestOptions.first { $0.id == quality }?.resolution
            .split(separator: "p").first.flatMap { Int($0) }
        let height = device.effectiveMaxHeight(qualityHeight: qualityHeight)
        let width = device.maxWidth

        var profile = body["DeviceProfile"] as? [String: Any] ?? [:]
        let codecProfiles = device.codecProfiles(qualityHeight: qualityHeight)
        if !codecProfiles.isEmpty { profile["CodecProfiles"] = codecProfiles }
        if let height {
            var transcodes = profile["TranscodingProfiles"] as? [[String: Any]] ?? []
            for index in transcodes.indices {
                transcodes[index]["MaxHeight"] = height
                if let width { transcodes[index]["MaxWidth"] = width }
            }
            profile["TranscodingProfiles"] = transcodes
        }

        let needsResize = height.map { (video["Height"] as? Int ?? 0) > $0 } ?? false
            || width.map { (video["Width"] as? Int ?? 0) > $0 } ?? false
        if needsResize || (!hdr && isHDR) || (!dolbyVision && isDolbyVision) {
            body["EnableDirectPlay"] = false
            body["EnableDirectStream"] = false
            body["AllowVideoStreamCopy"] = false
        }
        body["DeviceProfile"] = profile
    }

    /// The `POST /Items/{id}/PlaybackInfo` body.
    nonisolated static func playbackInfoBody(userID: String, sourceID: String, start: Double, audioIndex: Int?,
                                             subtitleIndex: Int?, bitrateKbps: Int?, source: [String: Any],
                                             quality: String?, device: DeviceProfileVideoLimits) -> [String: Any] {
        let deviceProfile: [String: Any] = [
            "Name": "Vivid",
            "MaxStreamingBitrate": (bitrateKbps ?? 200_000) * 1000,
            "DirectPlayProfiles": [[
                "Type": "Video",
                "Container": "mkv,mp4,m4v,mov,avi,ts,m2ts,webm",
                "VideoCodec": device.videoCodecs.joined(separator: ","),
                "AudioCodec": "aac,ac3,eac3,flac,alac,mp3,opus,vorbis,truehd,dts,pcm_s16le,pcm_s24le",
            ]],
            "TranscodingProfiles": [[
                "Type": "Video", "Container": "ts", "Protocol": "hls", "VideoCodec": "h264", "AudioCodec": "aac",
                "Context": "Streaming", "MaxAudioChannels": "2", "MinSegments": 2, "SegmentLength": 6,
            ]],
            "SubtitleProfiles": [
                ["Format": "srt", "Method": "External"], ["Format": "ass", "Method": "External"],
                ["Format": "ssa", "Method": "External"], ["Format": "vtt", "Method": "External"],
                ["Format": "pgssub", "Method": "Embed"], ["Format": "dvdsub", "Method": "Embed"],
            ],
        ]
        var body: [String: Any] = [
            "UserId": userID,
            "MediaSourceId": sourceID,
            "StartTimeTicks": ticks(start),
            "IsPlayback": true,
            "AutoOpenLiveStream": false,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "SubtitleStreamIndex": subtitleIndex ?? -1,
            "DeviceProfile": deviceProfile,
        ]
        if let bitrateKbps, bitrateKbps > 0 { body["MaxStreamingBitrate"] = bitrateKbps * 1000 }
        if let audioIndex { body["AudioStreamIndex"] = audioIndex }
        applyPlaybackLimits(to: &body, source: source, quality: quality, hdr: true, dolbyVision: true, device: device)
        return body
    }

    // MARK: - Preparing a session

    struct Metadata {
        let connection: EmbyConnection
        let raw: [String: Any]
        let detail: WatchDetail
    }

    static func loadMetadata(contentID: String) async throws -> Metadata {
        let connection = try await EmbyConnection.current()
        let adapter = EmbyAdapter(connection: connection)
        let raw = try await adapter.rawItem(contentID)
        let payload = try await adapter.watchWithPreferences(raw)
        let detail = try JSONDecoder().decode(WatchDetail.self, from: JSONSerialization.data(withJSONObject: payload))
        try await connection.validate()
        return Metadata(connection: connection, raw: raw, detail: detail)
    }

    /// Negotiates the stream for one file version and builds the session.
    /// A direct play streams the file statically; a transcode uses the
    /// server's `TranscodingUrl`, which must be on the server's origin and is
    /// stripped of credential and start-time query items.
    static func prepare(metadata: Metadata, detail: WatchDetail, version: FileVersion, start: Double,
                        audioOrdinal: Int?, subtitleIndex: Int?, bitrateKbps: Int?, quality: String?,
                        burnInSubtitleIndex: Int? = nil) async throws -> (PreparedPlayback, EmbyPlayback) {
        let connection = metadata.connection
        try await connection.validate()
        let sources = metadata.raw["MediaSources"] as? [[String: Any]] ?? []
        guard let source = sources.first(where: { ($0["Id"] as? String).map(EmbyAdapter.numberID) == version.fileId }),
              let sourceID = source["Id"] as? String else { throw EmbyError.playbackUnavailable }
        let audioStreams = (source["MediaStreams"] as? [[String: Any]] ?? []).filter { $0["Type"] as? String == "Audio" }
        let audioIndex = audioOrdinal.flatMap { audioStreams.indices.contains($0) ? audioStreams[$0]["Index"] as? Int : nil }

        let body = playbackInfoBody(userID: connection.userID!, sourceID: sourceID, start: start, audioIndex: audioIndex,
                                    subtitleIndex: subtitleIndex, bitrateKbps: bitrateKbps, source: source,
                                    quality: quality, device: .current)
        let itemPathID = try EmbyConnection.id(detail.contentId)
        let infoPath = "/Items/\(itemPathID)/PlaybackInfo"
        let info = try await connection.object("POST", infoPath, body: body)
        guard let offer = ServerSubtitleBurnIn.Offer(info, sourceID: sourceID) else { throw EmbyError.playbackUnavailable }
        let (chosen, transcodeSubtitles) = try await ServerSubtitleBurnIn.negotiate(
            offer, burnIn: burnInSubtitleIndex, sourceVideoCodec: version.codecVideo, body: body, sourceID: sourceID
        ) {
            try await connection.object("POST", infoPath, body: $0)
        }
        let playable = chosen.playable
        let playSessionID = chosen.playSessionID
        let direct = chosen.direct

        let url: URL
        let method: String
        if direct {
            url = try EmbyConnection.url(serverURL: connection.serverURL, path: "/Videos/\(itemPathID)/stream",
                                         query: ["Static": "true", "MediaSourceId": sourceID, "PlaySessionId": playSessionID])
            method = "DirectPlay"
        } else if let rawURL = playable["TranscodingUrl"] as? String,
                  let base = URL(string: connection.serverURL),
                  let candidate = URL(string: rawURL, relativeTo: base)?.absoluteURL,
                  StreamRequest.hasSameOrigin(candidate, base),
                  candidate.user == nil, candidate.password == nil {
            var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false)!
            components.queryItems = components.queryItems?.filter {
                !["api_key", "x-emby-token", "starttimeticks"].contains($0.name.lowercased())
            }
            guard let resolved = components.url else { throw EmbyError.invalidURL }
            url = resolved
            method = "Transcode"
        } else {
            throw EmbyError.playbackUnavailable
        }

        // Text subtitle files beside the media, and every text track while
        // transcoding (the transcode leaves them out), mount as sidecars.
        var subtitles: [SubtitleUrl] = []
        for track in playable["MediaStreams"] as? [[String: Any]] ?? []
        where track["Type"] as? String == "Subtitle" && (track["IsExternal"] as? Bool == true || !direct) {
            guard let index = track["Index"] as? Int, let codec = track["Codec"] as? String,
                  ServerSubtitleSidecars.isMountable(codec: codec) else { continue }
            let format = ServerSubtitleSidecars.format(codec)
            let subtitleURL = try EmbyConnection.url(
                serverURL: connection.serverURL,
                path: "/Videos/\(itemPathID)/\(EmbyConnection.id(sourceID))/Subtitles/\(index)/Stream.\(format)")
            subtitles.append(SubtitleUrl(index: index, language: track["Language"] as? String, codec: format,
                                         label: track["DisplayTitle"] as? String, source: "external",
                                         forced: track["IsForced"] as? Bool, default: track["IsDefault"] as? Bool,
                                         hearingImpaired: track["IsHearingImpaired"] as? Bool,
                                         url: subtitleURL.absoluteString))
        }

        let session = PlaybackSessionResponse(
            sessionId: playSessionID, userId: nil, profileId: connection.userID, mediaFileId: version.fileId,
            playMethod: method, position: start, isPaused: false, streamUrl: url.absoluteString,
            audioTrackIndex: audioOrdinal, durationSeconds: version.duration, subtitleUrls: subtitles,
            playbackInfo: PlaybackInfo(streamType: direct ? "direct" : "hls", transcodeAudio: !direct,
                                       videoCodec: direct ? version.codecVideo : "h264",
                                       audioCodec: direct ? version.codecAudio : "aac"))
        let playback = EmbyPlayback(
            connection: connection, itemID: detail.contentId, sourceID: sourceID, playSessionID: playSessionID,
            stream: StreamRequest(url: url, headers: connection.headers, serverUrl: connection.serverURL),
            method: method, audioIndex: audioIndex,
            subtitleIndex: transcodeSubtitles?.burnedIndex ?? subtitleIndex, position: start,
            audioStreamIndexes: audioStreams.map { $0["Index"] as? Int })
        try await connection.validate()
        let prepared = PreparedPlayback(
            watchDetail: detail, selectedVersion: version, session: session,
            activeQualityId: quality ?? ApplePlaybackQuality.autoId, bandwidthCap: .inEffect(bitrateKbps),
            nativeAudioStreamIndex: direct ? audioIndex.flatMap(Int32.init(exactly:)) : nil,
            nativeHLS: !direct, transcodeSubtitles: transcodeSubtitles,
            nativeQualityOptions: playable["SupportsTranscoding"] as? Bool == true
                ? ApplePlaybackQuality.settingsOptions
                : [ApplePlaybackQuality.auto, ApplePlaybackQuality.original])
        return (prepared, playback)
    }

    // MARK: - Reports

    func ping() async throws {
        guard !stopped else { return }
        _ = try await connection.request("POST", "/Sessions/Playing/Ping", query: ["PlaySessionId": playSessionID])
    }

    /// Ends a load that never reached its first frame without a watch
    /// progress session: nothing is reported, and a transcode is cleared.
    func stopWithoutProgress() async throws {
        guard !stopped else { return }
        if method == "Transcode" {
            _ = try await connection.request("DELETE", "/Videos/ActiveEncodings",
                                             query: ["DeviceId": EmbyConnection.deviceID, "PlaySessionId": playSessionID])
        }
        stopped = true
    }

    /// Reports the position, starting the play session on the first report.
    /// A stopping report ends it and clears a transcode.
    func report(position: Double, isPaused: Bool, stopping: Bool = false) async throws {
        guard !stopped else { return }
        lastPosition = position.isFinite ? max(0, position) : lastPosition
        let streams = (playingTracks ?? MediaServerPlayingTracks()).streamIndexes(
            audioStreamIndexes: audioStreamIndexes, directPlay: method == "DirectPlay",
            initialAudio: audioIndex, initialSubtitle: subtitleIndex)
        var body: [String: Any] = [
            "ItemId": itemID,
            "MediaSourceId": sourceID,
            "PlaySessionId": playSessionID,
            "PositionTicks": Self.ticks(lastPosition),
            "IsPaused": isPaused,
            "CanSeek": true,
            "PlayMethod": method,
            "QueueableMediaTypes": ["Video"],
            "EventName": "TimeUpdate",
            "SubtitleStreamIndex": streams.subtitle,
        ]
        if let audio = streams.audio { body["AudioStreamIndex"] = audio }
        if !started, !stopping {
            _ = try await connection.request("POST", "/Sessions/Playing", body: body)
            started = true
        }
        _ = try await connection.request("POST", stopping ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress",
                                         body: body)
        if stopping {
            stopped = true
            if method == "Transcode" {
                _ = try? await connection.request("DELETE", "/Videos/ActiveEncodings",
                                                  query: ["DeviceId": EmbyConnection.deviceID, "PlaySessionId": playSessionID])
            }
        }
    }
}
