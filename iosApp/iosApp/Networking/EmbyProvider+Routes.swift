import Foundation

/// Answers an Emby account's `/api/v1` requests (the Silo routes the app is
/// written against) from Emby's own API, or from this device for the things
/// Emby doesn't keep (the watchlist, track choices and Vivid settings).
extension EmbyAdapter {
    func route(method: String, path: String, query: [String: String], body: Any?) async throws -> Any {
        let route = EmbyRoute(path)
        let payload = body as? [String: Any] ?? [:]

        switch path {
        case "/api/v1/auth/logout":
            return try await connection.request("POST", "/Sessions/Logout")
        case "/api/v1/auth/me":
            let user = try await connection.object("GET", "/Users/\(userID)")
            return ["id": Self.numberID(userID), "username": user["Name"] as? String ?? "Emby", "role": "user", "email": ""]
        case "/api/v1/profiles" where method == "GET":
            let user = try await connection.object("GET", "/Users/\(userID)")
            let profile: [String: Any] = [
                "id": userID, "name": user["Name"] as? String ?? "Emby",
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
            return try item(await rawItem(id))
        }
        // Episode lists carry one source per episode; the item itself lists
        // every version, which season and series download menus need.
        if let id = route.capture("catalog/items/*/files"), method == "GET" {
            let raw = try await connection.object(
                "GET", "/Users/\(userID)/Items/\(EmbyConnection.id(id))", query: ["Fields": "MediaSources,MediaStreams"]
            )
            return ["files": try (raw["MediaSources"] as? [[String: Any]] ?? []).map { try version($0) }]
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
            let result = try await connection.object("GET", "/Shows/\(EmbyConnection.id(series))/Seasons", query: [
                "UserId": userID, "Fields": Self.fields, "Recursive": "false",
                "IncludeItemTypes": "Season", "SortBy": "SortName", "SortOrder": "Ascending",
            ])
            return ["seasons": try seasonRows(result["Items"] as? [[String: Any]] ?? [])]
        }
        if route.parts.count == 8, route.parts[2] == "catalog", route.parts[3] == "series", route.parts[7] == "episodes" {
            let result = try await items("/Shows/\(EmbyConnection.id(route.parts[4]))/Episodes", query: [
                "Season": route.parts[6], "Recursive": "false", "IncludeItemTypes": "Episode",
                "SortBy": "ParentIndexNumber,IndexNumber", "SortOrder": "Ascending",
            ])
            return ["episodes": result["items"] ?? []]
        }
        if route.parts.count == 4, ["favorites", "watched"].contains(route.parts[2]) {
            return try await userDataRoute(route.parts[2], id: route.parts[3], method: method)
        }
        if let id = route.capture("home/dismissals/continue_watching/*") {
            return try await connection.request(
                "POST", "/Users/\(userID)/Items/\(EmbyConnection.id(id))/HideFromResume",
                query: ["Hide": method == "DELETE" ? "false" : "true"]
            )
        }
        if let id = route.capture("watchlist/*") {
            return try watchlistRoute(id: id, method: method)
        }
        if path == "/api/v1/collections", method == "GET" {
            let listQuery = Self.collectionListQuery(counts: query["counts"] == "true")
                .merging(["SortBy": "SortName", "SortOrder": "Ascending"]) { _, new in new }
            let raw = try await connection.object("GET", "/Users/\(userID)/Items", query: listQuery)
            return ["collections": (raw["Items"] as? [[String: Any]] ?? []).compactMap(collection), "groups": []]
        }
        if let library = route.capture("library/*/collections") {
            let listQuery = Self.collectionListQuery.merging(["ParentId": try await libraryID(library)]) { _, new in new }
            let raw = try await connection.object("GET", "/Users/\(userID)/Items", query: listQuery)
            return ["collections": (raw["Items"] as? [[String: Any]] ?? []).compactMap(collection), "sections": []]
        }
        if let id = route.capture("collections/*/items"), method == "GET" {
            return try await collectionItems(id, offset: query["offset"] ?? "0", limit: query["limit"] ?? "200")
        }
        if route.parts.count >= 3, route.parts[2] == "downloads" {
            return try await EmbyDownloads.shared.route(connection: connection, method: method, path: route.parts, body: payload)
        }
        if path == "/api/v1/sync/progress" {
            return try await syncProgress(payload)
        }
        // Emby has no progress change feed, so this answers with the current
        // watch state of the items named in `ids` (the device's downloads).
        if path == "/api/v1/progress", method == "GET", let list = query["ids"] {
            return try await progress(ids: list)
        }
        if path.hasPrefix("/api/v1/settings/values/") || path == "/api/v1/settings/contract/capabilities" {
            return try await EmbyLocalPreferences.shared.route(connection: connection, method: method, path: route.parts, query: query, body: payload)
        }
        if path == "/api/v1/settings/effective" {
            return ["settings": effectiveLegacySettings(keys: query["keys"] ?? "")]
        }
        if path == "/api/v1/catalog/filters" {
            return try await catalogFilters(libraryNumber: query["library_id"])
        }
        if route.parts.count >= 3, route.parts[2] == "settings" {
            return try legacySettingRoute(route.parts, method: method, payload: payload)
        }
        throw EmbyError.unsupportedFeature
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

    private func person(_ id: String) async throws -> [String: Any] {
        let raw = try await rawItem(id)
        var person: [String: Any] = ["id": Self.numberID(id), "name": raw["Name"] as? String ?? ""]
        person["bio"] = raw["Overview"]
        person["photoUrl"] = image(raw, kind: "Primary")
        person["birthDate"] = raw["PremiereDate"]
        person["deathDate"] = raw["EndDate"]
        return person
    }

    /// Favourites and played state live in Emby. A GET answers 404 when the
    /// item isn't a favourite or played, as Silo does.
    private func userDataRoute(_ kind: String, id: String, method: String) async throws -> Any {
        if method == "GET" {
            let data = try await rawItem(id)["UserData"] as? [String: Any] ?? [:]
            guard data[kind == "watched" ? "Played" : "IsFavorite"] as? Bool == true else {
                throw HTTPError.http(statusCode: 404, body: nil)
            }
            return [String: Any]()
        }
        let list = kind == "favorites" ? "FavoriteItems" : "PlayedItems"
        return try await connection.request(method == "DELETE" ? "DELETE" : "POST", "/Users/\(userID)/\(list)/\(EmbyConnection.id(id))")
    }

    // MARK: - Collections

    /// Collection cards only need a name and poster. Emby works out each
    /// collection's count title by title for the user, so with counts a list
    /// of 162 collections took 3 to 22 seconds and without them about a
    /// fifth of a second. Lists leave counts out; `counts=true` asks for
    /// them, which the Home Collections row does in the background and keeps.
    nonisolated static let collectionListQuery: [String: String] = [
        "Recursive": "true", "IncludeItemTypes": "BoxSet",
        "EnableUserData": "false", "EnableImageTypes": "Primary", "ImageTypeLimit": "1",
    ]

    nonisolated static func collectionListQuery(counts: Bool) -> [String: String] {
        var query = collectionListQuery
        if counts { query["Fields"] = "ChildCount" }
        return query
    }

    /// `DisplayOrder` keeps the order set on each collection (release date
    /// unless changed to name). Older servers get no sort, as Emby's own
    /// client does there.
    nonisolated static func collectionQuery(id: String, offset: String, limit: String, displayOrder: Bool) -> [String: String] {
        var query = [
            "ParentId": id, "Recursive": "false", "GroupItemsIntoCollections": "false",
            "StartIndex": offset, "Limit": limit,
        ]
        if displayOrder { query["SortBy"] = "DisplayOrder" }
        return query
    }

    func collection(_ raw: [String: Any]) -> [String: Any]? {
        guard raw["Type"] as? String == "BoxSet",
              let id = raw["Id"] as? String,
              let name = raw["Name"] as? String
        else { return nil }
        var result: [String: Any] = ["id": id, "name": name, "title": name, "collectionType": "collection", "kind": "regular"]
        result["itemCount"] = raw["ChildCount"]
        result["posterUrl"] = image(raw, kind: "Primary")
        return result
    }

    func collectionItems(_ collection: String, offset: String, limit: String, fields: String? = nil) async throws -> [String: Any] {
        let id = try EmbyConnection.id(collection)
        // A failed version check fails the page rather than loading it in
        // another order, which would repeat or skip titles part-way through.
        let version = try await serverVersion()
        var query = Self.collectionQuery(
            id: id, offset: offset, limit: limit,
            displayOrder: Self.sortsCollectionsByDisplayOrder(version: version)
        )
        if let fields { query["Fields"] = fields }
        return try await items(query: query)
    }

    // MARK: - Catalogue

    /// Silo catalogue query keys > Emby query keys, copied when not empty.
    private static let catalogFilterKeys = [
        "search": "SearchTerm", "q": "SearchTerm", "genre": "Genres", "genres": "Genres",
        "year": "Years", "years": "Years", "content_rating": "OfficialRatings", "studio": "StudioIds",
    ]

    private static let catalogSorts = [
        "title": "SortName", "year": "ProductionYear", "release_date": "PremiereDate", "added": "DateCreated",
        "added_at": "DateCreated", "rating": "CommunityRating", "random": "Random", "runtime": "Runtime",
        "latest_episode_added": "DateLastContentAdded,SortName", "last_air_date": "LastContentPremiereDate,SortName",
    ]

    /// Emby sorts series by their newest episode's air date from 4.9.0.17,
    /// the version its own web app offers it from.
    nonisolated static func sortsByLastEpisodeAired(version: String) -> Bool {
        isVersion(version, atLeast: [4, 9, 0, 17])
    }

    func catalog(_ input: [String: String]) async throws -> [String: Any] {
        if let collection = input["collection_id"] {
            return try await collectionItems(collection, offset: input["offset"] ?? "0", limit: input["limit"] ?? "60", fields: Self.browseFields)
        }
        var query = [
            "Fields": Self.browseFields,
            "StartIndex": input["offset"] ?? "0",
            "Limit": input["limit"] ?? "60",
            "IncludeItemTypes": "Movie,Series",
            "SortBy": "SortName",
            "SortOrder": input["order"] == "desc" ? "Descending" : "Ascending",
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
        // Older servers fall back to the newest episode's arrival.
        if input["sort"] == "last_air_date", !Self.sortsByLastEpisodeAired(version: try await serverVersion()) {
            query["SortBy"] = Self.catalogSorts["latest_episode_added"]
        }
        if let library = input["library_id"] { query["ParentId"] = try await libraryID(library) }
        if let prefix = input["name_prefix"], !prefix.isEmpty {
            if prefix == "#" { query["NameLessThan"] = "A" } else { query["NameStartsWith"] = prefix }
        }
        if let person = input["person_id"] { query["PersonIds"] = try EmbyConnection.id(person) }
        switch input["emby_watch_status"] {
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

    /// The genre and rating filter options, read in pages of 1,000 up to
    /// 10,000 rows or 100 pages. An HTTP failure names the step that failed.
    private func catalogFilters(libraryNumber: String?) async throws -> [String: Any] {
        var filterQuery = ["UserId": userID]
        if let libraryNumber {
            do { filterQuery["ParentId"] = try await libraryID(libraryNumber) }
            catch HTTPError.http(let status, _) { throw EmbyError.filterRequestFailed(step: "Library lookup", status: status) }
        }
        filterQuery["Recursive"] = "true"
        filterQuery["EnableImages"] = "false"

        func optionRows(_ path: String) async throws -> [Any] {
            let maximumRows = 10_000
            var rows: [Any] = []
            var pageQuery = filterQuery
            pageQuery["Limit"] = "1000"
            for _ in 0..<100 {
                try Task.checkCancellation()
                pageQuery["StartIndex"] = String(rows.count)
                let response: [String: Any]
                do { response = try await connection.object("GET", path, query: pageQuery) }
                catch HTTPError.http(let status, _) {
                    throw EmbyError.filterRequestFailed(step: path == "/Genres" ? "Genres" : "Ratings", status: status)
                }
                guard let page = response["Items"] as? [Any], page.count <= maximumRows - rows.count else {
                    throw EmbyError.invalidResponse
                }
                rows.append(contentsOf: page)
                let total = response["TotalRecordCount"] as? Int ?? rows.count
                if page.isEmpty || rows.count >= total { return rows }
                guard rows.count < maximumRows else { throw EmbyError.invalidResponse }
            }
            throw EmbyError.invalidResponse
        }

        let genres = try await optionRows("/Genres")
        let ratings = try await optionRows("/OfficialRatings")
        return Self.catalogFilterOptions(["Genres": genres, "OfficialRatings": ratings])
    }

    // MARK: - Watch details

    func watchWithPreferences(_ raw: [String: Any]) async throws -> [String: Any] {
        let preferenceID = raw["SeriesId"] as? String ?? raw["Id"] as? String ?? ""
        return try watch(
            raw,
            preferences: await EmbyLocalPreferences.shared.playbackValues(connection: connection),
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
        _ = try EmbyConnection.id(id)
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
            throw EmbyError.unsupportedFeature
        }
    }

    /// Vivid's own watchlist, kept on the device. A GET answers 404 for an
    /// item not on it.
    private func watchlistRoute(id rawID: String, method: String) throws -> Any {
        let id = try EmbyConnection.id(rawID)
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

    /// The older string settings (`/api/v1/settings/{key}`), kept on the
    /// device. Settings Vivid saved for the device take precedence.
    private func effectiveLegacySettings(keys: String) -> [[String: Any]] {
        let prefix = "vivid.emby.setting.\(connection.identity!.account.serverId).\(userID)."
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
        let key = "vivid.emby.setting.\(connection.identity!.account.serverId).\(userID).\(parts.dropFirst(3).joined(separator: "."))"
        if method == "GET" {
            guard let value = UserDefaults.standard.string(forKey: key) else { throw HTTPError.http(statusCode: 404, body: nil) }
            return ["key": parts.last ?? "", "value": value]
        }
        if method == "DELETE" {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let value = payload["value"] as? String {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            throw EmbyError.unsupportedFeature
        }
        return [String: Any]()
    }

    // MARK: - Progress

    /// Offline progress, sent as stop reports. Unlike a user data write, a
    /// stop goes through Emby's resume settings; without a `PlaySessionId`
    /// it can't end a transcode, and without a `MediaSourceId` it updates the
    /// item itself. A stop isn't safe to repeat, so a failure part-way
    /// returns the items already accepted rather than failing them all.
    private func syncProgress(_ payload: [String: Any]) async throws -> [String: Any] {
        var results: [[String: Any]] = []
        for item in payload["items"] as? [[String: Any]] ?? [] {
            guard let id = item["media_item_id"] as? String,
                  let position = item["position_seconds"] as? Double ?? item["position"] as? Double
            else { throw EmbyError.invalidResponse }
            do {
                _ = try await connection.request("POST", "/Sessions/Playing/Stopped", body: [
                    "ItemId": EmbyConnection.id(id), "PositionTicks": EmbyPlayback.ticks(position),
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
        let ids = try list.split(separator: ",").map { try EmbyConnection.id(String($0)) }
        guard !ids.isEmpty else { return ["progress": []] }
        let raw = try await connection.object("GET", "/Users/\(userID)/Items", query: [
            "Ids": ids.joined(separator: ","), "Recursive": "true", "EnableUserData": "true", "EnableImages": "false",
        ])
        return ["progress": (raw["Items"] as? [[String: Any]] ?? []).compactMap(Self.progress)]
    }
}

/// A `/api/v1/...` path split at `/` (empty pieces dropped), for matching
/// the rest of the path against patterns such as `catalog/items/*`.
private struct EmbyRoute {
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
