import Foundation

/// Answers a Jellyfin account's `/api/v1` requests (the Silo routes the app
/// is written against) from Jellyfin's own API, or from this device for the
/// things Jellyfin doesn't keep (the watchlist, track choices and Vivid
/// settings).
extension JellyfinAdapter {
    func route(method: String, path: String, query: [String: String], body: Any?) async throws -> Any {
        let route = JellyfinRoute(path)
        let payload = body as? [String: Any] ?? [:]

        switch path {
        case "/api/v1/auth/logout":
            return try await connection.request("POST", "/Sessions/Logout")
        case "/api/v1/auth/me":
            let user = try await connection.object("GET", "/Users/\(userID)")
            return ["id": Self.numberID(userID), "username": user["Name"] as? String ?? "Jellyfin", "role": "user", "email": ""]
        case "/api/v1/profiles" where method == "GET":
            let user = try await connection.object("GET", "/Users/\(userID)")
            let profile: [String: Any] = [
                "id": userID, "name": user["Name"] as? String ?? "Jellyfin",
                "hasPin": false, "isChild": false, "isPrimary": true,
            ]
            return ["profiles": [profile]]
        case "/api/v1/home/sections":
            return try await home()
        default:
            break
        }
        if let library = route.capture("library/*/sections") {
            return try await home(library: library)
        }
        switch path {
        case "/api/v1/user/libraries", "/api/v1/libraries":
            return try await libraries()
        case "/api/v1/catalog":
            return try await catalog(query)
        case "/api/v1/favorites", "/api/v1/history", "/api/v1/watchlist":
            return try await catalog(query.merging(["source": route.parts[2]]) { _, new in new })
        default:
            break
        }
        if let id = route.capture("catalog/items/*") {
            return try await catalogItem(id)
        }
        if let id = route.capture("people/*"), method == "GET" {
            return try await person(id)
        }
        if let id = route.capture("watch/*") {
            return try await watchWithPreferences(await rawItem(id))
        }
        if route.parts.count == 4, ["audio-prefs", "subtitle-prefs"].contains(route.parts[2]) {
            return try await trackPreferenceRoute(kind: route.parts[2], id: route.parts[3], method: method, payload: payload)
        }
        if let series = route.capture("catalog/series/*/seasons") {
            return try await seasons(series)
        }
        if route.parts.count == 8, route.parts[2] == "catalog", route.parts[3] == "series", route.parts[7] == "episodes" {
            return try await episodes(seriesID: route.parts[4], seasonNumber: route.parts[6], resumeEpisodeID: query["resume_episode_id"])
        }
        if route.parts.count == 4, ["favorites", "watched"].contains(route.parts[2]) {
            return try await userDataRoute(route.parts[2], id: route.parts[3], method: method)
        }
        if let id = route.capture("watchlist/*") {
            return try watchlistRoute(id: id, method: method)
        }
        if path == "/api/v1/collections", method == "GET" {
            let raw = try await connection.object("GET", "/Items", query: [
                "Recursive": "true", "IncludeItemTypes": "BoxSet", "Fields": "Overview,ChildCount,RecursiveItemCount",
                "SortBy": "SortName", "SortOrder": "Ascending",
            ])
            return ["collections": (raw["Items"] as? [[String: Any]] ?? []).compactMap(collection), "groups": []]
        }
        if let library = route.capture("library/*/collections") {
            let raw = try await connection.object("GET", "/Items", query: [
                "Recursive": "true", "IncludeItemTypes": "BoxSet", "Fields": "ChildCount,RecursiveItemCount",
                "ParentId": try await libraryID(library),
            ])
            return ["collections": (raw["Items"] as? [[String: Any]] ?? []).compactMap(collection), "sections": []]
        }
        if let id = route.capture("collections/*/items"), method == "GET" {
            return try await items(query: Self.collectionQuery(
                id: JellyfinConnection.id(id), offset: query["offset"] ?? "0", limit: query["limit"] ?? "200"
            ))
        }
        if route.parts.count >= 3, route.parts[2] == "downloads" {
            return try await JellyfinDownloads.shared.route(connection: connection, method: method, path: route.parts, body: payload)
        }
        if path == "/api/v1/sync/progress" {
            return try await syncProgress(payload)
        }
        // Jellyfin has no progress change feed, so this answers with the
        // current watch state of the items named in `ids` (the device's downloads).
        if path == "/api/v1/progress", method == "GET", let list = query["ids"] {
            return try await progress(ids: list)
        }
        if path.hasPrefix("/api/v1/settings/values/") || path == "/api/v1/settings/contract/capabilities" {
            return try await JellyfinLocalPreferences.shared.route(connection: connection, method: method, path: route.parts, query: query, body: payload)
        }
        if path == "/api/v1/settings/effective" {
            return ["settings": effectiveLegacySettings(keys: query["keys"] ?? "")]
        }
        if path == "/api/v1/catalog/filters" {
            var filterQuery = ["UserId": userID, "IncludeItemTypes": "Movie,Series"]
            if let library = query["library_id"] { filterQuery["ParentId"] = try await libraryID(library) }
            return Self.catalogFilterOptions(try await connection.object("GET", "/Items/Filters", query: filterQuery))
        }
        if route.parts.count >= 3, route.parts[2] == "settings" {
            return try legacySettingRoute(route.parts, method: method, payload: payload)
        }
        throw JellyfinError.unsupportedFeature
    }

