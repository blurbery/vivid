import Foundation
import CryptoKit

enum MediaServerProvider: String, Codable, Sendable {
    case silo, emby
    var name: String { self == .emby ? "Emby" : "Silo" }
    static func forServerID(_ id: String?) -> Self { id?.hasPrefix("emby:") == true ? .emby : .silo }
    static var active: Self { forServerID(ServerRegistry.activeServerIDSnapshot) }
}

enum EmbyError: LocalizedError {
    case invalidResponse, invalidURL, unsupportedFeature, signInRequired, playbackUnavailable
    case filterRequestFailed(step: String, status: Int)
    var errorDescription: String? {
        switch self {
        case .filterRequestFailed(let step, let status): "\(step): HTTP \(status)"
        case .invalidResponse: "Emby returned an unexpected response."
        case .invalidURL: "The Emby server returned an invalid address."
        case .unsupportedFeature: "This feature is not available with Emby yet."
        case .signInRequired: "Please sign in to Emby again."
        case .playbackUnavailable: "Emby could not provide a playable media source."
        }
    }
}

final class EmbyRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct EmbyConnection: Sendable {
    let serverURL: String
    let token: String?
    let userID: String?
    let identity: CapturedOrdinaryRequestAuth?
    var sessionOverride: URLSession? = nil

    static func current() async throws -> Self {
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              MediaServerProvider.forServerID(auth.account.serverId) == .emby,
              let token = auth.accessToken, !token.isEmpty else { throw EmbyError.signInRequired }
        let userID = await TokenStore.shared.nativeUserID(expected: auth.account)
        guard let userID, !userID.isEmpty else { throw EmbyError.signInRequired }
        return Self(serverURL: auth.account.serverURL, token: token, userID: userID, identity: auth)
    }

    func validate() async throws {
        try Task.checkCancellation()
        if let identity,
           await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: identity) != identity {
            throw HTTPError.requestIdentityChanged
        }
    }

    static func url(serverURL: String, path: String, query: [String: String] = [:]) throws -> URL {
        guard var base = URLComponents(string: serverURL),
              ["https", "http"].contains(base.scheme?.lowercased() ?? ""), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("..") else { throw EmbyError.invalidURL }
        var prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.split(separator: "/").last?.lowercased() != "emby" { prefix += prefix.isEmpty ? "emby" : "/emby" }
        base.path = "/" + prefix + path
        base.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = base.url else { throw EmbyError.invalidURL }
        return url
    }

    static func id(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw EmbyError.invalidResponse }
        return value
    }

    static let deviceID: String = {
        let key = "vivid.emby.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    var headers: [String: String] {
        var fields = ["X-Emby-Authorization": "Emby Client=\"Vivid\", Device=\"Apple\", DeviceId=\"\(Self.deviceID)\", Version=\"\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")\""]
        if let token { fields["X-Emby-Token"] = token }
        return fields
    }

    private static let session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return config
    }(), delegate: EmbyRedirectPolicy(), delegateQueue: nil)

    func request(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Any {
        let data = try await data(method,path,query:query,body:body)
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with:data)
    }

    func data(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Data {
        try await validate()
        var request = URLRequest(url: try Self.url(serverURL: serverURL, path: path, query: query))
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await (sessionOverride ?? Self.session).data(for: request)
        try await validate()
        guard let response = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                if let identity, let event = await TokenStore.shared.invalidateNativeToken(identity),
                   await TokenStore.shared.shouldConsumeSessionExpiryEvent(event) {
                    await MainActor.run { NotificationCenter.default.post(name: .vividSessionExpired, object: event) }
                }
                throw EmbyError.signInRequired
            }
            throw HTTPError.http(statusCode: response.statusCode, body: nil)
        }
        return data
    }

    func assetData(_ raw: String) async throws -> Data {
        let base = try Self.url(serverURL:serverURL,path:"/")
        guard let url = URL(string:raw), url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil, url.path.hasPrefix(base.path),
              let components = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw EmbyError.invalidURL }
        let path = "/" + url.path.dropFirst(base.path.count)
        guard path.hasPrefix("/Items/") || path.hasPrefix("/Videos/") else { throw EmbyError.invalidURL }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        return try await data("GET",path,query:query)
    }

    func object(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> [String: Any] {
        guard let result = try await request(method, path, query: query, body: body) as? [String: Any] else { throw EmbyError.invalidResponse }
        return result
    }

    static func probe(serverURL: String) async throws -> String? {
        let result = try await Self(serverURL: serverURL, token: nil, userID: nil, identity: nil).object("GET", "/System/Info/Public")
        guard result["Id"] is String, result["Version"] is String else { throw EmbyError.invalidResponse }
        return result["ServerName"] as? String
    }

    static func login(serverURL: String, username: String, password: String) async throws -> (token: String, userID: String) {
        let result = try await Self(serverURL: serverURL, token: nil, userID: nil, identity: nil)
            .object("POST", "/Users/AuthenticateByName", body: ["Username": username, "Pw": password])
        guard let token = result["AccessToken"] as? String, !token.isEmpty,
              let user = result["User"] as? [String: Any], let userID = user["Id"] as? String else { throw EmbyError.invalidResponse }
        return (token, try id(userID))
    }
}

