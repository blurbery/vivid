import Foundation

/// Emby streams for an AirPlay receiver: a PlaybackInfo request with the
/// receiver's profile instead of this device's, and a stream URL that carries
/// its own `api_key`, because the receiver fetches it without Vivid's headers.
extension EmbyPlayback {
    /// The one credential query item a receiver URL carries.
    nonisolated static let receiverCredentialName = "api_key"

    /// The `POST /Items/{id}/PlaybackInfo` body for an AirPlay receiver. It
    /// starts at 0 (the receiver's player seeks), keeps the user's bitrate
    /// cap, and transcodes to MPEG-TS HLS with H.264 (Emby's fragmented MP4
    /// HLS isn't verified).
    nonisolated static func airPlayPlaybackInfoBody(userID: String, sourceID: String, audioIndex: Int?,
                                                    subtitleIndex: Int?, bitrateKbps: Int?,
                                                    source: [String: Any]) -> [String: Any] {
        let deviceProfile: [String: Any] = [
            "Name": "Vivid AirPlay",
            "MaxStreamingBitrate": MediaServerAirPlayReceiver.maxStreamingBitrate(bitrateKbps),
            "DirectPlayProfiles": [[
                "Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,alac",
            ]],
            "TranscodingProfiles": [MediaServerAirPlayReceiver.cappingH264([
                "Type": "Video", "Container": "ts", "Protocol": "hls", "VideoCodec": "h264", "AudioCodec": "aac,ac3,eac3",
                "Context": "Streaming", "MaxAudioChannels": "6", "MinSegments": 2, "SegmentLength": 6,
            ])],
            "CodecProfiles": MediaServerAirPlayReceiver.codecProfiles(rangeTypes: false),
            "SubtitleProfiles": MediaServerAirPlayReceiver.subtitleProfiles,
        ]
        var body: [String: Any] = [
            "UserId": userID,
            "MediaSourceId": sourceID,
            "StartTimeTicks": 0,
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
        MediaServerAirPlayReceiver.applySourceLimits(to: &body, source: source)
        return body
    }

    /// The stream URL without any credential: the static file for a direct
    /// play (`transcodingURL` nil), otherwise the server's `TranscodingUrl`,
    /// resolved and stripped the same way as for Lucid Engine.
    nonisolated static func airPlayStreamURL(serverURL: String, itemPathID: String, sourceID: String,
                                             playSessionID: String, transcodingURL: String?) throws -> URL {
        guard let transcodingURL else {
            return try EmbyConnection.url(serverURL: serverURL, path: "/Videos/\(itemPathID)/stream",
                                          query: ["Static": "true", "MediaSourceId": sourceID,
                                                  "PlaySessionId": playSessionID])
        }
        guard let base = URL(string: serverURL),
              let url = MediaServerAirPlayReceiver.cleanTranscodingURL(transcodingURL, base: base)
        else { throw EmbyError.invalidURL }
        return url
    }

    /// `streamURL` with exactly one credential, `api_key`, for the receiver.
    /// The result is a secret: never log, trace or store it.
    nonisolated static func receiverURL(_ streamURL: URL, token: String?) throws -> URL {
        guard let url = MediaServerAirPlayReceiver.addingCredential(receiverCredentialName, token: token, to: streamURL)
        else { throw EmbyError.signInRequired }
        return url
    }

    /// Negotiates a stream an AirPlay receiver plays by itself, for the same
    /// title, version and tracks. It's a new play session: adopt `playback`
    /// for reporting (it starts, progresses and stops like any other, and a
    /// stop clears the receiver's transcode) and `prepared.session` as the
    /// bridge's current session. Neither holds the credential; only
    /// `stream.url` does.
    ///
    /// `subtitleIndex` is the server stream index of a subtitle in the file
    /// (nil for none). The receiver profile has text subtitles sent as HLS
    /// renditions and bitmap ones drawn in by the server, so there's no
    /// separate burn-in step. `position` is only the session's starting
    /// report position; the stream itself starts at 0.
    static func prepareAirPlayReceiver(
        metadata: Metadata, detail: WatchDetail, version: FileVersion, audioOrdinal: Int?, subtitleIndex: Int?,
        bitrateKbps: Int?, position: Double = 0
    ) async throws -> (stream: AirPlayReceiverStream, prepared: PreparedPlayback, playback: EmbyPlayback) {
        let connection = metadata.connection
        try await connection.validate()
        guard let userID = connection.userID, connection.token?.isEmpty == false else {
            throw EmbyError.signInRequired
        }
        let sources = metadata.raw["MediaSources"] as? [[String: Any]] ?? []
        guard let source = sources.first(where: { ($0["Id"] as? String).map(EmbyAdapter.numberID) == version.fileId }),
              let sourceID = source["Id"] as? String else { throw EmbyError.playbackUnavailable }
        let audioStreams = (source["MediaStreams"] as? [[String: Any]] ?? []).filter { $0["Type"] as? String == "Audio" }
        let audioIndex = audioOrdinal.flatMap { audioStreams.indices.contains($0) ? audioStreams[$0]["Index"] as? Int : nil }

        let body = airPlayPlaybackInfoBody(userID: userID, sourceID: sourceID, audioIndex: audioIndex,
                                           subtitleIndex: subtitleIndex, bitrateKbps: bitrateKbps, source: source)
        let itemPathID = try EmbyConnection.id(detail.contentId)
        let info = try await connection.object("POST", "/Items/\(itemPathID)/PlaybackInfo", body: body)
        guard let offer = ServerSubtitleBurnIn.Offer(info, sourceID: sourceID) else { throw EmbyError.playbackUnavailable }
        // Never a static file the receiver can't open, whatever the server says.
        let direct = offer.direct && MediaServerAirPlayReceiver.isDirectPlayable(offer.playable)
        guard direct || offer.transcodingURL != nil else { throw EmbyError.playbackUnavailable }

        let streamURL = try airPlayStreamURL(serverURL: connection.serverURL, itemPathID: itemPathID, sourceID: sourceID,
                                             playSessionID: offer.playSessionID,
                                             transcodingURL: direct ? nil : offer.transcodingURL)
        let receiver = try receiverURL(streamURL, token: connection.token)
        let method = direct ? "DirectPlay" : "Transcode"
        let session = PlaybackSessionResponse(
            sessionId: offer.playSessionID, userId: nil, profileId: connection.userID, mediaFileId: version.fileId,
            playMethod: method, position: position, isPaused: false, streamUrl: streamURL.absoluteString,
            audioTrackIndex: audioOrdinal, durationSeconds: version.duration, subtitleUrls: [],
            playbackInfo: PlaybackInfo(streamType: direct ? "direct" : "hls", transcodeAudio: !direct,
                                       videoCodec: direct ? version.codecVideo : nil,
                                       audioCodec: direct ? version.codecAudio : nil))
        let playback = EmbyPlayback(
            connection: connection, itemID: detail.contentId, sourceID: sourceID, playSessionID: offer.playSessionID,
            stream: StreamRequest(url: streamURL, headers: connection.headers, serverUrl: connection.serverURL),
            method: method, audioIndex: audioIndex, subtitleIndex: subtitleIndex, position: position,
            audioStreamIndexes: audioStreams.map { $0["Index"] as? Int })
        try await connection.validate()
        let prepared = PreparedPlayback(
            watchDetail: detail, selectedVersion: version, session: session,
            bandwidthCap: .inEffect(bitrateKbps), nativeHLS: !direct)
        let rendition = MediaServerAirPlayReceiver.deliversSubtitleRendition(
            subtitleIndex, direct: direct, transcodingURL: offer.transcodingURL, mediaStreams: offer.mediaStreams)
        let stream = AirPlayReceiverStream(url: receiver, sourceOffset: 0, isTranscode: !direct,
                                           serverSessionId: offer.playSessionID, showsSubtitleRendition: rendition)
        return (stream, prepared, playback)
    }
}
