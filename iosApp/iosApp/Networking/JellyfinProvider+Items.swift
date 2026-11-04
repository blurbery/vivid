import CryptoKit
import Foundation

/// Turns Jellyfin's API into the Silo-shaped JSON Vivid's models decode. The
/// shared HTTP client hands a Jellyfin account's `/api/v1` requests to
/// `route` (in `JellyfinProvider+Routes.swift`); this file converts items,
/// versions and tracks, reads seasons and episodes, and builds Home.
struct JellyfinAdapter {
    let connection: JellyfinConnection
    var userID: String { connection.userID! }

    static let browseFields = "Overview,Genres,Studios,ProviderIds,DateCreated,SortName,ChildCount,RecursiveItemCount,PrimaryImageAspectRatio"
    static let homeFields = browseFields + ",MediaSources,MediaStreams"
    static let fields = "Overview,Genres,Studios,People,ProviderIds,MediaSources,MediaStreams,Chapters,DateCreated,SortName,Taglines,ChildCount,RecursiveItemCount,PrimaryImageAspectRatio"

    // MARK: - Values

    /// Jellyfin ticks (100 ns) as seconds; anything missing, negative or not
    /// finite reads as 0.
    static func seconds(_ ticks: Any?) -> Double {
        guard let number = ticks as? NSNumber else { return 0 }
        let value = number.doubleValue / 10_000_000
        return value.isFinite ? max(0, value) : 0
    }

    /// The whole-number ID Vivid's models need for a Jellyfin ID: the number
    /// itself when it is one, otherwise 56 bits of its SHA-256.
    static func numberID(_ raw: String) -> Int {
        if let numeric = Int(raw), numeric >= 0 { return numeric }
        return SHA256.hash(data: Data(raw.utf8)).prefix(7).reduce(0) { ($0 << 8) | Int($1) }
    }

    /// One item's watch state as a `ProgressPullItem` row. Jellyfin clears
    /// the position when it marks an item played, so played rows report 0.
    static func progress(_ raw: [String: Any]) -> [String: Any]? {
        guard let id = raw["Id"] as? String, (try? JellyfinConnection.id(id)) != nil else { return nil }
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
        guard let imageID, let tag, (try? JellyfinConnection.id(imageID)) != nil else { return nil }
        let query = ["tag": tag, "maxWidth": kind == "Backdrop" ? "1920" : "780", "quality": "90"]
        return try? JellyfinConnection.url(serverURL: connection.serverURL, path: "/Items/\(imageID)/Images/\(kind)", query: query).absoluteString
    }

    /// The poster: an episode or season shows its series' poster (tagged
    /// when Jellyfin sends the tag), anything else its own.
    func poster(_ raw: [String: Any]) -> String? {
        guard ["Episode", "Season"].contains(raw["Type"] as? String ?? ""),
              let seriesID = raw["SeriesId"] as? String,
              (try? JellyfinConnection.id(seriesID)) != nil
        else { return image(raw, kind: "Primary") }
        var query = ["maxWidth": "780", "quality": "90"]
        if let tag = raw["SeriesPrimaryImageTag"] as? String, !tag.isEmpty { query["tag"] = tag }
        return try? JellyfinConnection.url(serverURL: connection.serverURL, path: "/Items/\(seriesID)/Images/Primary", query: query).absoluteString
    }