struct EmbyAdapter {
    let connection: EmbyConnection
    var userID: String { connection.userID! }
    static let fields = "Overview,Genres,Studios,People,ProviderIds,MediaSources,MediaStreams,Chapters,DateCreated,UserData,SortName,Taglines,ChildCount,RecursiveItemCount,PrimaryImageAspectRatio"

    static func seconds(_ ticks: Any?) -> Double {
        guard let number = ticks as? NSNumber else { return 0 }
        let value = number.doubleValue / 10_000_000
        return value.isFinite ? max(0,value) : 0
    }

    static func numberID(_ raw: String) -> Int {
        if let numeric = Int(raw), numeric >= 0 { return numeric }
        return SHA256.hash(data: Data(raw.utf8)).prefix(7).reduce(0) { ($0 << 8) | Int($1) }
    }

    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }

    func image(_ item: [String: Any], kind: String) -> String? {
        let tags = item["ImageTags"] as? [String: Any] ?? [:]
        var imageID = item["Id"] as? String
        var tag = tags[kind] as? String
        if kind == "Backdrop" {
            tag = (item["BackdropImageTags"] as? [String])?.first
            if tag == nil {
                imageID = item["ParentBackdropItemId"] as? String
                tag = (item["ParentBackdropImageTags"] as? [String])?.first
            }
        } else if kind == "Primary", tag == nil {
            imageID = item["SeriesId"] as? String
            tag = item["SeriesPrimaryImageTag"] as? String
        } else if kind == "Logo", tag == nil {
            imageID = item["ParentLogoItemId"] as? String
            tag = item["ParentLogoImageTag"] as? String
        }
        guard let imageID, let tag, (try? EmbyConnection.id(imageID)) != nil else { return nil }
        return try? EmbyConnection.url(serverURL: connection.serverURL,
            path: "/Items/\(imageID)/Images/\(kind)", query: ["tag": tag, "maxWidth": kind == "Backdrop" ? "1920" : "780", "quality": "90"]).absoluteString
    }

    func item(_ raw: [String: Any]) throws -> [String: Any] {
        guard let id = raw["Id"] as? String, let name = raw["Name"] as? String else { throw EmbyError.invalidResponse }
        _ = try EmbyConnection.id(id)
        let kind = (raw["Type"] as? String ?? "Movie").lowercased()
        let user = raw["UserData"] as? [String: Any] ?? [:]
        let seconds = Self.seconds(raw["RunTimeTicks"])
        let position = Self.seconds(user["PlaybackPositionTicks"])
        var value: [String: Any] = ["contentId": id, "title": name, "type": kind == "boxset" ? "collection" : kind,
            "status": "available", "runtime": Int(seconds / 60), "durationSeconds": seconds, "positionSeconds": position,
            "userState": ["played": user["Played"] as? Bool ?? false, "isFavorite": user["IsFavorite"] as? Bool ?? false, "inWatchlist": watchlistIDs.contains(id)],
            "userData": ["played": user["Played"] as? Bool ?? false, "isInProgress": position > 0, "positionSeconds": position, "durationSeconds": seconds],
            "versions": try (raw["MediaSources"] as? [[String: Any]] ?? []).map { try version($0, chapters: raw["Chapters"] as? [[String: Any]] ?? []) }]
        let pairs = ["ProductionYear":"year", "Overview":"overview", "OfficialRating":"contentRating", "Genres":"genres", "CommunityRating":"ratingTmdb", "CriticRating":"ratingRtCritic", "PremiereDate":"releaseDate", "DateCreated":"addedAt", "SeriesId":"seriesId", "SeriesName":"seriesTitle", "ParentIndexNumber":"seasonNumber", "IndexNumber":"episodeNumber", "ChildCount":"episodeCount", "Status":"showStatus", "SortName":"sortTitle"]
        for (source,target) in pairs { value[target] = raw[source] }
        let people = raw["People"] as? [[String:Any]] ?? []
        value["cast"] = people.filter { $0["Type"] as? String == "Actor" }.compactMap { person -> [String:Any]? in
            guard let name = person["Name"] as? String else { return nil }
            var member: [String:Any] = ["name":name]
            member["personId"] = person["Id"]; member["character"] = person["Role"]
            if let id = person["Id"] as? String, let tag = person["PrimaryImageTag"] as? String {
                member["photoUrl"] = try? EmbyConnection.url(serverURL:connection.serverURL,path:"/Items/\(EmbyConnection.id(id))/Images/Primary",query:["tag":tag,"maxWidth":"300"]).absoluteString
            }
            return member
        }
        value["posterUrl"] = image(raw, kind: "Primary")
        value["stillUrl"] = image(raw, kind: "Primary")
        value["backdropUrl"] = image(raw, kind: "Backdrop")
        value["logoUrl"] = image(raw, kind: "Logo")
        value["airDate"] = raw["PremiereDate"]
        value["progressUpdatedAt"] = user["LastPlayedDate"]
        value["studios"] = (raw["Studios"] as? [[String: Any]])?.compactMap { $0["Name"] as? String }
        let providers = Dictionary((raw["ProviderIds"] as? [String:String] ?? [:]).map { ($0.key.lowercased(),$0.value) },uniquingKeysWith:{ _,last in last })
        value["imdbId"] = providers["imdb"]; value["tmdbId"] = providers["tmdb"]; value["tvdbId"] = providers["tvdb"]
        if kind == "season" {
            let seasonNumber = raw["IndexNumber"] as? Int
            value["seasonNumber"] = seasonNumber ?? 0
            value["episodeCount"] = raw["RecursiveItemCount"] as? Int ?? raw["ChildCount"] as? Int ?? 0
            value["isSpecials"] = seasonNumber == 0
            if let seasonNumber, seasonNumber >= 0 {
                value["title"] = seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
            }
        }
        if kind == "episode" { value["seasonNumber"] = raw["ParentIndexNumber"] as? Int ?? 0; value["episodeNumber"] = raw["IndexNumber"] as? Int ?? 0; value["files"] = value["versions"] }
        return value
    }

    func version(_ raw: [String: Any], chapters: [[String: Any]] = []) throws -> [String: Any] {
        guard let id = raw["Id"] as? String else { throw EmbyError.invalidResponse }
        let streams = raw["MediaStreams"] as? [[String: Any]] ?? []
        let video = streams.first { $0["Type"] as? String == "Video" } ?? [:]
        let audios = streams.filter { $0["Type"] as? String == "Audio" }
        var value: [String: Any] = ["fileId": Self.numberID(id), "duration": Self.seconds(raw["RunTimeTicks"]),
            "audioTracks": audios.enumerated().map { ordinal, stream in track(stream, index: ordinal) },
            "subtitleTracks": streams.filter { $0["Type"] as? String == "Subtitle" }.map { track($0, index: $0["Index"] as? Int ?? -1) },
            "videoTracks": streams.filter { $0["Type"] as? String == "Video" }.map { track($0, index: $0["Index"] as? Int ?? 0) },
            "chapters": chapters.enumerated().map { index, chapter in ["index": index, "startSeconds": Self.seconds(chapter["StartPositionTicks"]), "title": chapter["Name"] as? String ?? "Chapter \(index + 1)"] }]
        value["fileName"] = raw["Name"]
        value["container"] = raw["Container"]; value["fileSize"] = raw["Size"]; value["bitrate"] = raw["Bitrate"]
        value["codecVideo"] = video["Codec"]; value["codecAudio"] = audios.first?["Codec"]
        if let height = video["Height"] as? Int {
            let width = video["Width"] as? Int ?? 0
            let resolution = width >= 3800 || height >= 2100 ? 2160
                : width >= 1900 || height >= 1050 ? 1080
                : width >= 1260 || height >= 700 ? 720 : height
            value["resolution"] = "\(resolution)p"
        }
        value["hdr"] = (video["VideoRange"] as? String ?? "SDR") != "SDR"
        if let defaultIndex = raw["DefaultAudioStreamIndex"] as? Int { value["effectiveAudioTrackIndex"] = audios.firstIndex { $0["Index"] as? Int == defaultIndex } }
        return value
    }

    func track(_ raw: [String: Any], index: Int) -> [String: Any] {
        var value: [String: Any] = ["index": index]
        for (source,target) in ["Codec":"codec", "Language":"language", "DisplayTitle":"title", "Title":"embeddedTitle", "IsDefault":"default", "IsForced":"forced", "IsHearingImpaired":"hearingImpaired", "IsExternal":"external", "Channels":"channels", "ChannelLayout":"layout", "SampleRate":"sampleRate", "BitRate":"bitrate", "Width":"width", "Height":"height"] { value[target] = raw[source] }
        return value
    }

    func rawItem(_ id: String) async throws -> [String: Any] {
        try await connection.object("GET", "/Users/\(userID)/Items/\(EmbyConnection.id(id))", query: ["Fields": Self.fields])
    }

    func items(_ path: String? = nil, query: [String: String] = [:]) async throws -> [String: Any] {
        var defaults = ["UserId":userID,"Fields":Self.fields,"EnableUserData":"true"]
        if path == nil { defaults["Recursive"] = "true" }
        let q = defaults.merging(query) { _,new in new }
        let raw = try await connection.object("GET", path ?? "/Users/\(userID)/Items", query: q)
        let converted = try (raw["Items"] as? [[String: Any]] ?? []).map(item)
        let total = raw["TotalRecordCount"] as? Int ?? converted.count
        return ["items": converted, "total": total, "totalExact": true, "hasMore": (Int(q["StartIndex"] ?? "0") ?? 0) + converted.count < total]
    }

    func libraryID(_ number: String) async throws -> String {
        let views = try await connection.object("GET", "/Users/\(userID)/Views")
        guard let id = (views["Items"] as? [[String: Any]] ?? []).compactMap({ $0["Id"] as? String }).first(where: { String(Self.numberID($0)) == number }) else { throw EmbyError.invalidResponse }
        return try EmbyConnection.id(id)
    }

    func seasonRows(_ rows: [[String:Any]]) throws -> [[String:Any]] {
        try rows.filter { $0["Type"] as? String == "Season" }.map(item)
    }

    nonisolated static func excludesHomeRow(id: String, type: String, title: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let excluded: Set<String> = ["featured","spotlight","recentlyadded","recentlyadd"]
        return [id,type,title].contains { excluded.contains(normalized($0)) }
    }

    nonisolated static func usesServerHomeSections(version: String) -> Bool {
        let actual = version.split(separator:".").map { Int($0) ?? 0 }
        let minimum = [4,10,0,4]
        for index in minimum.indices {
            let value = actual.indices.contains(index) ? actual[index] : 0
            if value != minimum[index] { return value > minimum[index] }
        }
        return true
    }

    nonisolated static func legacyHomeSectionTypes(settings: [String:Any]) -> [String] {
        let defaults = ["smalllibrarytiles","resume","resumeaudio","livetv","none","latestmedia","none"]
        return defaults.indices.compactMap { index in
            let value = (settings["homesection\(index)"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaults[index]
            return value == "none" ? nil : value
        }
    }

    func legacyHome() async throws -> [String:Any] {
        let settings: [String:Any]
        do { settings = try await connection.object("GET", "/usersettings/\(userID)") }
        catch HTTPError.http(let status, _) where status == 404 {
            let response = try await connection.object("GET", "/DisplayPreferences/usersettings",query:["UserId":userID,"Client":"emby"])
            settings = response["CustomPrefs"] as? [String:Any] ?? [:]
        }
        let types = Self.legacyHomeSectionTypes(settings:settings)
        var sections: [[String:Any]] = []
        for type in types {
            switch type {
            case "resume":
                let result = try await items("/Users/\(userID)/Items/Resume",query:["Limit":"20","MediaTypes":"Video","IncludeNextUp":types.contains("nextup") ? "false" : "true"])
                sections.append(section("continue_watching","Continue Watching",result))
            case "nextup":
                let result = try await items("/Shows/NextUp",query:["Limit":"20","LegacyNextUp":"true"])
                sections.append(section("next_up","Next Up",result))
            case "latestmedia":
                let user = try await connection.object("GET", "/Users/\(userID)")
                let configuration = user["Configuration"] as? [String:Any] ?? [:]
                let excluded = Set(configuration["LatestItemsExcludes"] as? [String] ?? [])
                let views = try await connection.object("GET", "/Users/\(userID)/Views")
                for view in views["Items"] as? [[String:Any]] ?? [] {
                    guard let id = view["Id"] as? String, let name = view["Name"] as? String,
                          ["movies","tvshows","mixed", ""].contains(view["CollectionType"] as? String ?? ""),
                          !excluded.contains(id), !excluded.contains(view["Guid"] as? String ?? "") else { continue }
                    let latest = try await connection.request("GET", "/Users/\(userID)/Items/Latest",query:["ParentId":id,"Limit":"20","Fields":Self.fields,"EnableUserData":"true"])
                    let rows = try (latest as? [[String:Any]] ?? []).map(item)
                    sections.append(section("latestmedia_" + id,"Latest " + name,["items":rows,"total":rows.count]))
                }
            case "collections":
                let result = try await items(query:["IncludeItemTypes":"BoxSet","Limit":"20","SortBy":"SortName"])
                sections.append(section("collections","Collections",result))
            case "latestmoviereleases":
                let since = Calendar(identifier:.gregorian).date(byAdding:.year,value:-1,to:Date()) ?? Date()
                let result = try await items(query:["IncludeItemTypes":"Movie","Limit":"20","SortBy":"ProductionYear,PremiereDate,SortName","SortOrder":"Descending","MinPremiereDate":ISO8601DateFormatter().string(from:since)])
                sections.append(section(type,"Recently Released Movies",result))
            default: continue
            }
        }
        return ["sections": try await supplyingCombinedNextUp(sections)]
    }

    func home(library: String? = nil) async throws -> [String: Any] {
        if let library {
            let parent = try await libraryID(library)
            let latest = try await connection.request("GET", "/Users/\(userID)/Items/Latest",
                query:["ParentId":parent,"Limit":"20","Fields":Self.fields,"EnableUserData":"true"])
            let rows = try (latest as? [[String:Any]] ?? []).map(item)
            return ["sections":[section("latest-" + parent,"Latest",["items":rows,"total":rows.count])]]
        }
        let system = try await connection.object("GET", "/System/Info/Public")
        guard Self.usesServerHomeSections(version:system["Version"] as? String ?? "") else { return try await legacyHome() }
        #if os(tvOS)
        let displayMode = "tv"
        #else
        let displayMode = "mobile,desktop"
        #endif
        let response = try await connection.request("GET", "/Users/\(userID)/HomeSections",query:["displayMode":displayMode])
        guard let definitions = response as? [[String:Any]] else { throw EmbyError.invalidResponse }
        var sections: [[String:Any]] = []
        for definition in definitions {
            guard let id = definition["Id"] as? String,
                  !Self.excludesHomeRow(id:id,type:definition["SectionType"] as? String ?? "",title:definition["Name"] as? String ?? "") else { continue }
            let result = try await items("/Users/\(userID)/Sections/\(EmbyConnection.id(id))/Items",query:["Limit":"20"])
            sections.append(homeSection(definition, catalog:result))
        }
        return ["sections": try await supplyingCombinedNextUp(sections)]
    }

    private func supplyingCombinedNextUp(_ sections: [[String:Any]]) async throws -> [[String:Any]] {
        guard let server = connection.identity?.account.serverId else { return sections }
        let combine = await HomeSectionPreferences.combinesEmbyNextUp(server: server, profile: userID)
        return try await supplyingCombinedNextUp(sections, enabled: combine)
    }

    func supplyingCombinedNextUp(_ sections: [[String:Any]], enabled: Bool) async throws -> [[String:Any]] {
        guard enabled, !sections.contains(where: { $0["sectionType"] as? String == "next_up" }) else { return sections }
        do {
            let result = try await items("/Shows/NextUp", query: ["Limit":"20", "LegacyNextUp":"true"])
            return sections + [section("next_up", "Next Up", result)]
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if case HTTPError.requestIdentityChanged = error { throw error }
            if case EmbyError.signInRequired = error { throw error }
            return sections
        }
    }

    func homeSection(_ definition: [String:Any], catalog: [String:Any]) -> [String:Any] {
        let id = definition["Id"] as? String ?? ""
        let rawType = definition["SectionType"] as? String ?? ""
        let type: String
        switch rawType.lowercased().replacingOccurrences(of:"_",with:"") {
        case "resume", "resumemedia", "continuewatching": type = "continue_watching"
        case "nextup": type = "next_up"
        default: type = rawType
        }
        var result = section(id,definition["Name"] as? String ?? "",catalog)
        result["sectionType"] = type
        return result
    }

    func collection(_ raw: [String:Any]) -> [String:Any]? {
        guard raw["Type"] as? String == "BoxSet", let id = raw["Id"] as? String, let name = raw["Name"] as? String else { return nil }
        var result: [String:Any] = ["id":id,"name":name,"title":name,"collectionType":"collection","kind":"regular"]
        result["itemCount"] = raw["ChildCount"] ?? raw["RecursiveItemCount"]
        result["posterUrl"] = image(raw,kind:"Primary")
        return result
    }

    func section(_ id: String, _ title: String, _ catalog: [String: Any], featured: Bool = false) -> [String: Any] {
        ["id": id, "sectionType": id, "title": title, "featured": featured, "items": catalog["items"] ?? [], "totalCount": catalog["total"] ?? 0]
    }

    private var storagePrefix: String { "vivid.emby." + (connection.identity?.account.serverId ?? connection.serverURL) + "." + userID }
    private var watchlistIDs: [String] { UserDefaults.standard.stringArray(forKey: storagePrefix + ".watchlist") ?? [] }

    nonisolated static func collectionQuery(id: String, offset: String, limit: String) -> [String:String] {
        ["ParentId":id,"Recursive":"false","GroupItemsIntoCollections":"false",
         "StartIndex":offset,"Limit":limit,"SortBy":"SortName","SortOrder":"Ascending"]
    }

    nonisolated static func catalogFilterOptions(_ raw: [String: Any]) -> [String: Any] {
        func names(_ value: Any?) -> [String] {
            let values = (value as? [Any] ?? []).compactMap { entry -> String? in
                if let name = entry as? String { return name }
                return (entry as? [String: Any])?["Name"] as? String
            }.filter { !$0.isEmpty }
            return Array(Set(values)).sorted()
        }
        return ["genres": names(raw["Genres"]), "contentRatings": names(raw["OfficialRatings"]),
                "studios": [String](), "networks": [String](), "countries": [String]()]
    }

    func catalog(_ input: [String: String]) async throws -> [String: Any] {
        if let collection = input["collection_id"] {
            return try await items(query:Self.collectionQuery(id:EmbyConnection.id(collection),offset:input["offset"] ?? "0",limit:input["limit"] ?? "60"))
        }
        var q = ["StartIndex": input["offset"] ?? "0", "Limit": input["limit"] ?? "60", "IncludeItemTypes": "Movie,Series", "SortBy":"SortName", "SortOrder":input["order"] == "desc" ? "Descending" : "Ascending"]
        if let type = input["type"] { q["IncludeItemTypes"] = type == "series" ? "Series" : type == "episode" ? "Episode" : "Movie" }
        for (source,target) in ["search":"SearchTerm", "q":"SearchTerm", "genre":"Genres", "genres":"Genres", "year":"Years", "years":"Years", "content_rating":"OfficialRatings", "studio":"StudioIds"] { if let v = input[source], !v.isEmpty { q[target] = v } }
        let sorts = ["title":"SortName", "year":"ProductionYear", "added":"DateCreated", "added_at":"DateCreated", "rating":"CommunityRating", "random":"Random", "runtime":"Runtime"]
        if let sort = input["sort"], let mapped = sorts[sort] { q["SortBy"] = mapped }
        if let library = input["library_id"] { q["ParentId"] = try await libraryID(library) }
        if let prefix = input["name_prefix"], !prefix.isEmpty {
            if prefix == "#" { q["NameLessThan"] = "A" }
            else { q["NameStartsWith"] = prefix }
        }
        if let person = input["person_id"] { q["PersonIds"] = try EmbyConnection.id(person) }
        switch input["emby_watch_status"] {
        case "watched": q["IsPlayed"] = "true"
        case "unwatched": q["IsPlayed"] = "false"
        case "inProgress": q["Filters"] = "IsResumable"
        case "favorited": q["IsFavorite"] = "true"
        default: break
        }
        if input["source"] == "favorites" { q["Filters"] = "IsFavorite" }
        if input["source"] == "history" { q["Filters"] = "IsPlayed"; q["SortBy"] = "DatePlayed"; q["SortOrder"] = "Descending"; q["IncludeItemTypes"] = input["type"] == "movie" ? "Movie" : input["type"] == "episode" ? "Episode" : "Movie,Episode" }
        if input["source"] == "watchlist" {
            let ids = watchlistIDs
            guard !ids.isEmpty else { return ["items": [], "total": 0, "hasMore": false] }
            q["Ids"] = ids.joined(separator: ",")
            if input["type"] == nil { q.removeValue(forKey: "IncludeItemTypes") }
        }
        return try await items(query: q)
    }

    private func trackPreference(_ kind: String, id: String) -> [String:Any] {
        guard let data = UserDefaults.standard.data(forKey:storagePrefix + "." + kind + "." + id) else { return [:] }
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
    }

    func watchWithPreferences(_ raw: [String:Any]) async throws -> [String:Any] {
        let prefID = raw["SeriesId"] as? String ?? raw["Id"] as? String ?? ""
        return try watch(raw, preferences: await EmbyLocalPreferences.shared.playbackValues(connection: connection),
                         subtitle: trackPreference("subtitle-prefs", id: prefID), audio: trackPreference("audio-prefs", id: prefID))
    }

    func watch(_ raw: [String:Any], preferences: [String:Any], subtitle: [String:Any] = [:], audio: [String:Any] = [:]) throws -> [String:Any] {
        var value = try item(raw)
        value["effectiveSubtitleLanguage"] = subtitle["subtitle_language"] ?? preferences["playback.subtitle_language"]
        value["effectiveSubtitleMode"] = subtitle["subtitle_mode"] ?? preferences["playback.subtitle_mode"]
        value["effectiveShowForcedSubtitles"] = subtitle["show_forced_subtitles"] ?? preferences["playback.show_forced_subtitles"]
        value["effectiveSubtitleTrackSignature"] = subtitle["track_signature"]
        let language = audio["audio_language"] as? String ?? preferences["playback.audio_language"] as? String
        func normalized(_ code: String) -> String {
            Locale(identifier:code).language.languageCode?.identifier(.alpha2) ?? code.lowercased()
        }
        value["versions"] = (value["versions"] as? [[String:Any]] ?? []).map { version in
            var result = version
            let tracks = version["audioTracks"] as? [[String:Any]] ?? []
            if let language, !language.isEmpty, language != "original",
               let selected = tracks.firstIndex(where:{ normalized($0["language"] as? String ?? "") == normalized(language) }) {
                result["effectiveAudioTrackIndex"] = selected
                result["effectiveAudioLanguage"] = language
            }
            return result
        }
        return value
    }

    func route(method: String, path: String, query: [String: String], body: Any?) async throws -> Any {
        let p = path.split(separator: "/").map(String.init)
        let payload = body as? [String: Any] ?? [:]
        if path == "/api/v1/auth/logout" { return try await connection.request("POST", "/Sessions/Logout") }
        if path == "/api/v1/auth/me" {
            let user = try await connection.object("GET", "/Users/\(userID)")
            return ["id": Self.numberID(userID), "username": user["Name"] as? String ?? "Emby", "role": "user", "email": ""]
        }
        if path == "/api/v1/profiles", method == "GET" {
            let user = try await connection.object("GET", "/Users/\(userID)")
            return ["profiles": [["id": userID, "name": user["Name"] as? String ?? "Emby", "hasPin": false, "isChild": false, "isPrimary": true]]]
        }
        if path == "/api/v1/home/sections" { return try await home() }
        if p.count == 5, p[2] == "library", p[4] == "sections" { return try await home(library: p[3]) }
        if path == "/api/v1/user/libraries" || path == "/api/v1/libraries" {
            let result = try await connection.object("GET", "/Users/\(userID)/Views")
            return (result["Items"] as? [[String: Any]] ?? []).compactMap { raw -> [String: Any]? in
                guard let id = raw["Id"] as? String else { return nil }
                let type = raw["CollectionType"] as? String ?? "mixed"
                guard ["movies", "tvshows", "mixed", ""].contains(type) else { return nil }
                return ["id": Self.numberID(id), "name": raw["Name"] as? String ?? "Library", "type": type == "tvshows" ? "series" : type == "movies" ? "movie" : "mixed"]
            }
        }
        if path == "/api/v1/catalog" { return try await catalog(query) }
        if ["/api/v1/favorites", "/api/v1/history", "/api/v1/watchlist"].contains(path) {
            return try await catalog(query.merging(["source":p[2]]) { _,new in new })
        }
        if p.count == 5, p[2] == "catalog", p[3] == "items" { return try item(await rawItem(p[4])) }
        if p.count == 4, p[2] == "people", method == "GET" {
            let raw = try await rawItem(p[3])
            var person: [String:Any] = ["id":Self.numberID(p[3]), "name":raw["Name"] as? String ?? ""]
            person["bio"] = raw["Overview"]; person["photoUrl"] = image(raw,kind:"Primary")
            person["birthDate"] = raw["PremiereDate"]; person["deathDate"] = raw["EndDate"]
            return person
        }
        if p.count == 4, p[2] == "watch" {
            let raw = try await rawItem(p[3])
            return try await watchWithPreferences(raw)
        }
        if p.count == 4, ["audio-prefs","subtitle-prefs"].contains(p[2]) {
            _ = try EmbyConnection.id(p[3])
            try await connection.validate()
            let key = storagePrefix + "." + p[2] + "." + p[3]
            if method == "GET" { return trackPreference(p[2],id:p[3]) }
            if method == "DELETE" { UserDefaults.standard.removeObject(forKey:key); return [:] }
            guard method == "PUT" else { throw EmbyError.unsupportedFeature }
            UserDefaults.standard.set(try JSONSerialization.data(withJSONObject:payload),forKey:key)
            return payload
        }
        if p.count == 6, p[2] == "catalog", p[3] == "series", p[5] == "seasons" {
            let result = try await connection.object("GET", "/Shows/\(EmbyConnection.id(p[4]))/Seasons",
                query:["UserId":userID,"Fields":Self.fields,"Recursive":"false","IncludeItemTypes":"Season","SortBy":"SortName","SortOrder":"Ascending"])
            return ["seasons":try seasonRows(result["Items"] as? [[String:Any]] ?? [])]
        }
        if p.count == 8, p[2] == "catalog", p[3] == "series", p[7] == "episodes" {
            let result = try await items("/Shows/\(EmbyConnection.id(p[4]))/Episodes", query: ["Season":p[6],"Recursive":"false","IncludeItemTypes":"Episode","SortBy":"ParentIndexNumber,IndexNumber","SortOrder":"Ascending"])
            return ["episodes": result["items"] ?? []]
        }
        if p.count == 4, ["favorites", "watched"].contains(p[2]) {
            let kind = p[2] == "favorites" ? "FavoriteItems" : "PlayedItems"
            if method == "GET" {
                let raw = try await rawItem(p[3]); let data = raw["UserData"] as? [String: Any] ?? [:]
                guard data[p[2] == "watched" ? "Played" : "IsFavorite"] as? Bool == true else { throw HTTPError.http(statusCode: 404, body: nil) }
                return [:]
            }
            return try await connection.request(method == "DELETE" ? "DELETE" : "POST", "/Users/\(userID)/\(kind)/\(EmbyConnection.id(p[3]))")
        }
        if p.count == 6, p[2] == "home", p[3] == "dismissals", p[4] == "continue_watching" {
            return try await connection.request("POST", "/Users/\(userID)/Items/\(EmbyConnection.id(p[5]))/HideFromResume", query: ["Hide":method == "DELETE" ? "false":"true"])
        }
        if path == "/api/v1/recommendations/discover" {
            let result = try await items(query:["SortBy":"Random","IncludeItemTypes":"Movie,Series","Limit":"30"])
            return ["rows":[["type":"discover","label":"Discover","items":result["items"] ?? []]]]
        }
        if p.count == 5, p[2] == "recommendations", p[3] == "similar" {
            let result = try await items("/Items/\(EmbyConnection.id(p[4]))/Similar", query: ["Limit":"12"])
            return ["items": (result["items"] as? [[String: Any]] ?? []).map { ["contentId":$0["contentId"]!, "score":1] }]
        }
        if p.count == 4, p[2] == "watchlist" {
            let id = try EmbyConnection.id(p[3])
            var ids = watchlistIDs
            if method == "GET" {
                guard ids.contains(id) else { throw HTTPError.http(statusCode: 404, body: nil) }
            } else if method == "DELETE" { ids.removeAll { $0 == id } }
            else if method == "PUT", !ids.contains(id) { ids.append(id) }
            UserDefaults.standard.set(ids, forKey: storagePrefix + ".watchlist")
            return [:]
        }
        if path == "/api/v1/collections", method == "GET" {
            let raw = try await connection.object("GET", "/Users/\(userID)/Items", query:["Recursive":"true", "IncludeItemTypes":"BoxSet", "Fields":"Overview,ChildCount,RecursiveItemCount", "SortBy":"SortName", "SortOrder":"Ascending"])
            return ["collections":(raw["Items"] as? [[String:Any]] ?? []).compactMap(collection),"groups":[]]
        }
        if p.count == 5, p[2] == "library", p[4] == "collections" {
            let raw = try await connection.object("GET", "/Users/\(userID)/Items", query:["Recursive":"true", "IncludeItemTypes":"BoxSet", "Fields":"ChildCount,RecursiveItemCount", "ParentId":try await libraryID(p[3])])
            return ["collections":(raw["Items"] as? [[String:Any]] ?? []).compactMap(collection),"sections":[]]
        }
        if p.count == 5, p[2] == "collections", p[4] == "items", method == "GET" {
            return try await items(query:Self.collectionQuery(id:EmbyConnection.id(p[3]),offset:query["offset"] ?? "0",limit:query["limit"] ?? "200"))
        }
        if p.count >= 3, p[2] == "downloads" {
            return try await EmbyDownloads.shared.route(connection:connection,method:method,path:p,body:payload)
        }
        if path == "/api/v1/sync/progress" {
            var results: [[String:Any]] = []
            for item in payload["items"] as? [[String:Any]] ?? [] {
                guard let id = item["media_item_id"] as? String,
                      let position = item["position_seconds"] as? Double ?? item["position"] as? Double else { throw EmbyError.invalidResponse }
                _ = try await connection.request("POST", "/Users/\(userID)/Items/\(EmbyConnection.id(id))/UserData", body:["PlaybackPositionTicks":EmbyPlayback.ticks(position)])
                results.append(["mediaItemId":id,"status":"ok"])
            }
            return ["results":results]
        }
        if path.hasPrefix("/api/v1/settings/values/") || path == "/api/v1/settings/contract/capabilities" {
            return try await EmbyLocalPreferences.shared.route(connection:connection,method:method,path:p,query:query,body:payload)
        }
        if path == "/api/v1/settings/effective" {
            let settings = (query["keys"] ?? "").split(separator:",").compactMap { key -> [String:Any]? in
                let prefix = "vivid.emby.setting.\(connection.identity!.account.serverId).\(userID)."
                let user = UserDefaults.standard.string(forKey:prefix + String(key))
                let device = UserDefaults.standard.string(forKey:prefix + "device." + String(key))
                guard let value = device ?? user else { return nil }
                var setting: [String:Any] = ["key":String(key),"effectiveValue":value,"source":device == nil ? "user":"device","hasDeviceOverride":device != nil]
                setting["userValue"] = user; setting["deviceValue"] = device
                return setting
            }
            return ["settings":settings]
        }
        if path == "/api/v1/catalog/filters" {
            var filterQuery = ["UserId": userID]
            if let library = query["library_id"] {
                do { filterQuery["ParentId"] = try await libraryID(library) }
                catch HTTPError.http(let status, _) { throw EmbyError.filterRequestFailed(step: "Library lookup", status: status) }
            }
            filterQuery["Recursive"] = "true"
            filterQuery["EnableImages"] = "false"
            func optionRows(_ path: String) async throws -> [Any] {
                var rows: [Any] = []
                var pageQuery = filterQuery
                pageQuery["Limit"] = "1000"
                let maximumRows = 10_000
                let maximumPages = 100
                for _ in 0..<maximumPages {
                    try Task.checkCancellation()
                    pageQuery["StartIndex"] = String(rows.count)
                    let response: [String: Any]
                    do { response = try await connection.object("GET", path, query: pageQuery) }
                    catch HTTPError.http(let status, _) { throw EmbyError.filterRequestFailed(step: path == "/Genres" ? "Genres" : "Ratings", status: status) }
                    guard let page = response["Items"] as? [Any] else { throw EmbyError.invalidResponse }
                    guard page.count <= maximumRows - rows.count else { throw EmbyError.invalidResponse }
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
        if p.count >= 3, p[2] == "settings" {
            let key = "vivid.emby.setting.\(connection.identity!.account.serverId).\(userID).\(p.dropFirst(3).joined(separator: "."))"
            if method == "GET" {
                guard let value = UserDefaults.standard.string(forKey:key) else { throw HTTPError.http(statusCode: 404, body: nil) }
                return ["key":p.last ?? "", "value":value]
            }
            if method == "DELETE" { UserDefaults.standard.removeObject(forKey:key) }
            else if let value = payload["value"] as? String { UserDefaults.standard.set(value,forKey:key) }
            else { throw EmbyError.unsupportedFeature }
            return [:]
        }
        throw EmbyError.unsupportedFeature
    }
}
