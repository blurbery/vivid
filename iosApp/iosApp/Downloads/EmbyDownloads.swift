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
            let formats = try await offeredFormats(connection: connection, policy: policy)
            return ["enabled":true,"downloadAllowed":policy["EnableContentDownloading"] as? Bool ?? false,
                    "qualityPresets":formats.map(\.rawValue),"transcodeEnabled":formats.count > 1,
                    "transcodeUserAllowed":EmbyDownloadConversion.isAllowed(policy: policy),
                    "seasonDownload":false,"seriesMonitoring":false]
        }
        if path.count == 3, method == "POST" {
            let rawUser = try await connection.object("GET", "/Users/\(user)")
            guard (rawUser["Policy"] as? [String:Any])?["EnableContentDownloading"] as? Bool == true else { throw EmbyError.unsupportedFeature }
            guard let format = DownloadFormat(rawValue: body["quality"] as? String ?? "original"), body["series"] as? Bool != true,
                  body["season_number"] == nil,
                  let itemID = body["episode_id"] as? String ?? body["content_id"] as? String else { throw EmbyError.unsupportedFeature }
            let conversionOptions: EmbyDownloadConversion.Options?
            if format != .original {
                #if os(iOS)
                guard EmbyDownloadConversion.isAllowed(policy: rawUser["Policy"] as? [String: Any] ?? [:]),
                      body["file_id"] == nil || body["file_id"] is NSNull else { throw EmbyError.unsupportedFeature }
                conversionOptions = try await EmbyDownloadConversion.availableOptions(connection: connection)
                #else
                throw EmbyError.unsupportedFeature
                #endif
            } else { conversionOptions = nil }
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
            var row: [String:Any] = ["id":id,"contentId":itemID,"mediaFileId":EmbyAdapter.numberID(sourceID),"status":"ready","quality":format.rawValue,"revision":1]
            row["fileSize"] = source["Size"]
            if raw["Type"] as? String == "Episode" { row["episodeId"] = itemID }
            var entry: [String: Any] = ["manifest":manifest,"itemID":itemID,"sourceID":sourceID]
            if let conversionOptions {
                let request = try EmbyDownloadConversion.request(itemID: itemID, userID: user, format: format, options: conversionOptions)
                let result = try await connection.object("POST", "/Sync/Jobs", body: request)
                let conversion = try EmbyDownloadConversion.creation(result)
                entry["syncJobID"] = conversion.jobID
                entry["syncItemID"] = conversion.itemID
                entry["sourceItem"] = raw
                row["status"] = "preparing"
                row["fileSize"] = 0
                row["targetBitrateKbps"] = format.targetBitrateKbps
            }
            entry["row"] = row
            try await connection.validate()
            var current = try records(connection)
            current[id] = entry
            try save(current,connection:connection)
            return ["downloads":[row]]
        }
        if path.count == 3, method == "GET" {
            try await refreshConversions(connection: connection)
            return ["downloads":try records(connection).values.filter { $0["deletionPending"] as? Bool != true }.compactMap { $0["row"] }]
        }
        var current = try records(connection)
        guard path.count >= 4, var entry = current[path[3]] else { throw HTTPError.http(statusCode:404,body:nil) }
        if path.count == 5, path[4] == "manifest", method == "GET" { return entry["manifest"] ?? [:] }
        if method == "DELETE", path.count == 4 {
            if entry["syncJobID"] != nil {
                entry["deletionPending"] = true
                current[path[3]] = entry
                try save(current, connection: connection)
                await removeConversion(id: path[3], connection: connection)
                return [:]
            }
            try await connection.validate()
            current = try records(connection)
            current.removeValue(forKey:path[3]); try save(current,connection:connection); return [:]
        }
        if method == "PATCH", path.count == 4, let status = body["status"] as? String, ["downloading","completed"].contains(status) {
            var row = entry["row"] as? [String:Any] ?? [:]
            row["status"] = status; entry["row"] = row; current[path[3]] = entry
            if status == "completed", entry["syncItemID"] != nil {
                entry["transferAcknowledgementPending"] = true
                current[path[3]] = entry
            }
            try save(current,connection:connection)
            if status == "completed" { await acknowledgeTransfer(id: path[3], connection: connection) }
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
        if let syncItemID = record["syncItemID"] as? String {
            guard let status = (record["row"] as? [String: Any])?["status"] as? String,
                  ["ready", "downloading", "completed"].contains(status) else { throw EmbyError.playbackUnavailable }
            return try EmbyConnection.url(serverURL: connection.serverURL, path: "/Sync/JobItems/\(EmbyConnection.id(syncItemID))/File")
        }
        return try EmbyConnection.url(serverURL:connection.serverURL,path:"/Videos/\(EmbyConnection.id(itemID))/stream",query:["Static":"true","MediaSourceId":sourceID])
    }

    private func offeredFormats(connection: EmbyConnection, policy: [String: Any]) async throws -> [DownloadFormat] {
        #if os(iOS)
        if EmbyDownloadConversion.isAllowed(policy: policy) {
            do {
                _ = try await EmbyDownloadConversion.availableOptions(connection: connection)
                return DownloadFormat.allCases
            } catch {
                // A disabled/unavailable conversion service must not break
                // existing original-file downloads. Identity and cancellation
                // still propagate before returning the fallback capability.
                try await connection.validate()
            }
        }
        #endif
        return [.original]
    }

    private func refreshConversions(connection: EmbyConnection) async throws {
        let snapshot = try records(connection)
        for (id, entry) in snapshot where entry["deletionPending"] as? Bool == true {
            await removeConversion(id: id, connection: connection)
        }
        for (id, entry) in snapshot where entry["transferAcknowledgementPending"] as? Bool == true {
            await acknowledgeTransfer(id: id, connection: connection)
        }
        guard snapshot.values.contains(where: {
            $0["deletionPending"] as? Bool != true && $0["syncItemID"] != nil && ($0["row"] as? [String: Any])?["status"] as? String == "preparing"
        }) else { return }
        let response = try await connection.object("GET", "/Sync/JobItems", query: ["TargetId": EmbyConnection.deviceID])
        guard let items = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        try await connection.validate()
        var current = try records(connection)
        for (id, var entry) in current {
            guard let syncID = entry["syncItemID"] as? String,
                  entry["deletionPending"] as? Bool != true,
                  let jobID = entry["syncJobID"] as? String,
                  var row = entry["row"] as? [String: Any], row["status"] as? String == "preparing",
                  let item = items.first(where: {
                      (try? EmbyDownloadConversion.identifier($0["Id"])) == syncID
                          && (try? EmbyDownloadConversion.identifier($0["JobId"])) == jobID
                          && $0["TargetId"] as? String == EmbyConnection.deviceID
                  }) else { continue }
            let status = try EmbyDownloadConversion.status(of: item)
            if status == "ready" {
                guard let raw = entry["sourceItem"] as? [String: Any],
                      let sourceID = entry["sourceID"] as? String,
                      let quality = row["quality"] as? String else { throw EmbyError.invalidResponse }
                let source = try EmbyDownloadConversion.readySource(from: item, sourceID: sourceID)
                var manifest = try Self.manifest(id: id, raw: raw, source: source, adapter: EmbyAdapter(connection: connection))
                manifest["quality"] = quality
                manifest["effectiveQuality"] = quality
                manifest["targetBitrateKbps"] = row["targetBitrateKbps"]
                manifest["deliveryFormat"] = source["Container"]
                manifest["subtitles"] = (entry["manifest"] as? [String: Any])?["subtitles"]
                entry["manifest"] = manifest
                entry.removeValue(forKey: "sourceItem")
                row["fileSize"] = source["Size"]
                row["mediaFileId"] = manifest["mediaFileId"]
                row["effectiveQuality"] = quality
                row["deliveryFormat"] = source["Container"]
            }
            row["status"] = status; entry["row"] = row; current[id] = entry
        }
        try save(current, connection: connection)
    }

    private func acknowledgeTransfer(id: String, connection: EmbyConnection) async {
        do {
            guard let entry = try records(connection)[id],
                  entry["deletionPending"] as? Bool != true,
                  entry["transferAcknowledgementPending"] as? Bool == true,
                  let syncID = entry["syncItemID"] as? String else { return }
            _ = try await connection.request("POST", "/Sync/JobItems/\(EmbyConnection.id(syncID))/Transferred")
            var current = try records(connection)
            current[id]?.removeValue(forKey: "transferAcknowledgementPending")
            try save(current, connection: connection)
        } catch {
            // The local file is already complete. Retain the acknowledgement
            // for the next reconciliation instead of downloading it again.
        }
    }

    private func removeConversion(id: String, connection: EmbyConnection) async {
        do {
            guard let entry = try records(connection)[id], entry["deletionPending"] as? Bool == true,
                  let jobID = entry["syncJobID"] as? String else { return }
            do { _ = try await connection.request("DELETE", "/Sync/Jobs/\(EmbyConnection.id(jobID))") }
            catch HTTPError.http(let status, _) where status == 404 { }
            try await connection.validate()
            var current = try records(connection)
            current.removeValue(forKey: id)
            try save(current, connection: connection)
        } catch {
            // Keep only the cleanup record while offline. It stays out of
            // the download list and is retried without restoring deleted media.
        }
    }
}