    private func personPhoto(id: String, tag: String) -> String? {
        try? JellyfinConnection.url(
            serverURL: connection.serverURL,
            path: "/Items/\(JellyfinConnection.id(id))/Images/Primary",
            query: ["tag": tag, "maxWidth": "300"]
        ).absoluteString
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

    /// Fields copied across as they are, Jellyfin name > Vivid name.
    private static let copiedItemFields = [
        "ProductionYear": "year", "Overview": "overview", "OfficialRating": "contentRating",
        "Genres": "genres", "CommunityRating": "ratingTmdb", "CriticRating": "ratingRtCritic",
        "PremiereDate": "releaseDate", "DateCreated": "addedAt", "SeriesId": "seriesId",
        "SeriesName": "seriesTitle", "ParentIndexNumber": "seasonNumber", "IndexNumber": "episodeNumber",
        "ChildCount": "episodeCount", "Status": "showStatus", "SortName": "sortTitle",
    ]

    func item(_ raw: [String: Any], watchlist: Set<String>) throws -> [String: Any] {
        guard let id = raw["Id"] as? String, let name = raw["Name"] as? String else { throw JellyfinError.invalidResponse }
        _ = try JellyfinConnection.id(id)
        let kind = (raw["Type"] as? String ?? "Movie").lowercased()
        let user = raw["UserData"] as? [String: Any] ?? [:]
        let played = user["Played"] as? Bool ?? false
        let duration = Self.seconds(raw["RunTimeTicks"])
        let position = Self.seconds(user["PlaybackPositionTicks"])
        guard let runtime = Int(exactly: (duration / 60).rounded(.towardZero)) else { throw JellyfinError.invalidResponse }
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
        let people = raw["People"] as? [[String: Any]] ?? []
        value["cast"] = cast(people)
        value["crew"] = crew(people)
        value["posterUrl"] = poster(raw)
        value["stillUrl"] = image(raw, kind: "Primary")
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
            let count = raw["RecursiveItemCount"] as? Int ?? raw["ChildCount"] as? Int ?? 0
            value["seasonNumber"] = seasonNumber ?? 0
            value["episodeCount"] = count
            var state: [String: Any] = ["played": played]
            if let unplayed = user["UnplayedItemCount"] as? Int {
                state["unplayedCount"] = unplayed
                state["watchedCount"] = max(0, count - unplayed)
            }
            value["userData"] = state
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

    /// The actors among an item's people, with route IDs and photos.
    private func cast(_ people: [[String: Any]]) -> [[String: Any]] {
        people.filter { $0["Type"] as? String == "Actor" }.compactMap { person in
            guard let name = person["Name"] as? String else { return nil }
            var member: [String: Any] = ["name": name]
            if let id = person["Id"] as? String { member["personId"] = rememberPerson(id) }
            member["character"] = person["Role"]
            if let id = person["Id"] as? String, let tag = person["PrimaryImageTag"] as? String {
                member["photoUrl"] = personPhoto(id: id, tag: tag)
            }
            return member
        }
    }

    /// Everyone else, with their role (or type) as the job.
    private func crew(_ people: [[String: Any]]) -> [[String: Any]] {
        people.filter { $0["Type"] as? String != "Actor" }.compactMap { person in
            guard let name = person["Name"] as? String else { return nil }
            var member: [String: Any] = ["name": name]
            member["job"] = person["Role"] ?? person["Type"]
            if let id = person["Id"] as? String {
                member["personId"] = rememberPerson(id)
                if let tag = person["PrimaryImageTag"] as? String { member["photoUrl"] = personPhoto(id: id, tag: tag) }
            }
            return member
        }
    }

    // MARK: - Versions and tracks

    /// One media source as a file version, with its tracks and the item's
    /// chapters.
    func version(_ raw: [String: Any], chapters: [[String: Any]] = []) throws -> [String: Any] {
        guard let id = raw["Id"] as? String else { throw JellyfinError.invalidResponse }
        let streams = raw["MediaStreams"] as? [[String: Any]] ?? []
        let videos = streams.filter { $0["Type"] as? String == "Video" }
        let audios = streams.filter { $0["Type"] as? String == "Audio" }
        let subtitles = streams.filter { $0["Type"] as? String == "Subtitle" }
        let video = videos.first ?? [:]

        var value: [String: Any] = [
            "fileId": Self.numberID(id),
            "duration": Self.seconds(raw["RunTimeTicks"]),
            // Audio tracks are numbered in order; subtitle and video tracks
            // keep Jellyfin's stream index.
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

    /// Stream fields copied across as they are, Jellyfin name > Vivid name.
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

    /// A video stream's dynamic range for the player and detail labels (see
    /// `PlayerStreamBadges`). Jellyfin's `VideoRangeType` is the vocabulary
    /// Silo shares (SDR, HDR10, HDR10Plus, HLG, DOVI, DOVIWithHDR10,
    /// DOVIWithHDR10Plus, DOVIWithSDR, DOVIWithHLG, DOVIWithEL,
    /// DOVIWithELHDR10Plus, DOVIInvalid, Unknown), `DvProfile` is the Dolby
    /// Vision profile and `DvBlSignalCompatibilityId` its base-layer
    /// compatibility ID (1 for HDR10, 2 for SDR, 4 for HLG, 6 for Blu-ray).
    /// Values of the wrong type are skipped so they can't break decoding.
    /// `videoRange` and `dolbyVision` stay empty because the phone's Dolby
    /// Vision fact and the Apple TV Continue Watching overlays
    /// (`TVFocusMarquee`) read them; other cards use `OverlaySummary`.
    static func dynamicRange(_ raw: [String: Any]) -> [String: Any] {
        var value: [String: Any] = [:]
        value["videoRangeType"] = raw["VideoRangeType"] as? String
        value["dvProfile"] = raw["DvProfile"] as? Int
        value["dvBlCompatId"] = raw["DvBlSignalCompatibilityId"] as? Int
        value["hdr10Plus"] = raw["Hdr10PlusPresentFlag"] as? Bool
        return value
    }

    // MARK: - Fetching

    func rawItem(_ id: String) async throws -> [String: Any] {
        try await connection.object("GET", "/Items/\(JellyfinConnection.id(id))", query: ["Fields": Self.fields, "EnableUserData": "true"])
    }

    /// A page of items as a catalogue response. Without a `path` it searches
    /// the user's whole library.
    func items(_ path: String? = nil, query: [String: String] = [:]) async throws -> [String: Any] {
        var defaults = ["UserId": userID, "Fields": Self.fields, "EnableUserData": "true"]
        if path == nil { defaults["Recursive"] = "true" }
        let merged = defaults.merging(query) { _, new in new }
        let raw = try await connection.object("GET", path ?? "/Items", query: merged)
        let converted = try convert(raw["Items"] as? [[String: Any]] ?? [])
        let total = raw["TotalRecordCount"] as? Int ?? converted.count
        let start = Int(merged["StartIndex"] ?? "0") ?? 0
        return ["items": converted, "total": total, "totalExact": true, "hasMore": start + converted.count < total]
    }

    func libraryViews() async throws -> [String: Any] {
        let result = try await connection.object("GET", "/UserViews")
        await JellyfinLibraryDirectory.shared.remember(result["Items"] as? [[String: Any]] ?? [], connection: connection)
        try await connection.validate()
        return result
    }

    /// The Jellyfin ID of the library Vivid numbers `number`.
    func libraryID(_ number: String) async throws -> String {
        try await connection.validate()
        if let cached = await JellyfinLibraryDirectory.shared.nativeID(number, connection: connection) {
            try await connection.validate()
            return try JellyfinConnection.id(cached)
        }
        let views = try await libraryViews()
        let ids = (views["Items"] as? [[String: Any]] ?? []).compactMap { $0["Id"] as? String }
        guard let id = ids.first(where: { String(Self.numberID($0)) == number }) else { throw JellyfinError.invalidResponse }
        return try JellyfinConnection.id(id)
    }

    // MARK: - Seasons and episodes

    /// A season's episodes. With a resume episode (the version the season's
    /// resume point is in), that episode's row takes the place of the one
    /// with its number, so the list resumes the right version.
    func episodes(seriesID: String, seasonNumber: String, resumeEpisodeID: String?) async throws -> [String: Any] {
        async let page = connection.object("GET", "/Shows/\(JellyfinConnection.id(seriesID))/Episodes", query: [
            "Season": seasonNumber, "UserId": userID, "EnableUserData": "true",
            "Fields": Self.fields, "Recursive": "false", "IncludeItemTypes": "Episode",
            "SortBy": "ParentIndexNumber,IndexNumber", "SortOrder": "Ascending",
        ])
        async let resume = resumeItem(resumeEpisodeID)
        var rows = try await page["Items"] as? [[String: Any]] ?? []
        if let selected = try await resume {
            guard selected["Id"] as? String == resumeEpisodeID,
                  selected["Type"] as? String == "Episode",
                  selected["SeriesId"] as? String == seriesID,
                  selected["ParentIndexNumber"] as? Int == Int(seasonNumber),
                  let episodeNumber = selected["IndexNumber"] as? Int
            else { throw JellyfinError.invalidResponse }
            if let index = rows.firstIndex(where: {
                $0["Id"] as? String == resumeEpisodeID || $0["IndexNumber"] as? Int == episodeNumber
            }) {
                rows[index] = selected
            } else {
                rows.append(selected)
            }
        }
        try await connection.validate()
        return ["episodes": try convert(rows)]
    }

    /// A deleted resume version mustn't hide the rest of the season, so a
    /// 404 reads as none. Sign-in, cancellation and other failures still throw.
    private func resumeItem(_ id: String?) async throws -> [String: Any]? {
        guard let id else { return nil }
        do {
            return try await rawItem(id)
        } catch HTTPError.http(statusCode: 404, body: _) {
            try await connection.validate()
            return nil
        }
    }

    func seasonRows(_ rows: [[String: Any]], episodes: [[String: Any]]? = nil) throws -> [[String: Any]] {
        let seasons = rows.filter { $0["Type"] as? String == "Season" }
        let converted = try convert(seasons)
        guard let episodes else { return converted }
        return zip(seasons, converted).map { raw, season in
            Self.countingGroupedVersions(season, seasonNumber: raw["IndexNumber"] as? Int, episodes: episodes)
        }
    }

    /// Jellyfin 12.2 can count every version of an episode in a season's
    /// RecursiveItemCount and UnplayedItemCount, so 8 episodes with two
    /// versions each report 16. The episode list groups versions into one
    /// row, so these rows give matching counts. Nil when the list can't be
    /// read, which leaves the server's counts in place.
    func groupedEpisodeRows(seriesID: String, seasonNumber: Int? = nil) async -> [[String: Any]]? {
        var query = [
            "UserId": userID, "EnableUserData": "true", "EnableImages": "false", "Fields": "MediaSourceCount",
            "Recursive": "false", "IncludeItemTypes": "Episode",
        ]
        if let seasonNumber { query["Season"] = String(seasonNumber) }
        guard let id = try? JellyfinConnection.id(seriesID),
              let page = try? await connection.object("GET", "/Shows/\(id)/Episodes", query: query)
        else { return nil }
        return page["Items"] as? [[String: Any]]
    }

    /// Jellyfin groups versions in a season's ChildCount only when
    /// RecursiveItemCount isn't requested with it, so a lower ChildCount
    /// there means a season is counting versions.
    nonisolated static func countsVersions(_ seasons: [[String: Any]], grouped: [[String: Any]]) -> Bool {
        let childCounts = Dictionary(grouped.compactMap { row in
            (row["Id"] as? String).map { ($0, row["ChildCount"] as? Int) }
        }) { first, _ in first }
        return seasons.contains { season in
            guard let id = season["Id"] as? String,
                  let total = season["RecursiveItemCount"] as? Int,
                  let child = childCounts[id] ?? nil
            else { return false }
            return child < total
        }
    }

    /// Recounts a season from its grouped episode rows when any of them has
    /// more than one version; seasons without versions keep the server's
    /// counts. Rows match by season number, because a season merged across
    /// libraries has a different ID in each.
    nonisolated static func countingGroupedVersions(_ season: [String: Any], seasonNumber: Int?, episodes: [[String: Any]]) -> [String: Any] {
        guard let seasonNumber else { return season }
        let rows = episodes.filter {
            $0["ParentIndexNumber"] as? Int == seasonNumber && $0["LocationType"] as? String != "Virtual"
        }
        guard rows.contains(where: { $0["MediaSourceCount"] as? Int ?? 1 > 1 }) else { return season }
        let watched = rows.filter { ($0["UserData"] as? [String: Any])?["Played"] as? Bool == true }.count
        var value = season
        value["episodeCount"] = rows.count
        value["userData"] = ["played": watched == rows.count, "watchedCount": watched, "unplayedCount": rows.count - watched]
        return value
    }

    // MARK: - Home

    nonisolated static func excludesHomeRow(id: String, type: String, title: String) -> Bool {
        let excluded: Set<String> = ["featured", "spotlight", "recentlyadded", "recentlyadd"]
        return [id, type, title].contains { excluded.contains($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
    }

    /// Continue Watching, Next Up, then a Latest row for each movie, series
    /// or mixed library the user hasn't excluded (only the given library's,
    /// for a library page). Independent requests run together; Latest rows
    /// load two at a time, in the server's order.
    func home(library: String? = nil) async throws -> [String: Any] {
        let parent: String?
        if let library { parent = try await libraryID(library) } else { parent = nil }
        var scope = ["Limit": "20", "MediaTypes": "Video", "Fields": Self.homeFields]
        if let parent { scope["ParentId"] = parent }

        async let viewsRequest = libraryViews()
        async let userRequest = connection.object("GET", "/Users/\(userID)")
        async let resumeRequest = items("/UserItems/Resume", query: scope)
        async let nextRequest = items("/Shows/NextUp", query: scope.merging(["EnableResumable": "false"]) { _, new in new })
        let (views, user) = try await (viewsRequest, userRequest)

        let excluded = Set((user["Configuration"] as? [String: Any])?["LatestItemsExcludes"] as? [String] ?? [])
        let libraries = (views["Items"] as? [[String: Any]] ?? []).compactMap { view -> (id: String, name: String)? in
            guard let id = view["Id"] as? String,
                  let name = view["Name"] as? String,
                  parent == nil || parent == id,
                  !excluded.contains(id),
                  ["movies", "tvshows", "mixed", ""].contains(view["CollectionType"] as? String ?? "")
            else { return nil }
            return (id, name)
        }

        var latestSections: [[String: Any]] = []
        for offset in stride(from: 0, to: libraries.count, by: 2) {
            try Task.checkCancellation()
            async let first = latestHomeSection(id: libraries[offset].id, name: libraries[offset].name)
            if offset + 1 < libraries.count {
                async let second = latestHomeSection(id: libraries[offset + 1].id, name: libraries[offset + 1].name)
                let pair = try await (first, second)
                latestSections += [pair.0, pair.1]
            } else {
                latestSections.append(try await first)
            }
        }

        let (resume, next) = try await (resumeRequest, nextRequest)
        try await connection.validate()
        let playback = [
            section("continue_watching", String(localized: "Continue Watching"), resume),
            section("next_up", String(localized: "Next Up"), next),
        ]
        return ["sections": playback + latestSections]
    }

    private func latestHomeSection(id: String, name: String) async throws -> [String: Any] {
        let latest = try await connection.request(
            "GET", "/Items/Latest",
            query: ["ParentId": id, "Limit": "20", "Fields": Self.homeFields, "EnableUserData": "true"]
        )
        let rows = try convert(latest as? [[String: Any]] ?? [])
        let title = String(localized: "Latest \(name)", comment: "Home row of a library's newest items; the library name comes from the server")
        return section("latestmedia_" + id, title, ["items": rows, "total": rows.count])
    }

    /// A Home row. On Continue Watching and Next Up, an episode card shows
    /// the series background (the episode's own backdrop, if it has one)
    /// with its still kept as `backdropUrl`; other places that use these rows
    /// keep the episode still. Continue Watching removal is Silo only, so
    /// the rows follow the server.
    func section(_ id: String, _ title: String, _ catalog: [String: Any], featured: Bool = false) -> [String: Any] {
        let playbackRow = ["continue_watching", "next_up"].contains(id)
        let rows = (catalog["items"] as? [[String: Any]] ?? []).map { item in
            var card = item
            if playbackRow,
               item["type"] as? String == "episode",
               let still = item["stillUrl"] as? String, !still.isEmpty {
                card["seriesBackdropUrl"] = item["backdropUrl"]
                card["backdropUrl"] = still
            }
            return card
        }
        return ["id": id, "sectionType": id, "title": title, "featured": featured, "items": rows, "totalCount": rows.count]
    }

    // MARK: - Local storage

    /// People, the watchlist and track choices are kept on the device, per
    /// server and user.
    var storagePrefix: String {
        "vivid.jellyfin." + (connection.identity?.account.serverId ?? connection.serverURL) + "." + userID
    }

    /// Vivid's person routes use numeric IDs, so Jellyfin's own ID is kept
    /// for each, letting navigation and filmographies round-trip.
    private func rememberPerson(_ nativeID: String) -> String {
        let routeID = String(Self.numberID(nativeID))
        JellyfinPeopleStore.shared.remember(routeID: routeID, nativeID: nativeID, partition: storagePrefix)
        return routeID
    }

    func nativePersonID(_ routeID: String) throws -> String {
        guard let id = JellyfinPeopleStore.shared.nativeID(routeID: routeID, partition: storagePrefix) else {
            throw JellyfinError.invalidResponse
        }
        return try JellyfinConnection.id(id)
    }

    var watchlistIDs: [String] {
        UserDefaults.standard.stringArray(forKey: storagePrefix + ".watchlist") ?? []
    }

    func trackPreference(_ kind: String, id: String) -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: storagePrefix + "." + kind + "." + id) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
