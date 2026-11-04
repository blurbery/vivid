import CryptoKit
import Foundation

/// Turns Emby's API into the Silo-shaped JSON Vivid's models decode. The
/// shared HTTP client hands an Emby account's `/api/v1` requests to `route`
/// (in `EmbyProvider+Routes.swift`); this file converts items, versions and
/// tracks, and `EmbyProvider+Home.swift` builds Home.
struct EmbyAdapter {
    let connection: EmbyConnection
    var userID: String { connection.userID! }

    static let fields = "ProductionYear,Overview,Genres,Studios,People,ProviderIds,MediaSources,MediaStreams,Chapters,DateCreated,UserData,SortName,Taglines,ChildCount,RecursiveItemCount,PrimaryImageAspectRatio"
    /// Grid and search pages never show cast, chapters or file details, so
    /// they skip the heaviest fields, matching Jellyfin's browse requests.
    static let browseFields = "ProductionYear,Overview,Genres,Studios,ProviderIds,DateCreated,UserData,SortName,ChildCount,RecursiveItemCount,PrimaryImageAspectRatio"
    /// Home rows keep media sources for their format badges. Each source
    /// already carries its streams, so the item-level copy isn't requested.
    static let homeFields = browseFields + ",MediaSources"

    // MARK: - Values

    /// Emby ticks (100 ns) as seconds; anything missing, negative or not
    /// finite reads as 0.
    static func seconds(_ ticks: Any?) -> Double {
        guard let number = ticks as? NSNumber else { return 0 }
        let value = number.doubleValue / 10_000_000
        return value.isFinite ? max(0, value) : 0
    }

    /// The whole-number ID Vivid's models need for an Emby ID: the number
    /// itself when it is one, otherwise 56 bits of its SHA-256.
    static func numberID(_ raw: String) -> Int {
        if let numeric = Int(raw), numeric >= 0 { return numeric }
        return SHA256.hash(data: Data(raw.utf8)).prefix(7).reduce(0) { ($0 << 8) | Int($1) }
    }

