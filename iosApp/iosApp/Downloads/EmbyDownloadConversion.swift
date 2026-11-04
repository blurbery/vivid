import Foundation
import CoreFoundation

/// Emby's conversion service, the fallback for accounts that may download
/// but not transcode playback. A conversion job makes a complete file on the
/// server, and the usual background transfer fetches it once it's ready.
/// Playback streams are never saved as offline files this way.
enum EmbyDownloadConversion {
    /// The conversion profile and quality Emby offers this device.
    struct Options {
        let profile: String
        let quality: String
    }

    static func isAllowed(policy: [String: Any]) -> Bool {
        policy["EnableContentDownloading"] as? Bool == true
            && policy["EnableSyncTranscoding"] as? Bool == true
    }

    /// The default profile that takes a quality, and the default quality
    /// that isn't the original (the first of each when none is default).
    static func options(from response: [String: Any]) throws -> Options {
        let profiles = (response["ProfileOptions"] as? [[String: Any]] ?? [])
            .filter { $0["EnableQualityOptions"] as? Bool == true }
        let qualities = (response["QualityOptions"] as? [[String: Any]] ?? [])
            .filter { $0["IsOriginalQuality"] as? Bool != true }
        guard let profile = preferred(in: profiles)?["Id"] as? String, !profile.isEmpty,
              let quality = preferred(in: qualities)?["Id"] as? String, !quality.isEmpty else {
            throw EmbyError.unsupportedFeature
        }
        return Options(profile: profile, quality: quality)
    }

    private static func preferred(in options: [[String: Any]]) -> [String: Any]? {
        options.first { $0["IsDefault"] as? Bool == true } ?? options.first
    }

    // MARK: Requests

    /// Conversion options for this device. Emby builds them from the items
    /// being synced and answers 500 when `ItemIds` is missing, so
    /// registration names the item it will convert and the capability check
    /// samples one video from the library.
    static func availableOptions(connection: EmbyConnection, itemID: String? = nil) async throws -> Options {
        guard let user = connection.userID else { throw EmbyError.signInRequired }
        let sampleID: String
        if let itemID {
            sampleID = itemID
        } else {
            sampleID = try await sampleItemID(connection: connection, user: user)
        }
        let sessionID = try await currentSessionID(connection: connection, user: user)
        _ = try await connection.request("POST", "/Sessions/Capabilities/Full", query: ["Id": sessionID],
                                         body: capabilities)
        let response = try await connection.object("GET", "/Sync/Options", query: [
            "UserId": user,
            "TargetId": EmbyConnection.deviceID,
            "ItemIds": try EmbyConnection.id(sampleID),
        ])
        return try options(from: response)
    }

    /// This installation's own session for this user. A sync target must
    /// belong to it: never register another device or change another
    /// account's session.
    private static func currentSessionID(connection: EmbyConnection, user: String) async throws -> String {
        let response = try await connection.request("GET", "/Sessions", query: ["DeviceId": EmbyConnection.deviceID])
        guard let sessions = response as? [[String: Any]],
              let session = sessions.first(where: {
                  $0["DeviceId"] as? String == EmbyConnection.deviceID && $0["UserId"] as? String == user
              }),
              let id = session["Id"] as? String else { throw EmbyError.unsupportedFeature }
        return id
    }

    /// The session capabilities that make this device a sync target.
    private static var capabilities: [String: Any] {
        [
            "PlayableMediaTypes": ["Video", "Audio"],
            "SupportsSync": true,
            "DeviceProfile": [
                "Name": "Vivid",
                "SupportedMediaTypes": "Video,Audio",
                "DirectPlayProfiles": [["Type": "Video", "Container": "mp4,m4v,mov,mkv,avi,ts,webm"]],
                "TranscodingProfiles": [[
                    "Type": "Video", "Context": "Static", "Protocol": "http", "Container": "mp4",
                    "VideoCodec": "h264", "AudioCodec": "aac", "MaxAudioChannels": "2",
                ]],
                "SubtitleProfiles": [["Format": "srt", "Method": "External"], ["Format": "vtt", "Method": "External"]],
            ] as [String: Any],
        ]
    }

    /// Any movie or episode this account can see, for the capability check.
    private static func sampleItemID(connection: EmbyConnection, user: String) async throws -> String {
        let result = try await connection.object("GET", "/Users/\(user)/Items", query: [
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Episode",
            "Limit": "1",
            "EnableImages": "false",
            "EnableUserData": "false",
        ])
        guard let id = (result["Items"] as? [[String: Any]])?.first?["Id"] as? String else {
            throw EmbyError.unsupportedFeature
        }
        return id
    }

    /// The body of a `POST /Sync/Jobs` that converts one item to this
    /// quality for this device.
    static func request(itemID: String, userID: String, format: DownloadFormat, options: Options) throws -> [String: Any] {
        guard let bitrateKbps = format.targetBitrateKbps else { throw EmbyError.unsupportedFeature }
        return [
            "TargetId": EmbyConnection.deviceID,
            "UserId": try EmbyConnection.id(userID),
            "ItemIds": [try EmbyConnection.id(itemID)],
            "Profile": options.profile,
            "Quality": options.quality,
            "Bitrate": bitrateKbps * 1000,
            "Container": "mp4",
            "VideoCodec": "h264",
            "AudioCodec": "aac",
            "UnwatchedOnly": false,
            "SyncNewContent": false,
            "Downloaded": false,
        ]
    }

    // MARK: Responses

    /// A job or job item ID, which Emby sends as a string or a positive
    /// whole number.
    static func identifier(_ value: Any?) throws -> String {
        if let text = value as? String { return try EmbyConnection.id(text) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let integer = Int64(number.stringValue), integer > 0 {
            return String(integer)
        }
        throw EmbyError.invalidResponse
    }

    /// The job and its one item, which must belong to this job and device.
    static func creation(_ response: [String: Any]) throws -> (jobID: String, itemID: String) {
        guard let job = response["Job"] as? [String: Any],
              let items = response["JobItems"] as? [[String: Any]], items.count == 1 else {
            throw EmbyError.invalidResponse
        }
        let jobID = try identifier(job["Id"])
        let item = items[0]
        guard try identifier(item["JobId"]) == jobID,
              item["TargetId"] as? String == EmbyConnection.deviceID else { throw EmbyError.invalidResponse }
        return (jobID, try identifier(item["Id"]))
    }

    /// A job item's status as a download row status: "preparing", "ready"
    /// or "failed". A job cancelled on the server won't make a file, so it
    /// counts as failed.
    static func status(of item: [String: Any]) throws -> String {
        switch item["Status"] as? String {
        case "Queued", "Converting": return "preparing"
        case "ReadyToTransfer", "Transferring", "Synced": return "ready"
        case "Failed", "Cancelled": return "failed"
        default: throw EmbyError.invalidResponse
        }
    }

    /// The converted file's media source, once it's ready and says its
    /// container and size. It keeps the original source ID when it has none.
    static func readySource(from item: [String: Any], sourceID: String) throws -> [String: Any] {
        guard try status(of: item) == "ready",
              var source = item["MediaSource"] as? [String: Any],
              let container = source["Container"] as? String, !container.isEmpty,
              let size = source["Size"] as? NSNumber, size.int64Value > 0 else { throw EmbyError.invalidResponse }
        source["Id"] = source["Id"] ?? sourceID
        return source
    }
}