    // MARK: - Library

    /// The user's movie, series and mixed libraries.
    private func libraries() async throws -> [[String: Any]] {
        let result = try await libraryViews()
        return (result["Items"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["Id"] as? String else { return nil }
            let type = raw["CollectionType"] as? String ?? "mixed"
            guard ["movies", "tvshows", "mixed", ""].contains(type) else { return nil }
            return [
                "id": Self.numberID(id),
                "name": raw["Name"] as? String ?? String(localized: "Library", comment: "Fallback name for a library the server sent without one"),
                "type": type == "tvshows" ? "series" : type == "movies" ? "movie" : "mixed",
            ]
        }
    }

    /// An item's detail. Like the seasons route, a season that counts every
    /// version in its totals is recounted from its grouped episode rows.
    private func catalogItem(_ id: String) async throws -> [String: Any] {
        let raw = try await rawItem(id)
        let value = try item(raw)
        guard raw["Type"] as? String == "Season",
              raw["RecursiveItemCount"] is Int,
              let series = raw["SeriesId"] as? String,
              let number = raw["IndexNumber"] as? Int,
              let grouped = try? await connection.object(
                  "GET", "/Items/\(JellyfinConnection.id(id))",
                  query: ["Fields": "ChildCount", "EnableUserData": "true", "EnableImages": "false"]
              ),
              Self.countsVersions([raw], grouped: [grouped]),
              let episodes = await groupedEpisodeRows(seriesID: series, seasonNumber: number)
        else { return value }
        return Self.countingGroupedVersions(value, seasonNumber: number, episodes: episodes)
    }

    private func person(_ routeID: String) async throws -> [String: Any] {
        let raw = try await rawItem(nativePersonID(routeID))
        var person: [String: Any] = ["id": Self.numberID(routeID), "name": raw["Name"] as? String ?? ""]
        person["bio"] = raw["Overview"]
        person["photoUrl"] = image(raw, kind: "Primary")
        person["birthDate"] = raw["PremiereDate"]
        person["deathDate"] = raw["EndDate"]
        return person
    }

    /// A series' seasons. Only a series whose seasons count versions in
    /// their totals pays for listing every episode to recount them.
    private func seasons(_ rawSeries: String) async throws -> [String: Any] {
        let series = try JellyfinConnection.id(rawSeries)
        let query = [
            "UserId": userID, "Fields": Self.fields, "EnableUserData": "true", "Recursive": "false",
            "IncludeItemTypes": "Season", "SortBy": "SortName", "SortOrder": "Ascending",
        ]
        async let result = connection.object("GET", "/Shows/\(series)/Seasons", query: query)
        async let grouped = try? connection.object(
            "GET", "/Shows/\(series)/Seasons",
            query: query.merging(["Fields": "ChildCount", "EnableImages": "false"]) { _, new in new }
        )
        let rows = try await result["Items"] as? [[String: Any]] ?? []
        let versioned = Self.countsVersions(rows, grouped: await grouped?["Items"] as? [[String: Any]] ?? [])
        return ["seasons": try await seasonRows(rows, episodes: versioned ? groupedEpisodeRows(seriesID: series) : nil)]
    }

    /// Favourites and played state live in Jellyfin. A GET answers 404 when
    /// the item isn't a favourite or played, as Silo does.
    private func userDataRoute(_ kind: String, id: String, method: String) async throws -> Any {
        if method == "GET" {
            let data = try await rawItem(id)["UserData"] as? [String: Any] ?? [:]
            guard data[kind == "watched" ? "Played" : "IsFavorite"] as? Bool == true else {
                throw HTTPError.http(statusCode: 404, body: nil)
            }
            return [String: Any]()
        }
        let list = kind == "favorites" ? "FavoriteItems" : "PlayedItems"
        return try await connection.request(method == "DELETE" ? "DELETE" : "POST", "/User\(list)/\(JellyfinConnection.id(id))")
    }

    // MARK: - Collections

    /// No sort, so Jellyfin lists a collection in its own display order
    /// (release date unless changed on the server), as its web client does.
    nonisolated static func collectionQuery(id: String, offset: String, limit: String) -> [String: String] {
        ["ParentId": id, "Recursive": "false", "CollapseBoxSetItems": "false", "StartIndex": offset, "Limit": limit]
    }

    func collection(_ raw: [String: Any]) -> [String: Any]? {
        guard raw["Type"] as? String == "BoxSet",
              let id = raw["Id"] as? String,
              let name = raw["Name"] as? String
        else { return nil }
        var result: [String: Any] = ["id": id, "name": name, "title": name, "collectionType": "collection", "kind": "regular"]
        result["itemCount"] = raw["ChildCount"] ?? raw["RecursiveItemCount"]
        result["posterUrl"] = image(raw, kind: "Primary")
        return result
    }

    // MARK: - Catalogue

    /// Silo catalogue query keys > Jellyfin query keys, copied when not empty.
    private static let catalogFilterKeys = [
        "search": "SearchTerm", "q": "SearchTerm", "genre": "Genres", "genres": "Genres",
        "year": "Years", "years": "Years", "content_rating": "OfficialRatings", "studio": "StudioIds",
    ]

    private static let catalogSorts = [
        "title": "SortName", "year": "ProductionYear", "release_date": "PremiereDate", "added": "DateCreated",
        "added_at": "DateCreated", "rating": "CommunityRating", "random": "Random", "runtime": "Runtime",
    ]

    nonisolated static func catalogFilterOptions(_ raw: [String: Any]) -> [String: Any] {
        func names(_ value: Any?) -> [String] {
            let values = (value as? [Any] ?? []).compactMap { entry -> String? in
                if let name = entry as? String { return name }
                return (entry as? [String: Any])?["Name"] as? String
            }.filter { !$0.isEmpty }
            return Array(Set(values)).sorted()
        }
        return [
            "genres": names(raw["Genres"]), "contentRatings": names(raw["OfficialRatings"]),
            "studios": [String](), "networks": [String](), "countries": [String](),
        ]
    }

    func catalog(_ input: [String: String]) async throws -> [String: Any] {
        if let collection = input["collection_id"] {
            let query = Self.collectionQuery(
                id: try JellyfinConnection.id(collection), offset: input["offset"] ?? "0", limit: input["limit"] ?? "60"
            )
            return try await items(query: query.merging(["Fields": Self.browseFields]) { _, new in new })
        }
        var query = [
            "Fields": Self.browseFields,
            "StartIndex": input["offset"] ?? "0",
            "Limit": input["limit"] ?? "60",
            "IncludeItemTypes": "Movie,Series",
            "SortBy": "SortName",
            "SortOrder": input["order"] == "desc" ? "Descending" : "Ascending",
            // A server set to group movies or shows into collections would
            // otherwise swap a library's titles for collection cards, which
            // have their own pages.
            "CollapseBoxSetItems": "false",
        ]
        // Search's "video" scope, like any other unmapped type, keeps both
        // movies and series.
        if let type = input["type"], let mapped = ["movie": "Movie", "series": "Series", "episode": "Episode"][type] {
            query["IncludeItemTypes"] = mapped
        }
        for (source, target) in Self.catalogFilterKeys {
            if let value = input[source], !value.isEmpty { query[target] = value }
        }
        if let sort = input["sort"], let mapped = Self.catalogSorts[sort] { query["SortBy"] = mapped }
        if let library = input["library_id"] { query["ParentId"] = try await libraryID(library) }
        if let prefix = input["name_prefix"], !prefix.isEmpty {
            if prefix == "#" { query["NameLessThan"] = "A" } else { query["NameStartsWith"] = prefix }
        }
        if let person = input["person_id"] { query["PersonIds"] = try nativePersonID(person) }
        switch input["jellyfin_watch_status"] {
        case "watched": query["IsPlayed"] = "true"
        case "unwatched": query["IsPlayed"] = "false"
        case "inProgress": query["Filters"] = "IsResumable"
        case "favorited": query["IsFavorite"] = "true"
        default: break
        }
        switch input["source"] {
        case "favorites":
            query["Filters"] = "IsFavorite"
        case "history":
            query["Filters"] = "IsPlayed"
            query["SortBy"] = "DatePlayed"
            query["SortOrder"] = "Descending"
            query["IncludeItemTypes"] = switch input["type"] {
            case "movie": "Movie"
            case "episode": "Episode"
            default: "Movie,Episode"
            }
        case "watchlist":
            let ids = watchlistIDs
            guard !ids.isEmpty else { return ["items": [], "total": 0, "hasMore": false] }
            query["Ids"] = ids.joined(separator: ",")
            if input["type"] == nil { query.removeValue(forKey: "IncludeItemTypes") }
        default:
            break
        }
        return try await items(query: query)
    }

    // MARK: - Watch details

    func watchWithPreferences(_ raw: [String: Any]) async throws -> [String: Any] {
        let preferenceID = raw["SeriesId"] as? String ?? raw["Id"] as? String ?? ""
        return try watch(
            raw,
            preferences: await JellyfinLocalPreferences.shared.playbackValues(connection: connection),
            subtitle: trackPreference("subtitle-prefs", id: preferenceID),
            audio: trackPreference("audio-prefs", id: preferenceID)
        )
    }

    /// An item with the subtitle and audio choices that apply to it: the
    /// title's (or series') own choice first, then the account's playback
    /// settings. An audio language picks the first track in that language.
    func watch(_ raw: [String: Any], preferences: [String: Any], subtitle: [String: Any] = [:], audio: [String: Any] = [:]) throws -> [String: Any] {
        var value = try item(raw)
        value["effectiveSubtitleLanguage"] = subtitle["subtitle_language"] ?? preferences["playback.subtitle_language"]
        value["effectiveSubtitleMode"] = subtitle["subtitle_mode"] ?? preferences["playback.subtitle_mode"]
        value["effectiveShowForcedSubtitles"] = subtitle["show_forced_subtitles"] ?? preferences["playback.show_forced_subtitles"]
        value["effectiveSubtitleTrackSignature"] = subtitle["track_signature"]

        let language = audio["audio_language"] as? String ?? preferences["playback.audio_language"] as? String
        func normalised(_ code: String) -> String {
            Locale(identifier: code).language.languageCode?.identifier(.alpha2) ?? code.lowercased()
        }
        value["versions"] = (value["versions"] as? [[String: Any]] ?? []).map { version in
            var result = version
            let tracks = version["audioTracks"] as? [[String: Any]] ?? []
            if let language, !language.isEmpty, language != "original",
               let selected = tracks.firstIndex(where: { normalised($0["language"] as? String ?? "") == normalised(language) }) {
                result["effectiveAudioTrackIndex"] = selected
                result["effectiveAudioLanguage"] = language
            }
            return result
        }
        return value
    }

    // MARK: - Kept on the device

    private func trackPreferenceRoute(kind: String, id: String, method: String, payload: [String: Any]) async throws -> Any {
        _ = try JellyfinConnection.id(id)
        try await connection.validate()
        let key = storagePrefix + "." + kind + "." + id
        switch method {
        case "GET":
            return trackPreference(kind, id: id)
        case "DELETE":
            UserDefaults.standard.removeObject(forKey: key)
            return [String: Any]()
        case "PUT":
            UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: payload), forKey: key)
            return payload
        default:
            throw JellyfinError.unsupportedFeature
        }
    }

    /// Vivid's own watchlist, kept on the device. A GET answers 404 for an
    /// item not on it.
    private func watchlistRoute(id rawID: String, method: String) throws -> Any {
        let id = try JellyfinConnection.id(rawID)
        var ids = watchlistIDs
        switch method {
        case "GET":
            guard ids.contains(id) else { throw HTTPError.http(statusCode: 404, body: nil) }
        case "DELETE":
            ids.removeAll { $0 == id }
        case "PUT" where !ids.contains(id):
            ids.append(id)
        default:
            break
        }
        UserDefaults.standard.set(ids, forKey: storagePrefix + ".watchlist")
        return [String: Any]()
    }

    private var legacySettingPrefix: String {
        "vivid.jellyfin.setting.\(connection.identity?.account.serverId ?? connection.serverURL).\(userID)."
    }

    /// The older string settings (`/api/v1/settings/{key}`), kept on the
    /// device. Settings Vivid saved for the device take precedence.
    private func effectiveLegacySettings(keys: String) -> [[String: Any]] {
        let prefix = legacySettingPrefix
        return keys.split(separator: ",").compactMap { key in
            let user = UserDefaults.standard.string(forKey: prefix + String(key))
            let device = UserDefaults.standard.string(forKey: prefix + "device." + String(key))
            guard let value = device ?? user else { return nil }
            var setting: [String: Any] = [
                "key": String(key), "effectiveValue": value,
                "source": device == nil ? "user" : "device", "hasDeviceOverride": device != nil,
            ]
            setting["userValue"] = user
            setting["deviceValue"] = device
            return setting
        }
    }

    private func legacySettingRoute(_ parts: [String], method: String, payload: [String: Any]) throws -> Any {
        let key = legacySettingPrefix + parts.dropFirst(3).joined(separator: ".")
        if method == "GET" {
            guard let value = UserDefaults.standard.string(forKey: key) else { throw HTTPError.http(statusCode: 404, body: nil) }
            return ["key": parts.last ?? "", "value": value]
        }
        if method == "DELETE" {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let value = payload["value"] as? String {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            throw JellyfinError.unsupportedFeature
        }
        return [String: Any]()
    }

    // MARK: - Progress

    /// Offline progress, sent as stop reports. Unlike a user data write, a
    /// stop goes through Jellyfin's resume settings and needs no earlier
    /// start; without a `PlaySessionId` it can't end a transcode, and without
    /// a `MediaSourceId` it updates the item itself. A stop isn't safe to
    /// repeat, so a failure part-way returns the items already accepted
    /// rather than failing them all.
    private func syncProgress(_ payload: [String: Any]) async throws -> [String: Any] {
        var results: [[String: Any]] = []
        for item in payload["items"] as? [[String: Any]] ?? [] {
            guard let id = item["media_item_id"] as? String,
                  let position = item["position_seconds"] as? Double ?? item["position"] as? Double
            else { throw JellyfinError.invalidResponse }
            do {
                _ = try await connection.request("POST", "/Sessions/Playing/Stopped", body: [
                    "ItemId": JellyfinConnection.id(id), "PositionTicks": JellyfinPlayback.ticks(position),
                ])
            } catch let error as HTTPError where error.isPermanentRejection {
                // Refused outright, for example an item the server no longer
                // has. Reporting an error lets the queue use up that entry's
                // retries instead of it holding up every entry behind it.
                results.append(["mediaItemId": id, "status": "error"])
                continue
            } catch {
                guard !results.isEmpty else { throw error }
                break
            }
            results.append(["mediaItemId": id, "status": "ok"])
        }
        return ["results": results]
    }

    private func progress(ids list: String) async throws -> [String: Any] {
        let ids = try list.split(separator: ",").map { try JellyfinConnection.id(String($0)) }
        guard !ids.isEmpty else { return ["progress": []] }
        let raw = try await connection.object("GET", "/Items", query: [
            "UserId": userID, "Ids": ids.joined(separator: ","), "Recursive": "true",
            "EnableUserData": "true", "EnableImages": "false",
        ])
        return ["progress": (raw["Items"] as? [[String: Any]] ?? []).compactMap(Self.progress)]
    }
}

/// A `/api/v1/...` path split at `/` (empty pieces dropped), for matching
/// the rest of the path against patterns such as `catalog/items/*`.
private struct JellyfinRoute {
    let parts: [String]

    init(_ path: String) {
        parts = path.split(separator: "/").map(String.init)
    }

    /// The piece standing in for the pattern's `*`, when the path is
    /// `/api/v1/` followed by the pattern. The first two pieces aren't
    /// checked, as before.
    func capture(_ pattern: String) -> String? {
        let expected = pattern.split(separator: "/")
        guard parts.count == expected.count + 2 else { return nil }
        var captured: String?
        for (want, part) in zip(expected, parts.dropFirst(2)) {
            if want == "*" {
                captured = part
            } else if want != part {
                return nil
            }
        }
        return captured
    }
}
