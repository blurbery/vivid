import Foundation

actor EmbyDownloads {
    static let shared = EmbyDownloads()

    private func storageKey(_ connection: EmbyConnection) throws -> String {
        guard let account = connection.identity?.account, let user = connection.userID else { throw EmbyError.signInRequired }
        return "vivid.emby.downloads." + account.serverId + "." + user
    }

    private func records(_ connection: EmbyConnection) throws -> [String:[String:Any]] {
        guard let data = UserDefaults.standard.data(forKey:try storageKey(connection)) else { return [:] }
        return try JSONSerialization.jsonObject(with:data) as? [String:[String:Any]] ?? [:]
    }

    private func save(_ records: [String:[String:Any]], connection: EmbyConnection) throws {
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject:records),forKey:try storageKey(connection))
    }

    func route(connection: EmbyConnection, method: String, path: [String], body: [String:Any]) async throws -> Any {
        try await connection.validate()
        guard let user = connection.userID else { throw EmbyError.signInRequired }
        if path.last == "capability" {
            let raw = try await connection.object("GET", "/Users/\(user)")
            let policy = raw["Policy"] as? [String:Any] ?? [:]
            return ["enabled":true,"downloadAllowed":policy["EnableContentDownloading"] as? Bool ?? false,
                    "qualityPresets":["original"],"transcodeEnabled":false,"seasonDownload":false,"seriesMonitoring":false]
        }
        if path.count == 3, method == "POST" {
            let rawUser = try await connection.object("GET", "/Users/\(user)")
            guard (rawUser["Policy"] as? [String:Any])?["EnableContentDownloading"] as? Bool == true else { throw EmbyError.unsupportedFeature }
            guard body["quality"] as? String == "original", body["series"] as? Bool != true,
                  body["season_number"] == nil,
                  let itemID = body["episode_id"] as? String ?? body["content_id"] as? String else { throw EmbyError.unsupportedFeature }
            let adapter = EmbyAdapter(connection:connection)
            let raw = try await adapter.rawItem(itemID)
            let sources = raw["MediaSources"] as? [[String:Any]] ?? []
            let source: [String:Any]?
            if let requested = body["file_id"] as? Int {
                source = sources.first { ($0["Id"] as? String).map(EmbyAdapter.numberID) == requested }
            } else { source = sources.first }
            guard let source, let sourceID = source["Id"] as? String else { throw EmbyError.playbackUnavailable }
            _ = try EmbyConnection.id(sourceID)
            let id = "emby-" + UUID().uuidString
            var manifest = try Self.manifest(id:id,raw:raw,source:source,adapter:adapter)
            let subtitleStreams = source["MediaStreams"] as? [[String:Any]] ?? []
            manifest["subtitles"] = try subtitleStreams.compactMap { stream -> [String:Any]? in
                guard stream["Type"] as? String == "Subtitle", stream["IsExternal"] as? Bool == true,
                      let index = stream["Index"] as? Int, let codec = stream["Codec"] as? String,
                      ["srt","subrip","ass","ssa","vtt"].contains(codec) else { return nil }
                let format = codec == "subrip" ? "srt" : codec
                let url = try EmbyConnection.url(serverURL:connection.serverURL,
                    path:"/Videos/\(EmbyConnection.id(itemID))/\(sourceID)/Subtitles/\(index)/Stream.\(format)")
                var subtitle: [String:Any] = ["fetchUrl":url.absoluteString,"format":format,"external":true]
                subtitle["language"] = stream["Language"]; subtitle["forced"] = stream["IsForced"]; subtitle["hearingImpaired"] = stream["IsHearingImpaired"]
                return subtitle
            }
            var row: [String:Any] = ["id":id,"contentId":itemID,"mediaFileId":EmbyAdapter.numberID(sourceID),"status":"ready","quality":"original","revision":1]
            row["fileSize"] = source["Size"]
            if raw["Type"] as? String == "Episode" { row["episodeId"] = itemID }
            try await connection.validate()
            var current = try records(connection)
            current[id] = ["row":row,"manifest":manifest,"itemID":itemID,"sourceID":sourceID]
            try save(current,connection:connection)
            return ["downloads":[row]]
        }
        var current = try records(connection)
        if path.count == 3, method == "GET" { return ["downloads":current.values.compactMap { $0["row"] }] }
        guard path.count >= 4, var entry = current[path[3]] else { throw HTTPError.http(statusCode:404,body:nil) }
        if path.count == 5, path[4] == "manifest", method == "GET" { return entry["manifest"] ?? [:] }
        if method == "DELETE", path.count == 4 { current.removeValue(forKey:path[3]); try save(current,connection:connection); return [:] }
        if method == "PATCH", path.count == 4, let status = body["status"] as? String, ["downloading","completed"].contains(status) {
            var row = entry["row"] as? [String:Any] ?? [:]
            row["status"] = status; entry["row"] = row; current[path[3]] = entry
            try save(current,connection:connection)
            return [:]
        }
        throw EmbyError.unsupportedFeature
    }

    static func manifest(id: String, raw: [String:Any], source: [String:Any], adapter: EmbyAdapter) throws -> [String:Any] {
        var result = try adapter.item(raw)
        let version = try adapter.version(source,chapters:raw["Chapters"] as? [[String:Any]] ?? [])
        guard let sourceID = source["Id"] as? String else { throw EmbyError.invalidResponse }
        result.removeValue(forKey:"versions")
        result["downloadId"] = id; result["quality"] = "original"; result["mediaFileId"] = EmbyAdapter.numberID(sourceID)
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

    func fileURL(id: String, connection: EmbyConnection) async throws -> URL {
        try await connection.validate()
        guard let record = try records(connection)[id], let itemID = record["itemID"] as? String,
              let sourceID = record["sourceID"] as? String else { throw EmbyError.invalidResponse }
        return try EmbyConnection.url(serverURL:connection.serverURL,path:"/Videos/\(EmbyConnection.id(itemID))/stream",query:["Static":"true","MediaSourceId":sourceID])
    }
}
