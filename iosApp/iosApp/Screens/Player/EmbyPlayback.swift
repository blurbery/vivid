import Foundation
import VividKit

@MainActor
final class EmbyPlayback {
    let connection: EmbyConnection
    let itemID: String
    let sourceID: String
    let playSessionID: String
    let stream: StreamRequest
    let method: String
    let audioIndex: Int?
    let subtitleIndex: Int?
    private var lastPosition: Double
    private var started = false
    private var stopped = false

    init(connection: EmbyConnection, itemID: String, sourceID: String, playSessionID: String,
         stream: StreamRequest, method: String, audioIndex: Int?, subtitleIndex: Int?, position: Double) {
        self.connection = connection; self.itemID = itemID; self.sourceID = sourceID
        self.playSessionID = playSessionID; self.stream = stream; self.method = method
        self.audioIndex = audioIndex; self.subtitleIndex = subtitleIndex; lastPosition = position
    }

    nonisolated static func ticks(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        guard seconds < Double(Int64.max / 10_000_000) else { return Int64.max }
        return Int64(seconds * 10_000_000)
    }

    nonisolated static func applyPlaybackLimits(to body: inout [String:Any], source: [String:Any], quality: String?, hdr: Bool, dolbyVision: Bool) {
        let video = (source["MediaStreams"] as? [[String:Any]] ?? []).first { $0["Type"] as? String == "Video" } ?? [:]
        let range = ((video["VideoRangeType"] as? String ?? "") + " " + (video["VideoRange"] as? String ?? "")).lowercased()
        let isDV = (video["DvProfile"] as? Int ?? 0) > 0 || range.contains("dovi") || range.contains("dolby")
        let isHDR = isDV || range.contains("hdr") || range.contains("hlg")
        let height = ApplePlaybackQuality.requestOptions.first { $0.id == quality }?.resolution
            .split(separator:"p").first.flatMap { Int($0) }
        var profile = body["DeviceProfile"] as? [String:Any] ?? [:]
        if let height {
            profile["CodecProfiles"] = [["Type":"Video","Conditions":[["Condition":"LessThanEqual","Property":"Height","Value":String(height),"IsRequired":false]]]]
            var transcodes = profile["TranscodingProfiles"] as? [[String:Any]] ?? []
            for index in transcodes.indices { transcodes[index]["MaxHeight"] = height }
            profile["TranscodingProfiles"] = transcodes
        }
        let resize = height.map { (video["Height"] as? Int ?? 0) > $0 } ?? false
        if resize || (!hdr && isHDR) || (!dolbyVision && isDV) {
            body["EnableDirectPlay"] = false
            body["EnableDirectStream"] = false
            body["AllowVideoStreamCopy"] = false
        }
        body["DeviceProfile"] = profile
    }

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

