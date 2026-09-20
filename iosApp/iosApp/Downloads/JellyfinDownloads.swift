import Foundation

actor JellyfinDownloads {
    static let shared = JellyfinDownloads()

    private func storageKey(_ connection: JellyfinConnection) throws -> String {
        guard let account = connection.identity?.account, let user = connection.userID else { throw JellyfinError.signInRequired }
        return "vivid.jellyfin.downloads." + account.serverId + "." + user
    }

    private func records(_ connection: JellyfinConnection) throws -> [String:[String:Any]] {
        guard let data = UserDefaults.standard.data(forKey:try storageKey(connection)) else { return [:] }
        return try JSONSerialization.jsonObject(with:data) as? [String:[String:Any]] ?? [:]
    }

    private func save(_ records: [String:[String:Any]], connection: JellyfinConnection) throws {
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject:records),forKey:try storageKey(connection))
    }

    func route(connection: JellyfinConnection, method: String, path: [String], body: [String:Any]) async throws -> Any {
        try await connection.validate()
        guard let user = connection.userID else { throw JellyfinError.signInRequired }
        if path.last == "capability" {
            let raw = try await connection.object("GET", "/Users/\(user)")
            let policy = raw["Policy"] as? [String:Any] ?? [:]
            let formats: [DownloadFormat] = [.original]
            return ["enabled":true,"downloadAllowed":policy["EnableContentDownloading"] as? Bool ?? false,
                    "qualityPresets":formats.map(\.rawValue),"transcodeEnabled":formats.count > 1,
                    "transcodeUserAllowed":false,
                    "seasonDownload":false,"seriesMonitoring":false]
        }
        if path.count == 3, method == "POST" {
            let rawUser = try await connection.object("GET", "/Users/\(user)")
            guard (rawUser["Policy"] as? [String:Any])?["EnableContentDownloading"] as? Bool == true else { throw JellyfinError.unsupportedFeature }
            guard let format = DownloadFormat(rawValue: body["quality"] as? String ?? "original"), body["series"] as? Bool != true,
                  body["season_number"] == nil,
                  let itemID = body["episode_id"] as? String ?? body["content_id"] as? String else { throw JellyfinError.unsupportedFeature }
            guard format == .original else { throw JellyfinError.unsupportedFeature }
            let adapter = JellyfinAdapter(connection:connection)
            let raw = try await adapter.rawItem(itemID)
            let sources = raw["MediaSources"] as? [[String:Any]] ?? []
            let source: [String:Any]?
            if let requested = body["file_id"] as? Int {
                source = sources.first { ($0["Id"] as? String).map(JellyfinAdapter.numberID) == requested }
            } else { source = sources.first }
            guard let source, let sourceID = source["Id"] as? String else { throw JellyfinError.playbackUnavailable }
            _ = try JellyfinConnection.id(sourceID)
            let id = "jellyfin-" + UUID().uuidString
            var manifest = try Self.manifest(id:id,raw:raw,source:source,adapter:adapter)
            let subtitleStreams = source["MediaStreams"] as? [[String:Any]] ?? []
            manifest["subtitles"] = try subtitleStreams.compactMap { stream -> [String:Any]? in
                guard stream["Type"] as? String == "Subtitle", stream["IsExternal"] as? Bool == true,
                      let index = stream["Index"] as? Int, let codec = stream["Codec"] as? String,
                      ["srt","subrip","ass","ssa","vtt"].contains(codec) else { return nil }
                let format = codec == "subrip" ? "srt" : codec
                let url = try JellyfinConnection.url(serverURL:connection.serverURL,
                    path:"/Videos/\(JellyfinConnection.id(itemID))/\(sourceID)/Subtitles/\(index)/Stream.\(format)")
                var subtitle: [String:Any] = ["fetchUrl":url.absoluteString,"format":format,"external":true]
                subtitle["language"] = stream["Language"]; subtitle["forced"] = stream["IsForced"]; subtitle["hearingImpaired"] = stream["IsHearingImpaired"]
                return subtitle
            }
            var row: [String:Any] = ["id":id,"contentId":itemID,"mediaFileId":JellyfinAdapter.numberID(sourceID),"status":"ready","quality":format.rawValue,"revision":1]
            row["fileSize"] = source["Size"]
            if raw["Type"] as? String == "Episode" { row["episodeId"] = itemID }
            var entry: [String: Any] = ["manifest":manifest,"itemID":itemID,"sourceID":sourceID]
            entry["row"] = row
            try await connection.validate()
            var current = try records(connection)
            current[id] = entry
            try save(current,connection:connection)
            return ["downloads":[row]]
        }
        if path.count == 3, method == "GET" {
            return ["downloads":try records(connection).values.filter { $0["deletionPending"] as? Bool != true }.compactMap { $0["row"] }]
        }
        var current = try records(connection)
        guard path.count >= 4, var entry = current[path[3]] else { throw HTTPError.http(statusCode:404,body:nil) }
        if path.count == 5, path[4] == "manifest", method == "GET" { return entry["manifest"] ?? [:] }
        if method == "DELETE", path.count == 4 {
            try await connection.validate()
            current = try records(connection)
            current.removeValue(forKey:path[3]); try save(current,connection:connection); return [:]
        }
        if method == "PATCH", path.count == 4, let status = body["status"] as? String, ["downloading","completed"].contains(status) {
            let row = entry["row"] as? [String:Any] ?? [:]
            guard let updated = try Self.updatedStatus(row: row, body: body) else { return [:] }
            entry["row"] = updated; current[path[3]] = entry
            try save(current,connection:connection)
            return [:]
        }
        throw JellyfinError.unsupportedFeature
    }

    /// Status callbacks share a content revision, so timestamps order writes
    /// within that revision. A completed transfer cannot regress on a replay.
    nonisolated static func updatedStatus(row: [String: Any], body: [String: Any]) throws -> [String: Any]? {
        let currentRevision = row["revision"] as? Int ?? 0
        let revision = body["revision"] as? Int ?? currentRevision
        guard revision >= currentRevision else { return nil }
        func timestamp(_ raw: String) throws -> Date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else { throw JellyfinError.invalidResponse }
            return date
        }
        let updatedAt = body["updated_at"] as? String ?? body["updatedAt"] as? String
        let incomingDate = try updatedAt.map(timestamp)
        if revision == currentRevision {
            if let stored = row["updatedAt"] as? String {
                guard let incomingDate, incomingDate >= (try timestamp(stored)) else { return nil }
            }
            if row["status"] as? String == "completed", body["status"] as? String == "downloading" { return nil }
        }
        var updated = row
        updated["status"] = body["status"]
        updated["revision"] = revision
        if let updatedAt { updated["updatedAt"] = updatedAt }
        return updated
    }

    static func manifest(id: String, raw: [String:Any], source: [String:Any], adapter: JellyfinAdapter) throws -> [String:Any] {
        var result = try adapter.item(raw)
        let version = try adapter.version(source,chapters:raw["Chapters"] as? [[String:Any]] ?? [])
        guard let sourceID = source["Id"] as? String else { throw JellyfinError.invalidResponse }
        result.removeValue(forKey:"versions")
        result["downloadId"] = id; result["quality"] = "original"; result["mediaFileId"] = JellyfinAdapter.numberID(sourceID)
        result["revision"] = 1; result["manifestVersion"] = 1
        for key in ["container","codecVideo","codecAudio","resolution","hdr","fileSize","audioTracks","chapters"] { result[key] = version[key] }
        result["durationSeconds"] = version["duration"]
        result["selectedAudioTrackIndex"] = version["effectiveAudioTrackIndex"]
        var artwork: [String:Any] = [:]
        artwork["poster"] = result["posterUrl"]; artwork["backdrop"] = result["backdropUrl"]; artwork["logo"] = result["logoUrl"]
        result["artworkUrls"] = artwork
        if raw["Type"] as? String == "Episode" { result["episodeId"] = raw["Id"] }
        return result
    }

    func fileURL(id: String, connection: JellyfinConnection) async throws -> URL {
        try await connection.validate()
        guard let record = try records(connection)[id], let itemID = record["itemID"] as? String,
              let sourceID = record["sourceID"] as? String else { throw JellyfinError.invalidResponse }
        return try JellyfinConnection.url(serverURL:connection.serverURL,path:"/Videos/\(JellyfinConnection.id(itemID))/stream",query:["Static":"true","MediaSourceId":sourceID])
    }

}
