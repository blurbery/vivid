import Foundation

/// Smaller-quality downloads from Emby and Jellyfin made by the server's
/// playback transcoder: the file is converted as it's sent and the background
/// session saves the stream. It needs only the account's download and
/// playback-transcoding permissions, so it works on any Emby or Jellyfin
/// server, with or without a conversion service, and keeps going while the
/// app is closed.
///
/// The server can't know the final length, so progress uses an estimate from
/// the bitrate and runtime, and an interrupted transfer starts again instead
/// of resuming.
enum StreamedTranscodeDownload {
    /// The account may transcode playback, which is all this needs on top of
    /// the download permission.
    static func isAllowed(policy: [String: Any]) -> Bool {
        policy["EnableContentDownloading"] as? Bool == true
            && policy["EnableVideoPlaybackTranscoding"] as? Bool != false
    }

    /// Largest output height for each preset, matching Silo's download ladder
    /// for H.264 without 4K transcoding.
    static func maxHeight(_ format: DownloadFormat) -> Int? {
        switch format {
        case .original: return nil
        case .twentyMbps, .tenMbps, .fiveMbps: return 1080
        case .twoMbps: return 720
        case .oneMbps: return 480
        }
    }

    static func audioBitrateKbps(_ format: DownloadFormat) -> Int {
        (format.targetBitrateKbps ?? 0) >= 5_000 ? 192 : 128
    }

    /// Query for `/Videos/{id}/stream.mp4`: H.264 with stereo AAC in MP4,
    /// which every Apple device plays, capped to the preset's bitrate and
    /// height. A fresh play session per request keeps a retry from joining
    /// an earlier, abandoned transcode.
    static func query(format: DownloadFormat, sourceID: String, audioStreamIndex: Int?, deviceID: String) -> [String: String]? {
        guard let videoKbps = format.targetBitrateKbps, let height = maxHeight(format) else { return nil }
        var query = [
            "Static": "false",
            "Container": "mp4",
            "MediaSourceId": sourceID,
            "VideoCodec": "h264",
            "AudioCodec": "aac",
            "MaxAudioChannels": "2",
            "VideoBitrate": String(videoKbps * 1000),
            "AudioBitrate": String(audioBitrateKbps(format) * 1000),
            "MaxHeight": String(height),
            "DeviceId": deviceID,
            "PlaySessionId": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        ]
        if let audioStreamIndex { query["AudioStreamIndex"] = String(audioStreamIndex) }
        return query
    }

    /// Expected size of a transcoded file, from its bitrates and runtime.
    static func estimatedBytes(format: DownloadFormat, durationSeconds: Double?) -> Int64? {
        guard let videoKbps = format.targetBitrateKbps, let seconds = durationSeconds, seconds > 0 else { return nil }
        let bytesPerSecond = Double(videoKbps + audioBitrateKbps(format)) * 1000 / 8
        return Int64(bytesPerSecond * seconds)
    }

    /// Rewrites an original-file registration (`manifest` and `row`) to
    /// describe the transcoded file the stream will produce, and records the
    /// preset and audio track the file request needs.
    static func apply(_ format: DownloadFormat, to entry: inout [String: Any], source: [String: Any]) {
        guard format != .original, var manifest = entry["manifest"] as? [String: Any],
              var row = entry["row"] as? [String: Any] else { return }
        let estimate = estimatedBytes(format: format, durationSeconds: manifest["durationSeconds"] as? Double)
        manifest["quality"] = format.rawValue
        manifest["effectiveQuality"] = format.rawValue
        manifest["targetBitrateKbps"] = format.targetBitrateKbps
        manifest["deliveryFormat"] = "mp4"
        manifest["container"] = "mp4"
        manifest["codecVideo"] = "h264"
        manifest["codecAudio"] = "aac"
        manifest["hdr"] = false
        manifest["fileSize"] = estimate
        if let height = maxHeight(format), let resolution = manifest["resolution"] as? String,
           let sourceHeight = Int(resolution.dropLast()), sourceHeight > height {
            manifest["resolution"] = "\(height)p"
        }
        // The transcode carries one audio track: the one asked for below.
        if let tracks = manifest["audioTracks"] as? [[String: Any]], !tracks.isEmpty {
            let selected = (manifest["selectedAudioTrackIndex"] as? Int).flatMap { tracks.indices.contains($0) ? $0 : nil } ?? 0
            var track = tracks[selected]
            track["index"] = 0
            track["codec"] = "aac"
            if let channels = track["channels"] as? Int { track["channels"] = min(channels, 2) }
            manifest["audioTracks"] = [track]
            manifest["selectedAudioTrackIndex"] = 0
        }
        row["quality"] = format.rawValue
        row["effectiveQuality"] = format.rawValue
        row["targetBitrateKbps"] = format.targetBitrateKbps
        row["deliveryFormat"] = "mp4"
        row["fileSize"] = estimate
        entry["manifest"] = manifest
        entry["row"] = row
        entry["transcode"] = format.rawValue
        entry["audioStreamIndex"] = source["DefaultAudioStreamIndex"] as? Int
    }

    /// The preset a stored registration streams in, or nil for an original file.
    static func format(of entry: [String: Any]) -> DownloadFormat? {
        guard let raw = entry["transcode"] as? String, let format = DownloadFormat(rawValue: raw),
              format != .original else { return nil }
        return format
    }
}
