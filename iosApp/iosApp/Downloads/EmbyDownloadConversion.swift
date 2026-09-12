import Foundation
import CoreFoundation

/// Native Emby conversion jobs produce a complete file before the existing
/// background downloader starts. Playback streams are not offline artifacts.
enum EmbyDownloadConversion {
    struct Options {
        let profile: String
        let quality: String
    }

    static func isAllowed(policy: [String: Any]) -> Bool {
        policy["EnableContentDownloading"] as? Bool == true
            && policy["EnableSyncTranscoding"] as? Bool == true
    }

    static func options(from response: [String: Any]) throws -> Options {
        let profiles = (response["ProfileOptions"] as? [[String: Any]] ?? [])
            .filter { $0["EnableQualityOptions"] as? Bool == true }
        let qualities = (response["QualityOptions"] as? [[String: Any]] ?? [])
            .filter { $0["IsOriginalQuality"] as? Bool != true }
        guard let profile = (profiles.first { $0["IsDefault"] as? Bool == true } ?? profiles.first)?["Id"] as? String,
              let quality = (qualities.first { $0["IsDefault"] as? Bool == true } ?? qualities.first)?["Id"] as? String,
              !profile.isEmpty, !quality.isEmpty else { throw EmbyError.unsupportedFeature }
        return Options(profile: profile, quality: quality)
    }

    static func availableOptions(connection: EmbyConnection) async throws -> Options {
        guard let user = connection.userID else { throw EmbyError.signInRequired }
        // A sync target must belong to this installation's existing Emby
        // session. Never register another device or change another session.
        guard let sessions = try await connection.request("GET", "/Sessions", query: ["DeviceId": EmbyConnection.deviceID]) as? [[String: Any]],
              let session = sessions.first(where: {
                  $0["DeviceId"] as? String == EmbyConnection.deviceID && $0["UserId"] as? String == user
              }), let sessionID = session["Id"] as? String else { throw EmbyError.unsupportedFeature }
        _ = try await connection.request("POST", "/Sessions/Capabilities/Full", query: ["Id": sessionID], body: [
            "PlayableMediaTypes": ["Video", "Audio"],
            "SupportsSync": true,
            "DeviceProfile": [
                "Name": "Vivid", "SupportedMediaTypes": "Video,Audio",
                "DirectPlayProfiles": [["Type": "Video", "Container": "mp4,m4v,mov,mkv,avi,ts,webm"]],
                "TranscodingProfiles": [["Type": "Video", "Context": "Static", "Protocol": "http",
                    "Container": "mp4", "VideoCodec": "h264", "AudioCodec": "aac", "MaxAudioChannels": "2"]],
                "SubtitleProfiles": [["Format": "srt", "Method": "External"], ["Format": "vtt", "Method": "External"]]
            ]
        ])
        return try options(from: await connection.object("GET", "/Sync/Options", query: [
            "UserId": user, "TargetId": EmbyConnection.deviceID
        ]))
    }

    static func request(itemID: String, userID: String, format: DownloadFormat, options: Options) throws -> [String: Any] {
        guard let bitrate = format.targetBitrateKbps else { throw EmbyError.unsupportedFeature }
        return [
            "TargetId": EmbyConnection.deviceID, "UserId": try EmbyConnection.id(userID),
            "ItemIds": [try EmbyConnection.id(itemID)], "Profile": options.profile, "Quality": options.quality,
            "Bitrate": bitrate * 1000, "Container": "mp4", "VideoCodec": "h264", "AudioCodec": "aac",
            "UnwatchedOnly": false, "SyncNewContent": false, "Downloaded": false
        ]
    }

    static func identifier(_ value: Any?) throws -> String {
        if let value = value as? String { return try EmbyConnection.id(value) }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
           let integer = Int64(value.stringValue), integer > 0 {
            return String(integer)
        }
        throw EmbyError.invalidResponse
    }

    static func creation(_ response: [String: Any]) throws -> (jobID: String, itemID: String) {
        guard let job = response["Job"] as? [String: Any],
              let items = response["JobItems"] as? [[String: Any]], items.count == 1 else { throw EmbyError.invalidResponse }
        let jobID = try identifier(job["Id"])
        guard try identifier(items[0]["JobId"]) == jobID,
              items[0]["TargetId"] as? String == EmbyConnection.deviceID else { throw EmbyError.invalidResponse }
        return (jobID, try identifier(items[0]["Id"]))
    }

    static func status(of item: [String: Any]) throws -> String {
        switch item["Status"] as? String {
        case "Queued", "Converting": return "preparing"
        case "ReadyToTransfer", "Transferring", "Synced": return "ready"
        case "Failed": return "failed"
        default: throw EmbyError.invalidResponse
        }
    }

    static func readySource(from item: [String: Any], sourceID: String) throws -> [String: Any] {
        guard try status(of: item) == "ready", var source = item["MediaSource"] as? [String: Any],
              let container = source["Container"] as? String, !container.isEmpty,
              let size = source["Size"] as? NSNumber, size.int64Value > 0 else { throw EmbyError.invalidResponse }
        source["Id"] = source["Id"] ?? sourceID
        return source
    }
}