    /// One item's watch state as a `ProgressPullItem` row. Emby clears the
    /// position when it marks an item played, so played rows report 0.
    static func progress(_ raw: [String: Any]) -> [String: Any]? {
        guard let id = raw["Id"] as? String, (try? EmbyConnection.id(id)) != nil else { return nil }
        let user = raw["UserData"] as? [String: Any] ?? [:]
        return [
            "mediaItemId": id,
            "positionSeconds": seconds(user["PlaybackPositionTicks"]),
            "durationSeconds": seconds(raw["RunTimeTicks"]),
            "completed": user["Played"] as? Bool ?? false,
        ]
    }

    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }

    // MARK: - Images

    /// An image URL for `kind` (Primary, Backdrop or Logo), falling back to
    /// the parent's or series' image when the item has none of its own.
    func image(_ item: [String: Any], kind: String) -> String? {
        let tags = item["ImageTags"] as? [String: Any] ?? [:]
        var imageID = item["Id"] as? String
        var tag = tags[kind] as? String
        switch kind {
        case "Backdrop":
            tag = (item["BackdropImageTags"] as? [String])?.first
            if tag == nil {
                imageID = item["ParentBackdropItemId"] as? String
                tag = (item["ParentBackdropImageTags"] as? [String])?.first
            }
        case "Primary" where tag == nil:
            imageID = item["SeriesId"] as? String
            tag = item["SeriesPrimaryImageTag"] as? String
        case "Logo" where tag == nil:
            imageID = item["ParentLogoItemId"] as? String
            tag = item["ParentLogoImageTag"] as? String
        default:
            break
        }
        guard let imageID, let tag, (try? EmbyConnection.id(imageID)) != nil else { return nil }
        let query = ["tag": tag, "maxWidth": kind == "Backdrop" ? "1920" : "780", "quality": "90"]
        return try? EmbyConnection.url(serverURL: connection.serverURL, path: "/Items/\(imageID)/Images/\(kind)", query: query).absoluteString
    }

    // MARK: - Items

    func item(_ raw: [String: Any]) throws -> [String: Any] {
        try item(raw, watchlist: Set(watchlistIDs))
    }

    /// Converts a page of items, reading the watchlist once rather than per item.
    func convert(_ rows: [[String: Any]]) throws -> [[String: Any]] {
        let watchlist = Set(watchlistIDs)
        return try rows.map { try item($0, watchlist: watchlist) }
    }

    /// Fields copied across as they are, Emby name > Vivid name.
    private static let copiedItemFields = [
        "ProductionYear": "year", "Overview": "overview", "OfficialRating": "contentRating",
        "Genres": "genres", "CommunityRating": "ratingTmdb", "CriticRating": "ratingRtCritic",
        "PremiereDate": "releaseDate", "DateCreated": "addedAt", "SeriesId": "seriesId",
        "SeriesName": "seriesTitle", "ParentIndexNumber": "seasonNumber", "IndexNumber": "episodeNumber",
        "ChildCount": "episodeCount", "Status": "showStatus", "SortName": "sortTitle",
    ]

    func item(_ raw: [String: Any], watchlist: Set<String>) throws -> [String: Any] {
        guard let id = raw["Id"] as? String, let name = raw["Name"] as? String else { throw EmbyError.invalidResponse }
        _ = try EmbyConnection.id(id)
        let kind = (raw["Type"] as? String ?? "Movie").lowercased()
        let user = raw["UserData"] as? [String: Any] ?? [:]
        let played = user["Played"] as? Bool ?? false
        let duration = Self.seconds(raw["RunTimeTicks"])
        let position = Self.seconds(user["PlaybackPositionTicks"])
        guard let runtime = Int(exactly: (duration / 60).rounded(.towardZero)) else { throw EmbyError.invalidResponse }
        let chapters = raw["Chapters"] as? [[String: Any]] ?? []

        var value: [String: Any] = [
            "contentId": id,
            "title": name,
            "type": kind == "boxset" ? "collection" : kind,
            "status": "available",
            "runtime": runtime,
            "durationSeconds": duration,
            "positionSeconds": position,
            "userState": [
                "played": played,
                "isFavorite": user["IsFavorite"] as? Bool ?? false,
                "inWatchlist": watchlist.contains(id),
            ],
            "userData": [
                "played": played,
                "isInProgress": position > 0,
                "positionSeconds": position,
                "durationSeconds": duration,
            ],
            "versions": try (raw["MediaSources"] as? [[String: Any]] ?? []).map { try version($0, chapters: chapters) },
        ]
        for (source, target) in Self.copiedItemFields { value[target] = raw[source] }
        value["cast"] = cast(raw["People"] as? [[String: Any]] ?? [])
        let poster = image(raw, kind: "Primary")
        value["posterUrl"] = poster
        value["stillUrl"] = poster
        value["backdropUrl"] = image(raw, kind: "Backdrop")
        value["logoUrl"] = image(raw, kind: "Logo")
        value["airDate"] = raw["PremiereDate"]
        value["progressUpdatedAt"] = user["LastPlayedDate"]
        value["studios"] = (raw["Studios"] as? [[String: Any]])?.compactMap { $0["Name"] as? String }

        let providers = Dictionary(
            (raw["ProviderIds"] as? [String: String] ?? [:]).map { ($0.key.lowercased(), $0.value) }
        ) { _, last in last }
        value["imdbId"] = providers["imdb"]
        value["tmdbId"] = providers["tmdb"]
        value["tvdbId"] = providers["tvdb"]

        switch kind {
        case "season":
            let seasonNumber = raw["IndexNumber"] as? Int
            value["seasonNumber"] = seasonNumber ?? 0
            value["episodeCount"] = raw["RecursiveItemCount"] as? Int ?? raw["ChildCount"] as? Int ?? 0
            value["isSpecials"] = seasonNumber == 0
            if let seasonNumber, seasonNumber >= 0 {
                value["title"] = seasonNumber == 0 ? String(localized: "Specials") : String(localized: "Season \(String(seasonNumber))")
            }
        case "episode":
            value["seasonNumber"] = raw["ParentIndexNumber"] as? Int ?? 0
            value["episodeNumber"] = raw["IndexNumber"] as? Int ?? 0
            value["files"] = value["versions"]
        default:
            break
        }
        return value
    }

    /// The actors among an item's people, with their photos.
    private func cast(_ people: [[String: Any]]) -> [[String: Any]] {
        people.filter { $0["Type"] as? String == "Actor" }.compactMap { person in
            guard let name = person["Name"] as? String else { return nil }
            var member: [String: Any] = ["name": name]
            member["personId"] = person["Id"]
            member["character"] = person["Role"]
            if let id = person["Id"] as? String, let tag = person["PrimaryImageTag"] as? String {
                member["photoUrl"] = try? EmbyConnection.url(
                    serverURL: connection.serverURL,
                    path: "/Items/\(EmbyConnection.id(id))/Images/Primary",
                    query: ["tag": tag, "maxWidth": "300"]
                ).absoluteString
            }
            return member
        }
    }

    // MARK: - Versions and tracks

    /// One media source as a file version, with its tracks and the item's
    /// chapters.
    func version(_ raw: [String: Any], chapters: [[String: Any]] = []) throws -> [String: Any] {
        guard let id = raw["Id"] as? String else { throw EmbyError.invalidResponse }
        let streams = raw["MediaStreams"] as? [[String: Any]] ?? []
        let videos = streams.filter { $0["Type"] as? String == "Video" }
        let audios = streams.filter { $0["Type"] as? String == "Audio" }
        let subtitles = streams.filter { $0["Type"] as? String == "Subtitle" }
        let video = videos.first ?? [:]

        var value: [String: Any] = [
            "fileId": Self.numberID(id),
            "duration": Self.seconds(raw["RunTimeTicks"]),
            // Audio tracks are numbered in order; subtitle and video tracks
            // keep Emby's stream index.
            "audioTracks": audios.enumerated().map { ordinal, stream in track(stream, index: ordinal) },
            "subtitleTracks": subtitles.map { track($0, index: $0["Index"] as? Int ?? -1) },
            "videoTracks": videos.map { stream in
                track(stream, index: stream["Index"] as? Int ?? 0).merging(Self.dynamicRange(stream)) { current, _ in current }
            },
            "chapters": chapters.enumerated().map { index, chapter in
                [
                    "index": index,
                    "startSeconds": Self.seconds(chapter["StartPositionTicks"]),
                    "title": chapter["Name"] as? String ?? String(localized: "Chapter \(index + 1)"),
                ]
            },
        ]
        value["fileName"] = raw["Name"]
        value["container"] = raw["Container"]
        value["fileSize"] = raw["Size"]
        value["bitrate"] = raw["Bitrate"]
        value["codecVideo"] = video["Codec"]
        value["codecAudio"] = audios.first?["Codec"]
        if let height = video["Height"] as? Int {
            value["resolution"] = "\(Self.resolutionLabel(width: video["Width"] as? Int ?? 0, height: height))p"
        }
        value["hdr"] = (video["VideoRange"] as? String ?? "SDR") != "SDR"
        if let defaultIndex = raw["DefaultAudioStreamIndex"] as? Int {
            value["effectiveAudioTrackIndex"] = audios.firstIndex { $0["Index"] as? Int == defaultIndex }
        }
        return value
    }

    /// The usual name for a frame size, allowing for cropped widths and
    /// heights; anything smaller than 720p keeps its own height.
    private static func resolutionLabel(width: Int, height: Int) -> Int {
        if width >= 3800 || height >= 2100 { return 2160 }
        if width >= 1900 || height >= 1050 { return 1080 }
        if width >= 1260 || height >= 700 { return 720 }
        return height
    }

    /// Stream fields copied across as they are, Emby name > Vivid name.
    private static let copiedTrackFields = [
        "Codec": "codec", "Language": "language", "DisplayTitle": "title", "Title": "embeddedTitle",
        "IsDefault": "default", "IsForced": "forced", "IsHearingImpaired": "hearingImpaired",
        "IsExternal": "external", "Channels": "channels", "ChannelLayout": "layout",
        "SampleRate": "sampleRate", "BitRate": "bitrate", "Width": "width", "Height": "height",
    ]

    func track(_ raw: [String: Any], index: Int) -> [String: Any] {
        var value: [String: Any] = ["index": index]
        for (source, target) in Self.copiedTrackFields { value[target] = raw[source] }
        return value
    }

    /// A video stream's dynamic range for the player and detail labels, in the
    /// words Silo and Jellyfin use (see `PlayerStreamBadges`).
    ///
    /// `ExtendedVideoType` is DolbyVision, Hdr10, Hdr10Plus, HyperLogGamma or
    /// None; servers that don't send it only have the display text in
    /// `VideoRange` ("Dolby Vision", "HDR 10", "SDR"). `ExtendedVideoSubtype`
    /// (spelt `ExtendedVideoSubType` in Emby's API reference) names Dolby
    /// Vision as `DoviProfile` plus the profile and the base-layer
    /// compatibility ID, always two digits ("DoviProfile02" to
    /// "DoviProfile92"), so "DoviProfile81" is profile 8 with ID 1. `videoRange`
    /// and `dolbyVision` stay empty because the phone's Dolby Vision fact and
    /// the Apple TV Continue Watching overlays (`TVFocusMarquee`) read them;
    /// other cards use `OverlaySummary`.
    static func dynamicRange(_ raw: [String: Any]) -> [String: Any] {
        var value: [String: Any] = [:]
        value["videoRangeType"] = rangeType(
            extended: raw["ExtendedVideoType"] as? String ?? "",
            display: raw["VideoRange"] as? String ?? ""
        )
        let subtype = raw["ExtendedVideoSubtype"] as? String ?? raw["ExtendedVideoSubType"] as? String ?? ""
        let digits = subtype.hasPrefix("DoviProfile") ? subtype.dropFirst("DoviProfile".count) : ""
        if digits.count == 2,
           let profile = digits.first?.wholeNumberValue,
           let compatibility = digits.last?.wholeNumberValue {
            value["dvProfile"] = profile
            value["dvBlCompatId"] = compatibility
        }
        return value
    }

    private static func rangeType(extended: String, display: String) -> String? {
        switch extended.lowercased() {
        case "dolbyvision": return "DOVI"
        case "hdr10plus": return "HDR10Plus"
        case "hdr10": return "HDR10"
        case "hyperloggamma": return "HLG"
        default: break
        }
        let range = display.lowercased().filter { !$0.isWhitespace }
        if range.contains("dolbyvision") || range.contains("dovi") { return "DOVI" }
        if range.contains("hdr10+") || range.contains("hdr10plus") { return "HDR10Plus" }
        if range == "hdr10" { return "HDR10" }
        if range == "hlg" { return "HLG" }
        return nil
    }

    // MARK: - Fetching

    func rawItem(_ id: String) async throws -> [String: Any] {
        try await connection.object("GET", "/Users/\(userID)/Items/\(EmbyConnection.id(id))", query: ["Fields": Self.fields])
    }

    /// A page of items as a catalogue response. Without a `path` it searches
    /// the user's whole library.
    func items(_ path: String? = nil, query: [String: String] = [:]) async throws -> [String: Any] {
        var defaults = ["UserId": userID, "Fields": Self.fields, "EnableUserData": "true"]
        if path == nil { defaults["Recursive"] = "true" }
        let merged = defaults.merging(query) { _, new in new }
        let raw = try await connection.object("GET", path ?? "/Users/\(userID)/Items", query: merged)
        let converted = try convert(raw["Items"] as? [[String: Any]] ?? [])
        let total = raw["TotalRecordCount"] as? Int ?? converted.count
        let start = Int(merged["StartIndex"] ?? "0") ?? 0
        return ["items": converted, "total": total, "totalExact": true, "hasMore": start + converted.count < total]
    }

    func libraryViews() async throws -> [String: Any] {
        let result = try await connection.object("GET", "/Users/\(userID)/Views")
        await EmbyServerDirectory.shared.rememberLibraries(result["Items"] as? [[String: Any]] ?? [], connection: connection)
        try await connection.validate()
        return result
    }

    /// The Emby ID of the library Vivid numbers `number`.
    func libraryID(_ number: String) async throws -> String {
        if let cached = await EmbyServerDirectory.shared.libraryID(number, connection: connection) {
            try await connection.validate()
            return try EmbyConnection.id(cached)
        }
        let views = try await libraryViews()
        let ids = (views["Items"] as? [[String: Any]] ?? []).compactMap { $0["Id"] as? String }
        guard let id = ids.first(where: { String(Self.numberID($0)) == number }) else { throw EmbyError.invalidResponse }
        return try EmbyConnection.id(id)
    }

    func seasonRows(_ rows: [[String: Any]]) throws -> [[String: Any]] {
        try convert(rows.filter { $0["Type"] as? String == "Season" })
    }

    nonisolated static func isVersion(_ version: String, atLeast minimum: [Int]) -> Bool {
        let actual = version.split(separator: ".").map { Int($0) ?? 0 }
        for index in minimum.indices {
            let value = actual.indices.contains(index) ? actual[index] : 0
            if value != minimum[index] { return value > minimum[index] }
        }
        return true
    }

    /// The server's version, cached per account and user for ten minutes.
    func serverVersion() async throws -> String {
        if let cached = await EmbyServerDirectory.shared.version(connection: connection) { return cached }
        let system = try await connection.object("GET", "/System/Info/Public")
        let version = system["Version"] as? String ?? ""
        await EmbyServerDirectory.shared.rememberVersion(version, connection: connection)
        return version
    }

    // MARK: - Local storage

    /// Watchlist and track choices are kept on the device, per server and user.
    var storagePrefix: String {
        "vivid.emby." + (connection.identity?.account.serverId ?? connection.serverURL) + "." + userID
    }

    var watchlistIDs: [String] {
        UserDefaults.standard.stringArray(forKey: storagePrefix + ".watchlist") ?? []
    }

    func trackPreference(_ kind: String, id: String) -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: storagePrefix + "." + kind + "." + id) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
