import Foundation

/// Downloads on a Jellyfin server, answering the app's `/api/v1/downloads`
/// routes. Jellyfin keeps no download records, so each account's
/// registrations are stored on the device: the offline manifest, the item
/// and source the file comes from, and the row the download list shows.
///
/// The original file comes straight from the server. A smaller quality is
/// streamed through the playback transcoder ([StreamedTranscodeDownload]).
actor JellyfinDownloads {
    static let shared = JellyfinDownloads()

    enum BatchError: LocalizedError {
        case alreadyDownloaded, noEpisodes

        var errorDescription: String? {
            switch self {
            case .alreadyDownloaded: String(localized: "All available episodes are already downloaded.")
            case .noEpisodes: String(localized: "No downloadable episodes were found.")
            }
        }
    }

    /// One episode's registration in a season or series batch.
    typealias BatchEpisode = (itemID: String, id: String, entry: [String: Any], row: [String: Any])

    /// A stored registration: `manifest`, `itemID`, `sourceID` and `row`,
    /// plus `transcode` and `audioStreamIndex` for a streamed quality.
    private typealias Entry = [String: Any]
    /// Every stored registration of one account, by download ID.
    private typealias Store = [String: Entry]

    /// Text subtitle codecs the server can hand over as a file.
    private static let textSubtitleCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]

    // MARK: Routes

    func route(connection: JellyfinConnection, method: String, path: [String], body: [String: Any]) async throws -> Any {
        try await connection.validate()
        guard let user = connection.userID else { throw JellyfinError.signInRequired }
        if path.last == "capability" {
            return try await capability(connection: connection, user: user)
        }
        if path.count == 3, method == "POST" {
            return try await register(connection: connection, user: user, body: body)
        }
        if path.count == 3, method == "GET" {
            return ["downloads": try load(connection).values.filter { !Self.isDeletionPending($0) }.compactMap { $0["row"] }]
        }
        return try await routeDownload(connection: connection, method: method, path: path, body: body)
    }

    /// The routes for one stored download: its manifest, removing it, and
    /// status updates from the transfer.
    private func routeDownload(connection: JellyfinConnection, method: String, path: [String],
                               body: [String: Any]) async throws -> Any {
        var store = try load(connection)
        guard path.count >= 4, var entry = store[path[3]] else { throw HTTPError.http(statusCode: 404, body: nil) }
        let id = path[3]
        if path.count == 5, path[4] == "manifest", method == "GET" {
            return entry["manifest"] ?? [:]
        }
        if method == "DELETE", path.count == 4 {
            try await connection.validate()
            store = try load(connection)
            store.removeValue(forKey: id)
            try save(store, connection: connection)
            return [:]
        }
        if method == "PATCH", path.count == 4, let status = body["status"] as? String, ["downloading", "completed"].contains(status) {
            guard let updated = try Self.updatedStatus(row: entry["row"] as? [String: Any] ?? [:], body: body) else { return [:] }
            entry["row"] = updated
            store[id] = entry
            try save(store, connection: connection)
            return [:]
        }
        throw JellyfinError.unsupportedFeature
    }

    // MARK: Capability

    /// Smaller qualities come from the server's playback transcoder, so any
    /// account allowed to transcode can pick them.
    private func capability(connection: JellyfinConnection, user: String) async throws -> [String: Any] {
        let policy = try await policy(connection: connection, user: user)
        let streams = StreamedTranscodeDownload.isAllowed(policy: policy)
        let formats: [DownloadFormat] = streams ? DownloadFormat.allCases : [.original]
        let smaller = formats.count > 1
        return [
            "enabled": true,
            "downloadAllowed": policy["EnableContentDownloading"] as? Bool ?? false,
            "qualityPresets": formats.map(\.rawValue),
            "transcodeEnabled": smaller,
            "transcodeUserAllowed": streams,
            "seasonDownload": true,
            "seriesMonitoring": false,
            "bulkQuality": smaller,
        ]
    }

    private func policy(connection: JellyfinConnection, user: String) async throws -> [String: Any] {
        let account = try await connection.object("GET", "/Users/\(user)")
        return account["Policy"] as? [String: Any] ?? [:]
    }

    // MARK: Registering

    private func register(connection: JellyfinConnection, user: String, body: [String: Any]) async throws -> Any {
        let policy = try await policy(connection: connection, user: user)
        guard policy["EnableContentDownloading"] as? Bool == true else { throw JellyfinError.unsupportedFeature }
        if body["series"] as? Bool == true || body["season_number"] != nil {
            return try await registerEpisodes(connection: connection, user: user, body: body, policy: policy)
        }
        return try await registerItem(connection: connection, body: body, policy: policy)
    }

    /// One movie or episode, in the file asked for or the first one.
    private func registerItem(connection: JellyfinConnection, body: [String: Any], policy: [String: Any]) async throws -> Any {
        guard let format = Self.format(in: body),
              let itemID = body["episode_id"] as? String ?? body["content_id"] as? String,
              format == .original || StreamedTranscodeDownload.isAllowed(policy: policy) else {
            throw JellyfinError.unsupportedFeature
        }
        let adapter = JellyfinAdapter(connection: connection)
        let raw = try await adapter.rawItem(itemID)
        let sources = raw["MediaSources"] as? [[String: Any]] ?? []
        let source = if let requested = body["file_id"] as? Int {
            sources.first { ($0["Id"] as? String).map(JellyfinAdapter.numberID) == requested }
        } else {
            sources.first
        }
        guard let source, let sourceID = source["Id"] as? String else { throw JellyfinError.playbackUnavailable }

        let id = "jellyfin-" + UUID().uuidString
        var (entry, _) = try Self.record(id: id, raw: raw, itemID: itemID, source: source, sourceID: sourceID,
                                         format: format, adapter: adapter)
        StreamedTranscodeDownload.apply(format, to: &entry, source: source)
        try await connection.validate()
        var store = try load(connection)
        store[id] = entry
        try save(store, connection: connection)
        return ["downloads": [entry["row"] ?? [:]]]
    }

    /// Series and season batches register each present episode in one
    /// write, as the original file or streamed through the transcoder at the
    /// chosen quality.
    private func registerEpisodes(connection: JellyfinConnection, user: String, body: [String: Any],
                                  policy: [String: Any]) async throws -> Any {
        let season = body["season_number"] as? Int
        guard let format = Self.format(in: body),
              format == .original || StreamedTranscodeDownload.isAllowed(policy: policy),
              Self.isAbsent(body["file_id"]), Self.isAbsent(body["episode_id"]),
              body["season_number"] == nil || season != nil,
              let seriesID = body["content_id"] as? String else { throw JellyfinError.unsupportedFeature }
        var query = [
            "UserId": user,
            "Fields": JellyfinAdapter.fields,
            "EnableUserData": "true",
            "IsMissing": "false",
            "Recursive": "false",
            "IncludeItemTypes": "Episode",
            "SortBy": "ParentIndexNumber,IndexNumber",
            "SortOrder": "Ascending",
        ]
        if let season { query["Season"] = String(season) }
        let result = try await connection.object("GET", "/Shows/\(JellyfinConnection.id(seriesID))/Episodes", query: query)
        guard let items = result["Items"] as? [[String: Any]] else { throw JellyfinError.invalidResponse }

        let built = try Self.batchEpisodes(items, body: body, format: format, adapter: JellyfinAdapter(connection: connection))
        guard !built.isEmpty else { throw BatchError.noEpisodes }
        try await connection.validate()
        // No await from here to the save, so overlapping requests can't
        // register an episode twice.
        var store = try load(connection)
        let batch = Self.batchResult(built: built, stored: store)
        guard !batch.rows.isEmpty else { throw BatchError.alreadyDownloaded }
        for episode in batch.fresh { store[episode.id] = episode.entry }
        if !batch.fresh.isEmpty { try save(store, connection: connection) }
        return ["downloads": batch.rows]
    }

    // MARK: Building registrations

    /// Registrations for each downloadable episode, in server order: the
    /// original file, or a stream transcoded to `format`.
    nonisolated static func batchEpisodes(_ items: [[String: Any]], body: [String: Any], format: DownloadFormat = .original,
                                          adapter: JellyfinAdapter) throws -> [BatchEpisode] {
        var built: [BatchEpisode] = []
        for raw in downloadableEpisodes(items) {
            try Task.checkCancellation()
            guard let itemID = raw["Id"] as? String,
                  let source = (raw["MediaSources"] as? [[String: Any]])?.first,
                  let sourceID = source["Id"] as? String else { continue }
            let id = "jellyfin-" + UUID().uuidString
            do {
                var (entry, row) = try record(id: id, raw: raw, itemID: itemID, source: source, sourceID: sourceID,
                                              format: format, batchID: body["batch_id"] as? String, adapter: adapter)
                // Episode rows name their series, as Silo's do; the episode
                // stays in episodeId.
                row["contentId"] = body["content_id"] as? String ?? itemID
                entry["row"] = row
                StreamedTranscodeDownload.apply(format, to: &entry, source: source)
                built.append((itemID, id, entry, entry["row"] as? [String: Any] ?? row))
            } catch JellyfinError.invalidResponse, JellyfinError.invalidURL {
                continue
            }
        }
        return built
    }

    /// Episodes without a live stored entry are registered fresh. A stored
    /// copy that was never finished ("ready" or "downloading") is returned
    /// again as ready under its own ID, so a failed local copy queues again.
    /// Completed copies are left alone. Stored copies are read in ID order,
    /// so the first unfinished one wins.
    nonisolated static func batchResult(built: [BatchEpisode],
                                        stored: [String: [String: Any]]) -> (fresh: [BatchEpisode], rows: [[String: Any]]) {
        var known = Set<String>()
        var unfinished: [String: [String: Any]] = [:]
        for (_, entry) in stored.sorted(by: { $0.key < $1.key }) {
            guard !isDeletionPending(entry), let itemID = entry["itemID"] as? String else { continue }
            known.insert(itemID)
            if unfinished[itemID] == nil, var row = entry["row"] as? [String: Any],
               let status = row["status"] as? String, ["ready", "downloading"].contains(status) {
                row["status"] = "ready"
                unfinished[itemID] = row
            }
        }
        var fresh: [BatchEpisode] = []
        var rows: [[String: Any]] = []
        for episode in built {
            if let row = unfinished[episode.itemID] {
                rows.append(row)
            } else if !known.contains(episode.itemID) {
                fresh.append(episode)
                rows.append(episode.row)
            }
        }
        return (fresh, rows)
    }

    /// Present episodes with a usable first source, once each, in server order.
    nonisolated static func downloadableEpisodes(_ items: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        return items.filter { raw in
            guard raw["Type"] as? String == "Episode",
                  raw["LocationType"] as? String != "Virtual",
                  raw["IsMissing"] as? Bool != true,
                  let id = raw["Id"] as? String, (try? JellyfinConnection.id(id)) != nil,
                  let sourceID = (raw["MediaSources"] as? [[String: Any]])?.first?["Id"] as? String,
                  (try? JellyfinConnection.id(sourceID)) != nil else { return false }
            return seen.insert(id).inserted
        }
    }

    /// A new registration for one source: the stored entry and the row it
    /// lists.
    private static func record(id: String, raw: [String: Any], itemID: String, source: [String: Any], sourceID: String,
                               format: DownloadFormat, batchID: String? = nil,
                               adapter: JellyfinAdapter) throws -> (entry: [String: Any], row: [String: Any]) {
        _ = try JellyfinConnection.id(sourceID)
        var manifest = try manifest(id: id, raw: raw, source: source, adapter: adapter)
        // A transcoded file leaves out the source's embedded text subtitles,
        // so those are saved as files too (the server extracts them).
        manifest["subtitles"] = try subtitleFiles(in: source, itemID: itemID, sourceID: sourceID,
                                                  keepsEmbedded: format == .original,
                                                  serverURL: adapter.connection.serverURL)
        var row: [String: Any] = [
            "id": id,
            "contentId": itemID,
            "mediaFileId": JellyfinAdapter.numberID(sourceID),
            "status": "ready",
            "quality": format.rawValue,
            "revision": 1,
        ]
        row["fileSize"] = source["Size"]
        if raw["Type"] as? String == "Episode" { row["episodeId"] = itemID }
        row["batchId"] = batchID
        return (["manifest": manifest, "itemID": itemID, "sourceID": sourceID, "row": row], row)
    }

    /// The source's text subtitles to save as files: external ones always,
    /// embedded ones too when the downloaded file won't keep them. The
    /// stream index and label match the online sidecar, so a chosen subtitle
    /// keeps its track ID offline.
    private static func subtitleFiles(in source: [String: Any], itemID: String, sourceID: String, keepsEmbedded: Bool,
                                      serverURL: String) throws -> [[String: Any]] {
        let streams = source["MediaStreams"] as? [[String: Any]] ?? []
        return try streams.compactMap { stream -> [String: Any]? in
            let external = stream["IsExternal"] as? Bool == true
            guard stream["Type"] as? String == "Subtitle", external || !keepsEmbedded,
                  let index = stream["Index"] as? Int, let codec = stream["Codec"] as? String,
                  textSubtitleCodecs.contains(codec.lowercased()) else { return nil }
            let format = ServerSubtitleSidecars.format(codec)
            let url = try JellyfinConnection.url(serverURL: serverURL,
                                                 path: "/Videos/\(JellyfinConnection.id(itemID))/\(sourceID)/Subtitles/\(index)/Stream.\(format)")
            var subtitle: [String: Any] = ["fetchUrl": url.absoluteString, "format": format, "external": external]
            subtitle["language"] = stream["Language"]
            subtitle["forced"] = stream["IsForced"]
            subtitle["hearingImpaired"] = stream["IsHearingImpaired"]
            subtitle["index"] = index
            subtitle["title"] = stream["DisplayTitle"]
            subtitle["isDefault"] = stream["IsDefault"]
            return subtitle
        }
    }

    /// The offline manifest for an item and one of its sources.
    static func manifest(id: String, raw: [String: Any], source: [String: Any], adapter: JellyfinAdapter) throws -> [String: Any] {
        var manifest = try adapter.item(raw)
        let version = try adapter.version(source, chapters: raw["Chapters"] as? [[String: Any]] ?? [])
        guard let sourceID = source["Id"] as? String else { throw JellyfinError.invalidResponse }
        manifest.removeValue(forKey: "versions")
        manifest["downloadId"] = id
        manifest["quality"] = "original"
        manifest["mediaFileId"] = JellyfinAdapter.numberID(sourceID)
        manifest["revision"] = 1
        manifest["manifestVersion"] = 1
        for key in ["container", "codecVideo", "codecAudio", "resolution", "hdr", "fileSize", "audioTracks", "chapters"] {
            manifest[key] = version[key]
        }
        manifest["durationSeconds"] = version["duration"]
        manifest["selectedAudioTrackIndex"] = version["effectiveAudioTrackIndex"]
        var artwork: [String: Any] = [:]
        artwork["poster"] = manifest["posterUrl"]
        artwork["backdrop"] = manifest["backdropUrl"]
        artwork["logo"] = manifest["logoUrl"]
        manifest["artworkUrls"] = artwork
        if raw["Type"] as? String == "Episode" { manifest["episodeId"] = raw["Id"] }
        return manifest
    }

    // MARK: Status updates

    /// The row after a transfer status update, or nil when the update is
    /// stale. Updates share a content revision, so timestamps order writes
    /// within one revision, and a completed transfer can't go back to
    /// downloading on a replay.
    nonisolated static func updatedStatus(row: [String: Any], body: [String: Any]) throws -> [String: Any]? {
        let storedRevision = row["revision"] as? Int ?? 0
        let revision = body["revision"] as? Int ?? storedRevision
        guard revision >= storedRevision else { return nil }
        let updatedAt = body["updated_at"] as? String ?? body["updatedAt"] as? String
        let incomingDate = try updatedAt.map(timestamp)
        if revision == storedRevision {
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

    /// An ISO 8601 time, with or without fractional seconds.
    private nonisolated static func timestamp(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw JellyfinError.invalidResponse }
        return date
    }

    // MARK: The file

    /// Where the background transfer fetches the file: the transcoded stream
    /// or the original.
    func fileURL(id: String, connection: JellyfinConnection) async throws -> URL {
        try await connection.validate()
        guard let entry = try load(connection)[id],
              let itemID = entry["itemID"] as? String,
              let sourceID = entry["sourceID"] as? String else { throw JellyfinError.invalidResponse }
        if let format = StreamedTranscodeDownload.format(of: entry) {
            guard let query = StreamedTranscodeDownload.query(format: format, sourceID: sourceID,
                                                              audioStreamIndex: entry["audioStreamIndex"] as? Int,
                                                              deviceID: JellyfinConnection.deviceID) else {
                throw JellyfinError.invalidResponse
            }
            return try JellyfinConnection.url(serverURL: connection.serverURL,
                                              path: "/Videos/\(JellyfinConnection.id(itemID))/stream.mp4", query: query)
        }
        return try JellyfinConnection.url(serverURL: connection.serverURL, path: "/Videos/\(JellyfinConnection.id(itemID))/stream",
                                          query: ["Static": "true", "MediaSourceId": sourceID])
    }

    // MARK: Request fields

    /// The requested quality, the original when none is named, or nil for
    /// one the app doesn't know.
    private static func format(in body: [String: Any]) -> DownloadFormat? {
        DownloadFormat(rawValue: body["quality"] as? String ?? "original")
    }

    /// The request leaves the field out or sends null.
    private static func isAbsent(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func isDeletionPending(_ entry: [String: Any]) -> Bool {
        entry["deletionPending"] as? Bool == true
    }

    // MARK: Stored registrations

    /// Each account and user keeps its own registrations.
    private func storageKey(_ connection: JellyfinConnection) throws -> String {
        guard let account = connection.identity?.account, let user = connection.userID else { throw JellyfinError.signInRequired }
        return "vivid.jellyfin.downloads." + account.serverId + "." + user
    }

    private func load(_ connection: JellyfinConnection) throws -> Store {
        guard let data = UserDefaults.standard.data(forKey: try storageKey(connection)) else { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? Store ?? [:]
    }

    private func save(_ store: Store, connection: JellyfinConnection) throws {
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: store), forKey: try storageKey(connection))
    }
}
