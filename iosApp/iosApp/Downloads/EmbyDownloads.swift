import Foundation
import OSLog

/// Downloads on an Emby server, answering the app's `/api/v1/downloads`
/// routes. Emby keeps no download records, so each account's registrations
/// are stored on the device: the offline manifest, the item and source the
/// file comes from, and the row the download list shows.
///
/// The original file comes straight from the server. A smaller quality is
/// streamed through the playback transcoder ([StreamedTranscodeDownload]),
/// or, for an account that may only use Emby's conversion service, made by
/// a conversion job first ([EmbyDownloadConversion]).
actor EmbyDownloads {
    static let shared = EmbyDownloads()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app", category: "Downloads")

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

    /// A stored registration: `manifest`, `itemID`, `sourceID` and `row`;
    /// `transcode` and `audioStreamIndex` for a streamed quality; and for a
    /// conversion `syncJobID`, `syncItemID`, `sourceItem` until it's ready,
    /// and the `deletionPending` and `transferAcknowledgementPending` flags.
    private typealias Entry = [String: Any]
    /// Every stored registration of one account, by download ID.
    private typealias Store = [String: Entry]

    /// Text subtitle codecs the server can hand over as a file.
    private static let textSubtitleCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]

    // MARK: Routes

    func route(connection: EmbyConnection, method: String, path: [String], body: [String: Any]) async throws -> Any {
        try await connection.validate()
        guard let user = connection.userID else { throw EmbyError.signInRequired }
        if path.last == "capability" {
            return try await capability(connection: connection, user: user)
        }
        if path.count == 3, method == "POST" {
            return try await register(connection: connection, user: user, body: body)
        }
        if path.count == 3, method == "GET" {
            try await refreshConversions(connection: connection)
            return ["downloads": try load(connection).values.filter { !Self.isDeletionPending($0) }.compactMap { $0["row"] }]
        }
        return try await routeDownload(connection: connection, method: method, path: path, body: body)
    }

    /// The routes for one stored download: its manifest, removing it, and
    /// status updates from the transfer.
    private func routeDownload(connection: EmbyConnection, method: String, path: [String], body: [String: Any]) async throws -> Any {
        var store = try load(connection)
        guard path.count >= 4, var entry = store[path[3]] else { throw HTTPError.http(statusCode: 404, body: nil) }
        let id = path[3]
        if path.count == 5, path[4] == "manifest", method == "GET" {
            return entry["manifest"] ?? [:]
        }
        if method == "DELETE", path.count == 4 {
            if entry["syncJobID"] != nil {
                // The job is removed first; the record stays, out of the list,
                // until the server confirms.
                entry["deletionPending"] = true
                store[id] = entry
                try save(store, connection: connection)
                await removeConversion(id: id, connection: connection)
                return [:]
            }
            try await connection.validate()
            store = try load(connection)
            store.removeValue(forKey: id)
            try save(store, connection: connection)
            return [:]
        }
        if method == "PATCH", path.count == 4, let status = body["status"] as? String, ["downloading", "completed"].contains(status) {
            var row = entry["row"] as? [String: Any] ?? [:]
            row["status"] = status
            entry["row"] = row
            let acknowledges = status == "completed" && entry["syncItemID"] != nil
            if acknowledges { entry["transferAcknowledgementPending"] = true }
            store[id] = entry
            try save(store, connection: connection)
            if status == "completed" { await acknowledgeTransfer(id: id, connection: connection) }
            return [:]
        }
        throw EmbyError.unsupportedFeature
    }

    // MARK: Capability

    private func capability(connection: EmbyConnection, user: String) async throws -> [String: Any] {
        let policy = try await policy(connection: connection, user: user)
        let formats = try await offeredFormats(connection: connection, policy: policy)
        let smaller = formats.count > 1
        return [
            "enabled": true,
            "downloadAllowed": policy["EnableContentDownloading"] as? Bool ?? false,
            "qualityPresets": formats.map(\.rawValue),
            "transcodeEnabled": smaller,
            "transcodeUserAllowed": smaller,
            "seasonDownload": true,
            "seriesMonitoring": false,
            "bulkQuality": smaller,
            "versionTranscodes": StreamedTranscodeDownload.isAllowed(policy: policy),
        ]
    }

    private func policy(connection: EmbyConnection, user: String) async throws -> [String: Any] {
        let account = try await connection.object("GET", "/Users/\(user)")
        return account["Policy"] as? [String: Any] ?? [:]
    }

    /// Every quality when the account may transcode playback, or when Emby's
    /// conversion service works for it; otherwise only the original.
    private func offeredFormats(connection: EmbyConnection, policy: [String: Any]) async throws -> [DownloadFormat] {
        #if os(iOS)
        if StreamedTranscodeDownload.isAllowed(policy: policy) { return DownloadFormat.allCases }
        if EmbyDownloadConversion.isAllowed(policy: policy) {
            do {
                _ = try await EmbyDownloadConversion.availableOptions(connection: connection)
                return DownloadFormat.allCases
            } catch {
                // A disabled or unavailable conversion service mustn't break
                // original-file downloads. An identity change or cancellation
                // still ends the request.
                try await connection.validate()
                let status: Int? = if case HTTPError.http(let code, _) = error { code } else { nil }
                Self.logger.info("Emby conversion unavailable, offering original only (HTTP \(status ?? 0, privacy: .public))")
            }
        }
        #endif
        return [.original]
    }

    // MARK: Registering

    private func register(connection: EmbyConnection, user: String, body: [String: Any]) async throws -> Any {
        let policy = try await policy(connection: connection, user: user)
        guard policy["EnableContentDownloading"] as? Bool == true else { throw EmbyError.unsupportedFeature }
        if body["series"] as? Bool == true || body["season_number"] != nil {
            return try await registerEpisodes(connection: connection, user: user, body: body, policy: policy)
        }
        return try await registerItem(connection: connection, user: user, body: body, policy: policy)
    }

    /// One movie or episode, in the file asked for or the first one.
    private func registerItem(connection: EmbyConnection, user: String, body: [String: Any], policy: [String: Any]) async throws -> Any {
        guard let format = Self.format(in: body),
              let itemID = body["episode_id"] as? String ?? body["content_id"] as? String else {
            throw EmbyError.unsupportedFeature
        }
        let conversion = try await conversionForItem(connection: connection, policy: policy, format: format, itemID: itemID,
                                                     fileRequested: !Self.isAbsent(body["file_id"]))
        let adapter = EmbyAdapter(connection: connection)
        let raw = try await adapter.rawItem(itemID)
        let sources = raw["MediaSources"] as? [[String: Any]] ?? []
        let source = if let requested = body["file_id"] as? Int {
            sources.first { ($0["Id"] as? String).map(EmbyAdapter.numberID) == requested }
        } else {
            sources.first
        }
        guard let source, let sourceID = source["Id"] as? String else { throw EmbyError.playbackUnavailable }

        let id = "emby-" + UUID().uuidString
        var (entry, row) = try Self.record(id: id, raw: raw, itemID: itemID, source: source, sourceID: sourceID,
                                           format: format, adapter: adapter)
        // Episode rows name their series, as batch rows and Silo's do. The
        // manifest's SeriesId can be another series item for the same show,
        // so this keeps the download tied to the series it was asked for.
        if row["episodeId"] != nil, let seriesID = body["content_id"] as? String { row["contentId"] = seriesID }
        var createdJobID: String?
        if let conversion {
            let request = try EmbyDownloadConversion.request(itemID: itemID, userID: user, format: format, options: conversion)
            let job = try EmbyDownloadConversion.creation(try await connection.object("POST", "/Sync/Jobs", body: request))
            createdJobID = job.jobID
            entry["syncJobID"] = job.jobID
            entry["syncItemID"] = job.itemID
            entry["sourceItem"] = raw
            Self.markPreparing(&row, format: format)
        }
        entry["row"] = row
        // Without a conversion job the playback transcoder streams the
        // smaller file instead.
        if conversion == nil { StreamedTranscodeDownload.apply(format, to: &entry, source: source) }
        do {
            try await connection.validate()
            var store = try load(connection)
            store[id] = entry
            try save(store, connection: connection)
        } catch {
            if let createdJobID { discardUntrackedJob(createdJobID, connection: connection) }
            throw error
        }
        return ["downloads": [entry["row"] ?? row]]
    }

    /// The conversion options for a single item at a smaller quality, or nil
    /// when it streams through the playback transcoder (or is the original).
    /// A chosen file can only stream: Emby picks the source it converts.
    private func conversionForItem(connection: EmbyConnection, policy: [String: Any], format: DownloadFormat, itemID: String,
                                   fileRequested: Bool) async throws -> EmbyDownloadConversion.Options? {
        guard format != .original else { return nil }
        #if os(iOS)
        // The playback transcoder streams the file in the background session,
        // so it keeps going with the app closed. Emby's conversion service,
        // which only moves on while Vivid checks on it, is the fallback for
        // accounts that can't transcode.
        let streams = StreamedTranscodeDownload.isAllowed(policy: policy)
        let conversion = fileRequested || streams
            ? nil
            : try await conversionOptions(connection: connection, policy: policy, itemID: itemID)
        guard conversion != nil || streams else { throw EmbyError.unsupportedFeature }
        return conversion
        #else
        throw EmbyError.unsupportedFeature
        #endif
    }

    /// Series and season batches register each present episode. Original
    /// files are saved in one write; a smaller quality streams through the
    /// playback transcoder, or gets a conversion job per episode for an
    /// account that can only use Emby's conversion service.
    private func registerEpisodes(connection: EmbyConnection, user: String, body: [String: Any], policy: [String: Any]) async throws -> Any {
        let season = body["season_number"] as? Int
        guard let format = Self.format(in: body),
              format == .original || EmbyDownloadConversion.isAllowed(policy: policy) || StreamedTranscodeDownload.isAllowed(policy: policy),
              Self.isAbsent(body["file_id"]), Self.isAbsent(body["episode_id"]),
              body["season_number"] == nil || season != nil,
              let seriesID = body["content_id"] as? String else { throw EmbyError.unsupportedFeature }
        var query = [
            "UserId": user,
            "Fields": EmbyAdapter.fields,
            "EnableUserData": "true",
            "IsMissing": "false",
            "Recursive": "false",
            "IncludeItemTypes": "Episode",
            "SortBy": "ParentIndexNumber,IndexNumber",
            "SortOrder": "Ascending",
        ]
        if let season { query["Season"] = String(season) }
        let result = try await connection.object("GET", "/Shows/\(EmbyConnection.id(seriesID))/Episodes", query: query)
        guard let items = result["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }

        let adapter = EmbyAdapter(connection: connection)
        if let conversion = try await conversionForBatch(connection: connection, policy: policy, format: format, items: items) {
            let built = try Self.convertedBatchEpisodes(items, body: body, format: format, adapter: adapter)
            guard !built.isEmpty else { throw BatchError.noEpisodes }
            return try await registerConvertedEpisodes(built, items: items, format: format, options: conversion,
                                                       connection: connection, user: user)
        }
        let built = try Self.batchEpisodes(items, body: body, format: format, adapter: adapter)
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

    /// The conversion options for a batch at a smaller quality, sampled from
    /// its first downloadable episode, or nil when it streams (or is the
    /// original).
    private func conversionForBatch(connection: EmbyConnection, policy: [String: Any], format: DownloadFormat,
                                    items: [[String: Any]]) async throws -> EmbyDownloadConversion.Options? {
        guard format != .original else { return nil }
        #if os(iOS)
        let streams = StreamedTranscodeDownload.isAllowed(policy: policy)
        var conversion: EmbyDownloadConversion.Options?
        if !streams, let sample = Self.downloadableEpisodes(items).first?["Id"] as? String {
            conversion = try await conversionOptions(connection: connection, policy: policy, itemID: sample)
        }
        guard conversion != nil || streams else { throw EmbyError.unsupportedFeature }
        return conversion
        #else
        throw EmbyError.unsupportedFeature
        #endif
    }

    /// A converted batch: one conversion job for each episode not already
    /// stored, saved as each job is made so an interruption never repeats a
    /// conversion. Episodes with a stored copy keep it, as with originals.
    private func registerConvertedEpisodes(_ built: [BatchEpisode], items: [[String: Any]], format: DownloadFormat,
                                           options: EmbyDownloadConversion.Options, connection: EmbyConnection,
                                           user: String) async throws -> Any {
        try await connection.validate()
        let batch = Self.batchResult(built: built, stored: try load(connection))
        guard !batch.rows.isEmpty else { throw BatchError.alreadyDownloaded }
        let freshIDs = Set(batch.fresh.map(\.id))
        var rows = batch.rows.filter { !freshIDs.contains($0["id"] as? String ?? "") }
        let rawByID = Dictionary(items.compactMap { raw in (raw["Id"] as? String).map { ($0, raw) } },
                                 uniquingKeysWith: { first, _ in first })
        var firstError: Error?
        for episode in batch.fresh {
            do {
                var entry = episode.entry
                var row = episode.row
                let request = try EmbyDownloadConversion.request(itemID: episode.itemID, userID: user, format: format, options: options)
                let job = try EmbyDownloadConversion.creation(try await connection.object("POST", "/Sync/Jobs", body: request))
                entry["syncJobID"] = job.jobID
                entry["syncItemID"] = job.itemID
                entry["sourceItem"] = rawByID[episode.itemID]
                row["quality"] = format.rawValue
                Self.markPreparing(&row, format: format)
                entry["row"] = row
                do {
                    try await connection.validate()
                    var store = try load(connection)
                    store[episode.id] = entry
                    try save(store, connection: connection)
                } catch {
                    discardUntrackedJob(job.jobID, connection: connection)
                    throw error
                }
                rows.append(row)
            } catch is CancellationError {
                throw CancellationError()
            } catch HTTPError.requestIdentityChanged {
                throw HTTPError.requestIdentityChanged
            } catch {
                // Keep the episodes already queued; report only a total failure.
                firstError = firstError ?? error
            }
        }
        if rows.isEmpty, let firstError { throw firstError }
        return ["downloads": rows]
    }

    /// Emby's conversion service for this account and item, or nil when it
    /// isn't available. An identity change or cancellation still ends the
    /// request.
    private func conversionOptions(connection: EmbyConnection, policy: [String: Any],
                                   itemID: String) async throws -> EmbyDownloadConversion.Options? {
        #if os(iOS)
        guard EmbyDownloadConversion.isAllowed(policy: policy) else { return nil }
        do {
            return try await EmbyDownloadConversion.availableOptions(connection: connection, itemID: itemID)
        } catch {
            try await connection.validate()
            return nil
        }
        #else
        return nil
        #endif
    }

    /// A conversion job made just before a cancellation or account switch
    /// was never saved, so nothing would track or clean it up. It's removed
    /// with the token that made it, outside the cancelled request.
    private func discardUntrackedJob(_ jobID: String, connection: EmbyConnection) {
        let owner = EmbyConnection(serverURL: connection.serverURL, token: connection.token, userID: connection.userID,
                                   identity: nil, sessionOverride: connection.sessionOverride)
        Task { _ = try? await owner.request("DELETE", "/Sync/Jobs/\(EmbyConnection.id(jobID))") }
    }

    // MARK: Building registrations

    /// Registrations for each downloadable episode, in server order: the
    /// original file, or a stream transcoded to `format`.
    nonisolated static func batchEpisodes(_ items: [[String: Any]], body: [String: Any], format: DownloadFormat = .original,
                                          adapter: EmbyAdapter) throws -> [BatchEpisode] {
        try episodeRegistrations(items, body: body, format: format, streamed: true, adapter: adapter)
    }

    /// Registrations for each downloadable episode of a converted batch, in
    /// server order. They describe the original file until the conversion is
    /// ready, but save embedded text subtitles as files as any smaller
    /// quality does, since the converted file leaves them out.
    nonisolated static func convertedBatchEpisodes(_ items: [[String: Any]], body: [String: Any], format: DownloadFormat,
                                                   adapter: EmbyAdapter) throws -> [BatchEpisode] {
        try episodeRegistrations(items, body: body, format: format, streamed: false, adapter: adapter)
    }

    private nonisolated static func episodeRegistrations(_ items: [[String: Any]], body: [String: Any], format: DownloadFormat,
                                                         streamed: Bool, adapter: EmbyAdapter) throws -> [BatchEpisode] {
        var built: [BatchEpisode] = []
        for raw in downloadableEpisodes(items) {
            try Task.checkCancellation()
            guard let itemID = raw["Id"] as? String,
                  let source = (raw["MediaSources"] as? [[String: Any]])?.first,
                  let sourceID = source["Id"] as? String else { continue }
            let id = "emby-" + UUID().uuidString
            do {
                var (entry, row) = try record(id: id, raw: raw, itemID: itemID, source: source, sourceID: sourceID,
                                              format: streamed ? format : .original, keepsEmbeddedSubtitles: format == .original,
                                              batchID: body["batch_id"] as? String, adapter: adapter)
                // Episode rows name their series, as Silo's do; the episode
                // stays in episodeId.
                row["contentId"] = body["content_id"] as? String ?? itemID
                entry["row"] = row
                if streamed { StreamedTranscodeDownload.apply(format, to: &entry, source: source) }
                built.append((itemID, id, entry, entry["row"] as? [String: Any] ?? row))
            } catch EmbyError.invalidResponse, EmbyError.invalidURL {
                continue
            }
        }
        return built
    }

    /// Episodes without a live stored entry are registered fresh. A stored
    /// copy that was never finished ("ready" or "downloading") is returned
    /// again as ready under its own ID, so a failed local copy queues again.
    /// Completed, converting and failed copies are left alone. Stored copies
    /// are read in ID order, so the first unfinished one wins.
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
                  let id = raw["Id"] as? String, (try? EmbyConnection.id(id)) != nil,
                  let sourceID = (raw["MediaSources"] as? [[String: Any]])?.first?["Id"] as? String,
                  (try? EmbyConnection.id(sourceID)) != nil else { return false }
            return seen.insert(id).inserted
        }
    }

    /// A new registration for one source: the stored entry and the row it
    /// lists. A smaller quality also saves the embedded text subtitles as
    /// files (the server extracts them), since a transcoded file leaves them
    /// out.
    private static func record(id: String, raw: [String: Any], itemID: String, source: [String: Any], sourceID: String,
                               format: DownloadFormat, keepsEmbeddedSubtitles: Bool? = nil, batchID: String? = nil,
                               adapter: EmbyAdapter) throws -> (entry: [String: Any], row: [String: Any]) {
        _ = try EmbyConnection.id(sourceID)
        var manifest = try manifest(id: id, raw: raw, source: source, adapter: adapter)
        manifest["subtitles"] = try subtitleFiles(in: source, itemID: itemID, sourceID: sourceID,
                                                  keepsEmbedded: keepsEmbeddedSubtitles ?? (format == .original),
                                                  serverURL: adapter.connection.serverURL)
        var row: [String: Any] = [
            "id": id,
            "contentId": itemID,
            "mediaFileId": EmbyAdapter.numberID(sourceID),
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
            let url = try EmbyConnection.url(serverURL: serverURL,
                                             path: "/Videos/\(EmbyConnection.id(itemID))/\(sourceID)/Subtitles/\(index)/Stream.\(format)")
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
    static func manifest(id: String, raw: [String: Any], source: [String: Any], adapter: EmbyAdapter) throws -> [String: Any] {
        var manifest = try adapter.item(raw)
        let version = try adapter.version(source, chapters: raw["Chapters"] as? [[String: Any]] ?? [])
        guard let sourceID = source["Id"] as? String else { throw EmbyError.invalidResponse }
        manifest.removeValue(forKey: "versions")
        manifest["downloadId"] = id
        manifest["quality"] = "original"
        manifest["mediaFileId"] = EmbyAdapter.numberID(sourceID)
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

    /// A conversion row waits for the server to make the file.
    private static func markPreparing(_ row: inout [String: Any], format: DownloadFormat) {
        row["status"] = "preparing"
        row["fileSize"] = 0
        row["targetBitrateKbps"] = format.targetBitrateKbps
    }

    // MARK: The file

    /// Where the background transfer fetches the file: the converted file,
    /// the transcoded stream, or the original.
    func fileURL(id: String, connection: EmbyConnection) async throws -> URL {
        try await connection.validate()
        guard let entry = try load(connection)[id],
              let itemID = entry["itemID"] as? String,
              let sourceID = entry["sourceID"] as? String else { throw EmbyError.invalidResponse }
        if let syncItemID = entry["syncItemID"] as? String {
            guard let status = (entry["row"] as? [String: Any])?["status"] as? String,
                  ["ready", "downloading", "completed"].contains(status) else { throw EmbyError.playbackUnavailable }
            return try EmbyConnection.url(serverURL: connection.serverURL, path: "/Sync/JobItems/\(EmbyConnection.id(syncItemID))/File")
        }
        if let format = StreamedTranscodeDownload.format(of: entry) {
            guard let query = StreamedTranscodeDownload.query(format: format, sourceID: sourceID,
                                                              audioStreamIndex: entry["audioStreamIndex"] as? Int,
                                                              deviceID: EmbyConnection.deviceID) else { throw EmbyError.invalidResponse }
            return try EmbyConnection.url(serverURL: connection.serverURL, path: "/Videos/\(EmbyConnection.id(itemID))/stream.mp4", query: query)
        }
        return try EmbyConnection.url(serverURL: connection.serverURL, path: "/Videos/\(EmbyConnection.id(itemID))/stream",
                                      query: ["Static": "true", "MediaSourceId": sourceID])
    }

    // MARK: Conversion jobs

    /// Finishes pending removals and acknowledgements, then, while a
    /// conversion is being prepared, reads every job item for this device
    /// and moves each preparing row on. A ready one gets the converted
    /// file's manifest.
    private func refreshConversions(connection: EmbyConnection) async throws {
        let snapshot = try load(connection)
        for (id, entry) in snapshot where Self.isDeletionPending(entry) {
            await removeConversion(id: id, connection: connection)
        }
        for (id, entry) in snapshot where entry["transferAcknowledgementPending"] as? Bool == true {
            await acknowledgeTransfer(id: id, connection: connection)
        }
        guard snapshot.values.contains(where: { Self.isPreparingConversion($0) }) else { return }
        let response = try await connection.object("GET", "/Sync/JobItems", query: ["TargetId": EmbyConnection.deviceID])
        guard let items = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        try await connection.validate()
        var store = try load(connection)
        for (id, var entry) in store {
            guard Self.isPreparingConversion(entry),
                  let syncID = entry["syncItemID"] as? String,
                  let jobID = entry["syncJobID"] as? String,
                  var row = entry["row"] as? [String: Any],
                  let item = items.first(where: { Self.isJobItem($0, syncID: syncID, jobID: jobID) }) else { continue }
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
            row["status"] = status
            entry["row"] = row
            store[id] = entry
        }
        try save(store, connection: connection)
    }

    /// Tells the server a converted file has arrived. When that fails, the
    /// flag stays for the next refresh instead of downloading it again.
    private func acknowledgeTransfer(id: String, connection: EmbyConnection) async {
        do {
            guard let entry = try load(connection)[id],
                  !Self.isDeletionPending(entry),
                  entry["transferAcknowledgementPending"] as? Bool == true,
                  let syncID = entry["syncItemID"] as? String else { return }
            _ = try await connection.request("POST", "/Sync/JobItems/\(EmbyConnection.id(syncID))/Transferred")
            var store = try load(connection)
            store[id]?.removeValue(forKey: "transferAcknowledgementPending")
            try save(store, connection: connection)
        } catch {
            // The local file is already complete.
        }
    }

    /// Deletes a removed download's conversion job, then its record. While
    /// that fails only the cleanup record stays: out of the download list,
    /// and retried without bringing the deleted download back.
    private func removeConversion(id: String, connection: EmbyConnection) async {
        do {
            guard let entry = try load(connection)[id], Self.isDeletionPending(entry),
                  let jobID = entry["syncJobID"] as? String else { return }
            do {
                _ = try await connection.request("DELETE", "/Sync/Jobs/\(EmbyConnection.id(jobID))")
            } catch HTTPError.http(let status, _) where status == 404 {
                // Already gone.
            }
            try await connection.validate()
            var store = try load(connection)
            store.removeValue(forKey: id)
            try save(store, connection: connection)
        } catch {
            // Retried on the next refresh.
        }
    }

    private static func isDeletionPending(_ entry: [String: Any]) -> Bool {
        entry["deletionPending"] as? Bool == true
    }

    private static func isPreparingConversion(_ entry: [String: Any]) -> Bool {
        !isDeletionPending(entry) && entry["syncItemID"] != nil
            && (entry["row"] as? [String: Any])?["status"] as? String == "preparing"
    }

    /// The job item belongs to this registration and this device.
    private static func isJobItem(_ item: [String: Any], syncID: String, jobID: String) -> Bool {
        (try? EmbyDownloadConversion.identifier(item["Id"])) == syncID
            && (try? EmbyDownloadConversion.identifier(item["JobId"])) == jobID
            && item["TargetId"] as? String == EmbyConnection.deviceID
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

    // MARK: Stored registrations

    /// Each account and user keeps its own registrations.
    private func storageKey(_ connection: EmbyConnection) throws -> String {
        guard let account = connection.identity?.account, let user = connection.userID else { throw EmbyError.signInRequired }
        return "vivid.emby.downloads." + account.serverId + "." + user
    }

    private func load(_ connection: EmbyConnection) throws -> Store {
        guard let data = UserDefaults.standard.data(forKey: try storageKey(connection)) else { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? Store ?? [:]
    }

    private func save(_ store: Store, connection: EmbyConnection) throws {
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: store), forKey: try storageKey(connection))
    }
}