    static func prepare(metadata: Metadata, detail: WatchDetail, version: FileVersion, start: Double,
                        audioOrdinal: Int?, subtitleIndex: Int?, bitrateKbps: Int?, quality: String?) async throws -> (PreparedPlayback, EmbyPlayback) {
        let connection = metadata.connection
        try await connection.validate()
        let raw = metadata.raw
        let sources = raw["MediaSources"] as? [[String: Any]] ?? []
        guard let source = sources.first(where: { ($0["Id"] as? String).map(EmbyAdapter.numberID) == version.fileId }),
              let sourceID = source["Id"] as? String else { throw EmbyError.playbackUnavailable }
        let audioStreams = (source["MediaStreams"] as? [[String: Any]] ?? []).filter { $0["Type"] as? String == "Audio" }
        let audioIndex = audioOrdinal.flatMap { audioStreams.indices.contains($0) ? audioStreams[$0]["Index"] as? Int : nil }
        var body: [String: Any] = ["UserId":connection.userID!, "MediaSourceId":sourceID, "StartTimeTicks":ticks(start),
            "IsPlayback":true, "AutoOpenLiveStream":false, "EnableDirectPlay":true, "EnableDirectStream":true, "EnableTranscoding":true,
            "SubtitleStreamIndex":subtitleIndex ?? -1,
            "DeviceProfile": ["Name":"Vivid Vivid", "MaxStreamingBitrate": (bitrateKbps ?? 200_000) * 1000,
                "DirectPlayProfiles":[["Type":"Video", "Container":"mkv,mp4,m4v,mov,avi,ts,m2ts,webm", "VideoCodec":"h264,hevc,av1,mpeg2video,vp9", "AudioCodec":"aac,ac3,eac3,flac,alac,mp3,opus,vorbis,truehd,dts,pcm_s16le,pcm_s24le"]],
                "TranscodingProfiles":[["Type":"Video", "Container":"ts", "Protocol":"hls", "VideoCodec":"h264", "AudioCodec":"aac", "Context":"Streaming", "MaxAudioChannels":"2", "MinSegments":2, "SegmentLength":6]],
                "SubtitleProfiles":[["Format":"srt", "Method":"External"], ["Format":"ass", "Method":"External"], ["Format":"ssa", "Method":"External"], ["Format":"vtt", "Method":"External"], ["Format":"pgssub", "Method":"Embed"], ["Format":"dvdsub", "Method":"Embed"]]]]
        if let bitrateKbps, bitrateKbps > 0 { body["MaxStreamingBitrate"] = bitrateKbps * 1000 }
        if let audioIndex { body["AudioStreamIndex"] = audioIndex }
        applyPlaybackLimits(to:&body,source:source,quality:quality,hdr:true,dolbyVision:true)
        let info = try await connection.object("POST", "/Items/\(EmbyConnection.id(detail.contentId))/PlaybackInfo", body: body)
        guard info["ErrorCode"] == nil || info["ErrorCode"] is NSNull,
              let playable = (info["MediaSources"] as? [[String: Any]])?.first(where: { $0["Id"] as? String == sourceID }),
              let playSessionID = info["PlaySessionId"] as? String else { throw EmbyError.playbackUnavailable }
        let direct = playable["SupportsDirectPlay"] as? Bool == true
        let url: URL
        let method: String
        if direct {
            url = try EmbyConnection.url(serverURL: connection.serverURL, path: "/Videos/\(EmbyConnection.id(detail.contentId))/stream", query:["Static":"true", "MediaSourceId":sourceID, "PlaySessionId":playSessionID])
            method = "DirectPlay"
        } else if let rawURL = playable["TranscodingUrl"] as? String,
                  let base = URL(string: connection.serverURL),
                  let candidate = URL(string: rawURL, relativeTo: base)?.absoluteURL,
                  StreamRequest.hasSameOrigin(candidate, base),
                  candidate.user == nil, candidate.password == nil {
            var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false)!
            components.queryItems = components.queryItems?.filter { !["api_key", "x-emby-token", "starttimeticks"].contains($0.name.lowercased()) }
            guard let resolved = components.url else { throw EmbyError.invalidURL }
            url = resolved; method = "Transcode"
        } else { throw EmbyError.playbackUnavailable }
        let stream = StreamRequest(url:url, headers:connection.headers, serverUrl:connection.serverURL)
        var subtitles: [SubtitleUrl] = []
        for track in playable["MediaStreams"] as? [[String: Any]] ?? [] where track["Type"] as? String == "Subtitle" && (track["IsExternal"] as? Bool == true || !direct) {
            guard let index = track["Index"] as? Int, let codec = track["Codec"] as? String,
                  ["srt", "ass", "ssa", "vtt", "subrip"].contains(codec.lowercased()) else { continue }
            let format = codec == "subrip" ? "srt" : codec
            let subURL = try EmbyConnection.url(serverURL: connection.serverURL,
                path:"/Videos/\(EmbyConnection.id(detail.contentId))/\(EmbyConnection.id(sourceID))/Subtitles/\(index)/Stream.\(format)")
            subtitles.append(SubtitleUrl(index:index, language:track["Language"] as? String, codec:format,
                label:track["DisplayTitle"] as? String, source:"external", forced:track["IsForced"] as? Bool,
                default:track["IsDefault"] as? Bool, hearingImpaired:track["IsHearingImpaired"] as? Bool, url:subURL.absoluteString))
        }
        let session = PlaybackSessionResponse(sessionId:playSessionID, userId:nil, profileId:connection.userID,
            mediaFileId:version.fileId, playMethod:method, position:start, isPaused:false, streamUrl:url.absoluteString,
            audioTrackIndex:audioOrdinal, durationSeconds:version.duration, subtitleUrls:subtitles,
            playbackInfo:PlaybackInfo(streamType:direct ? "direct" : "hls", transcodeAudio:!direct, videoCodec:direct ? version.codecVideo : "h264", audioCodec:direct ? version.codecAudio : "aac"))
        let playback = EmbyPlayback(connection:connection,itemID:detail.contentId,sourceID:sourceID,playSessionID:playSessionID,
            stream:stream,method:method,audioIndex:audioIndex,subtitleIndex:subtitleIndex,position:start)
        try await connection.validate()
        return (PreparedPlayback(watchDetail:detail,selectedVersion:version,session:session,activeQualityId:quality ?? ApplePlaybackQuality.autoId, nativeAudioStreamIndex:direct ? audioIndex.flatMap(Int32.init(exactly:)) : nil, nativeHLS:!direct, nativeQualityOptions:playable["SupportsTranscoding"] as? Bool == true ? ApplePlaybackQuality.settingsOptions : [ApplePlaybackQuality.auto,ApplePlaybackQuality.original]),playback)
    }

    func report(position: Double, isPaused: Bool, stopping: Bool = false) async throws {
        guard !stopped else { return }
        lastPosition = position.isFinite ? max(0,position) : lastPosition
        var body: [String:Any] = ["ItemId":itemID, "MediaSourceId":sourceID, "PlaySessionId":playSessionID,
            "PositionTicks":Self.ticks(lastPosition), "IsPaused":isPaused, "CanSeek":true, "PlayMethod":method,
            "QueueableMediaTypes":["Video"], "EventName":"TimeUpdate", "SubtitleStreamIndex":subtitleIndex ?? -1]
        if let audioIndex { body["AudioStreamIndex"] = audioIndex }
        if !started, !stopping {
            _ = try await connection.request("POST", "/Sessions/Playing", body:body)
            started = true
        }
        _ = try await connection.request("POST", stopping ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress",body:body)
        if stopping {
            stopped = true
            if method == "Transcode" {
                _ = try? await connection.request("DELETE", "/Videos/ActiveEncodings", query:["DeviceId":EmbyConnection.deviceID,"PlaySessionId":playSessionID])
            }
        }
    }
}
