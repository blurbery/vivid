import Foundation

/// Emby Home. Emby 4.10.0.4 and later list their own Home sections; older
/// servers are read from the user's home section settings, as Emby's web app
/// does. Rows load a few at a time, and rows that are hidden (and not feeding
/// Spotlight or a combined Continue Watching row) aren't fetched at all.
extension EmbyAdapter {
    /// Concurrent Home row requests, small enough not to crowd a home server.
    static let homeRowConcurrency = 3

    struct HomeRowLoad {
        let index: Int
        let load: () async throws -> [String: Any]
    }

    struct HomeRowResult: @unchecked Sendable {
        let index: Int
        let result: Result<[String: Any], Error>
    }

    struct HomeSectionRequest {
        let section: [String: Any]
        let load: () async throws -> [String: Any]
    }

    // MARK: - Rules

    nonisolated static func excludesHomeRow(id: String, type: String, title: String) -> Bool {
        // "userviews" is Emby's My Media library tiles section. It lists
        // libraries rather than items, so it would only take up an empty row.
        let excluded: Set<String> = ["featured", "spotlight", "recentlyadded", "recentlyadd", "userviews"]
        return [id, type, title].contains { excluded.contains($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
    }

    nonisolated static func usesServerHomeSections(version: String) -> Bool {
        isVersion(version, atLeast: [4, 10, 0, 4])
    }

    /// Emby's own client asks 4.8.0.16 and later to list a collection in its
    /// display order.
    nonisolated static func sortsCollectionsByDisplayOrder(version: String) -> Bool {
        isVersion(version, atLeast: [4, 8, 0, 16])
    }

    /// The legacy `homesection0` to `homesection6` settings, with Emby's
    /// defaults for any left empty, minus `none`.
    nonisolated static func legacyHomeSectionTypes(settings: [String: Any]) -> [String] {
        let defaults = ["smalllibrarytiles", "resume", "resumeaudio", "livetv", "none", "latestmedia", "none"]
        return defaults.indices.compactMap { index in
            let saved = (settings["homesection\(index)"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let value = saved ?? defaults[index]
            return value == "none" ? nil : value
        }
    }

    /// The rows that need fetching: every row not hidden, plus Spotlight's
    /// sources. Spotlight with no saved sources, or with sources the server
    /// no longer has, fetches every row once so it can choose. With Next Up
    /// combined into Continue Watching, both feed the combined row while it's
    /// visible, and neither is fetched while it's hidden (unless Spotlight
    /// uses it).
    static func requiredHomeSectionIDs(
        _ sections: [[String: Any]], hidden: Set<String>, spotlight: [String]?, combine: Bool
    ) -> Set<String> {
        let available = Set(sections.compactMap { $0["id"] as? String })
        let spotlightIDs: Set<String>
        if let spotlight, spotlight.isEmpty || !available.isDisjoint(with: spotlight) {
            spotlightIDs = Set(spotlight)
        } else {
            spotlightIDs = available
        }
        var required = available.subtracting(hidden).union(spotlightIDs.intersection(available))
        guard combine else { return required }

        let resume = sections.filter { $0["sectionType"] as? String == "continue_watching" }
        let next = sections.filter { $0["sectionType"] as? String == "next_up" }
        let playbackIDs = Set((resume + next).compactMap { $0["id"] as? String })
        let combinedID = resume.first?["id"] as? String ?? "continue_watching"
        if hidden.contains(combinedID) {
            required.subtract(playbackIDs.subtracting(spotlightIDs))
        } else {
            required.formUnion(playbackIDs)
        }
        return required
    }

    // MARK: - Loading

    func home(library: String? = nil) async throws -> [String: Any] {
        if let library {
            let parent = try await libraryID(library)
            let rows = try await latest(parent: parent)
            let title = String(localized: "Latest", comment: "Home row of a library's newest items")
            return ["sections": [section("latest-" + parent, title, ["items": rows, "total": rows.count])]]
        }
        guard Self.usesServerHomeSections(version: try await serverVersion()) else { return try await legacyHome() }

        #if os(tvOS)
        let displayMode = "tv"
        #else
        let displayMode = "mobile,desktop"
        #endif
        let response = try await connection.request("GET", "/Users/\(userID)/HomeSections", query: ["displayMode": displayMode])
        guard let definitions = response as? [[String: Any]] else { throw EmbyError.invalidResponse }
        let requests = definitions.compactMap { definition -> HomeSectionRequest? in
            guard let id = definition["Id"] as? String,
                  !Self.excludesHomeRow(
                      id: id,
                      type: definition["SectionType"] as? String ?? "",
                      title: definition["Name"] as? String ?? ""
                  )
            else { return nil }
            return HomeSectionRequest(section: homeSection(definition, catalog: [:])) {
                try await items("/Users/\(userID)/Sections/\(EmbyConnection.id(id))/Items", query: ["Limit": "20", "Fields": Self.homeFields])
            }
        }
        return ["sections": try await fetchHomeSections(requests)]
    }

    func legacyHome() async throws -> [String: Any] {
        let settings: [String: Any]
        do {
            settings = try await connection.object("GET", "/usersettings/\(userID)")
        } catch HTTPError.http(let status, _) where status == 404 {
            let response = try await connection.object(
                "GET", "/DisplayPreferences/usersettings", query: ["UserId": userID, "Client": "emby"]
            )
            settings = response["CustomPrefs"] as? [String: Any] ?? [:]
        }

        let types = Self.legacyHomeSectionTypes(settings: settings)
        var requests: [HomeSectionRequest] = []
        for type in types {
            switch type {
            case "resume":
                let query = [
                    "Limit": "20", "Fields": Self.homeFields, "MediaTypes": "Video",
                    "IncludeNextUp": types.contains("nextup") ? "false" : "true",
                ]
                requests.append(HomeSectionRequest(section: section("continue_watching", String(localized: "Continue Watching"), [:])) {
                    try await items("/Users/\(userID)/Items/Resume", query: query)
                })
            case "nextup":
                requests.append(HomeSectionRequest(section: section("next_up", String(localized: "Next Up"), [:])) {
                    try await nextUp()
                })
            case "latestmedia":
                requests += try await latestMediaRequests()
            case "collections":
                requests.append(HomeSectionRequest(section: section("collections", String(localized: "Collections"), [:])) {
                    try await items(query: ["IncludeItemTypes": "BoxSet", "Limit": "20", "Fields": Self.homeFields, "SortBy": "SortName"])
                })
            case "latestmoviereleases":
                requests.append(HomeSectionRequest(section: section(type, String(localized: "Recently Released Movies"), [:])) {
                    let since = Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: Date()) ?? Date()
                    return try await items(query: [
                        "IncludeItemTypes": "Movie", "Limit": "20", "Fields": Self.homeFields,
                        "SortBy": "ProductionYear,PremiereDate,SortName", "SortOrder": "Descending",
                        "MinPremiereDate": ISO8601DateFormatter().string(from: since),
                    ])
                })
            default:
                continue
            }
        }
        return ["sections": try await fetchHomeSections(requests)]
    }

    /// A Latest row for each movie, series or mixed library the user hasn't
    /// excluded from Latest.
    private func latestMediaRequests() async throws -> [HomeSectionRequest] {
        let user = try await connection.object("GET", "/Users/\(userID)")
        let configuration = user["Configuration"] as? [String: Any] ?? [:]
        let excluded = Set(configuration["LatestItemsExcludes"] as? [String] ?? [])
        let views = try await libraryViews()
        return (views["Items"] as? [[String: Any]] ?? []).compactMap { view in
            guard let id = view["Id"] as? String,
                  let name = view["Name"] as? String,
                  ["movies", "tvshows", "mixed", ""].contains(view["CollectionType"] as? String ?? ""),
                  !excluded.contains(id),
                  !excluded.contains(view["Guid"] as? String ?? "")
            else { return nil }
            let title = String(localized: "Latest \(name)", comment: "Home row of a library's newest items; the library name comes from the server")
            return HomeSectionRequest(section: section("latestmedia_" + id, title, [:])) {
                let rows = try await latest(parent: id)
                return ["items": rows, "total": rows.count]
            }
        }
    }

    private func latest(parent: String) async throws -> [[String: Any]] {
        let latest = try await connection.request(
            "GET", "/Users/\(userID)/Items/Latest",
            query: ["ParentId": parent, "Limit": "20", "Fields": Self.homeFields, "EnableUserData": "true"]
        )
        return try convert(latest as? [[String: Any]] ?? [])
    }

    private func nextUp() async throws -> [String: Any] {
        try await items("/Shows/NextUp", query: ["Limit": "20", "Fields": Self.homeFields, "LegacyNextUp": "true"])
    }

    private func fetchHomeSections(_ requests: [HomeSectionRequest]) async throws -> [[String: Any]] {
        guard let server = connection.identity?.account.serverId else {
            return try await loadHomeSections(requests, hidden: [], spotlight: nil, combine: false)
        }
        let hidden = await HomeSectionPreferences.hiddenSections(server: server, profile: userID)
        let combine = await HomeSectionPreferences.combinesEmbyNextUp(server: server, profile: userID)
        #if os(iOS) || os(tvOS)
        let spotlight = await TVHomeSpotlightPreferences.savedRowIDs(server: server, profile: userID)
        #else
        let spotlight: [String]? = []
        #endif
        return try await loadHomeSections(requests, hidden: hidden, spotlight: spotlight, combine: combine)
    }

    /// Loads the needed rows, a few at a time, and returns every row in its
    /// original order. A row that wasn't loaded keeps its name and ID (so
    /// Settings can turn it back on) with no count. If rows fail, the
    /// earliest failing row's error is thrown, as when rows loaded one by one.
    func loadHomeSections(
        _ requests: [HomeSectionRequest], hidden: Set<String>, spotlight: [String]?, combine: Bool
    ) async throws -> [[String: Any]] {
        var planned = requests
        if combine, !planned.contains(where: { $0.section["sectionType"] as? String == "next_up" }) {
            planned.append(HomeSectionRequest(section: section("next_up", String(localized: "Next Up"), [:])) {
                // Keeps the combined row's rule that a failed Next Up is skipped.
                let rows = try await supplyingCombinedNextUp([], enabled: true)
                return ["items": rows.first?["items"] ?? [], "total": rows.first?["totalCount"] ?? 0]
            })
        }
        let required = Self.requiredHomeSectionIDs(planned.map(\.section), hidden: hidden, spotlight: spotlight, combine: combine)
        try Task.checkCancellation()

        let loads = planned.enumerated().compactMap { index, request -> HomeRowLoad? in
            guard let id = request.section["id"] as? String, required.contains(id) else { return nil }
            return HomeRowLoad(index: index, load: request.load)
        }
        let results = await Self.load(loads)
        try Task.checkCancellation()

        return try planned.enumerated().map { index, request in
            var row = request.section
            if let result = results[index] {
                let catalog = try result.get()
                row["items"] = catalog["items"] ?? []
                row["totalCount"] = catalog["total"]
            } else {
                // A skipped row's count is unknown, not zero.
                row.removeValue(forKey: "totalCount")
            }
            return row
        }
    }

    /// Runs the loads, at most `homeRowConcurrency` at once, and files each
    /// result under its row's index. The index travels in a named struct:
    /// optimised builds once lost it when it was returned in a tuple, filing
    /// every result under the first row.
    private static func load(_ loads: [HomeRowLoad]) async -> [Int: Result<[String: Any], Error>] {
        var results: [Int: Result<[String: Any], Error>] = [:]
        await withTaskGroup(of: HomeRowResult.self) { group in
            var pending = loads[...]
            func startNext() {
                guard let row = pending.popFirst() else { return }
                group.addTask {
                    do { return HomeRowResult(index: row.index, result: .success(try await row.load())) }
                    catch { return HomeRowResult(index: row.index, result: .failure(error)) }
                }
            }
            for _ in 0..<homeRowConcurrency { startNext() }
            while let finished = await group.next() {
                results[finished.index] = finished.result
                startNext()
            }
        }
        return results
    }

    /// Adds a Next Up row when combining is on and there isn't one. A failed
    /// Next Up is left out, unless the failure is a cancellation, a changed
    /// sign-in or an expired session.
    func supplyingCombinedNextUp(_ sections: [[String: Any]], enabled: Bool) async throws -> [[String: Any]] {
        guard enabled, !sections.contains(where: { $0["sectionType"] as? String == "next_up" }) else { return sections }
        do {
            return sections + [section("next_up", String(localized: "Next Up"), try await nextUp())]
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if case HTTPError.requestIdentityChanged = error { throw error }
            if case EmbyError.signInRequired = error { throw error }
            return sections
        }
    }

    /// A server Home section as a Vivid row, with resume and Next Up
    /// sections given Vivid's own types.
    func homeSection(_ definition: [String: Any], catalog: [String: Any]) -> [String: Any] {
        let rawType = definition["SectionType"] as? String ?? ""
        var result = section(definition["Id"] as? String ?? "", definition["Name"] as? String ?? "", catalog)
        switch rawType.lowercased().replacingOccurrences(of: "_", with: "") {
        case "resume", "resumemedia", "continuewatching": result["sectionType"] = "continue_watching"
        case "nextup": result["sectionType"] = "next_up"
        default: result["sectionType"] = rawType
        }
        return result
    }

    func section(_ id: String, _ title: String, _ catalog: [String: Any], featured: Bool = false) -> [String: Any] {
        [
            "id": id,
            "sectionType": id,
            "title": title,
            "featured": featured,
            "items": catalog["items"] ?? [],
            "totalCount": catalog["total"] ?? 0,
        ]
    }
}
