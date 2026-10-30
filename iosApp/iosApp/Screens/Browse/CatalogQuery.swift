import Foundation

/// Turns a filter state into the `/api/v1/catalog` query. Silo takes grouped
/// filter rules; Emby and Jellyfin take the flat keys their adapters read.
enum CatalogQueryBuilder {
    static func build(
        _ state: CatalogFilterState,
        libraryId: Int?,
        mediaType: BrowseMediaType,
        offset: Int,
        limit: Int,
        snapshot: String? = nil,
        includeTotal: Bool = true,
        includeType: Bool = true,
        provider: MediaServerProvider = .active
    ) -> [String: String] {
        var query = [
            "source": "query",
            "offset": String(offset),
            "limit": String(limit),
            "sort": state.sort.field,
            "order": state.effectiveOrder.rawValue,
            "match": state.matchAll ? "all" : "any",
        ]
        if let libraryId { query["library_id"] = String(libraryId) }
        if state.mediaScope == nil, includeType, let type = mediaType.catalogTypeParam {
            query["type"] = type
        }
        if let namePrefix = state.namePrefix { query["name_prefix"] = namePrefix }
        if let snapshot { query["snapshot"] = snapshot }
        if !includeTotal { query["include_total"] = "false" }

        for (index, group) in ruleGroups(for: state).enumerated() {
            group.encode(at: index, into: &query)
        }

        switch provider {
        case .silo: return query
        case .emby: return embyQuery(state, base: query)
        case .jellyfin: return jellyfinQuery(state, base: query)
        }
    }

    static func embyQuery(_ state: CatalogFilterState, base: [String: String]) -> [String: String] {
        flatQuery(state, base: base, watchStatusKey: "emby_watch_status")
    }

    static func jellyfinQuery(_ state: CatalogFilterState, base: [String: String]) -> [String: String] {
        flatQuery(state, base: base, watchStatusKey: "jellyfin_watch_status")
    }

    private static func flatQuery(
        _ state: CatalogFilterState,
        base: [String: String],
        watchStatusKey: String
    ) -> [String: String] {
        var query = base.filter { $0.key != "match" && !$0.key.hasPrefix("groups[") }
        if let scope = state.mediaScope { query["type"] = scope }
        if !state.genres.isEmpty { query["genre"] = state.genres.sorted().joined(separator: "|") }
        if !state.contentRatings.isEmpty {
            query["content_rating"] = state.contentRatings.sorted().joined(separator: "|")
        }
        if !state.decades.isEmpty {
            let years = state.decades.sorted().flatMap { $0...($0 + 9) }
            query["years"] = years.map(String.init).joined(separator: ",")
        }
        switch state.watchStatus {
        case .watchlist?: query["source"] = "watchlist"
        case let status?: query[watchStatusKey] = status.rawValue
        case nil: break
        }
        return query
    }

    private struct Rule {
        let field: String
        let op: String
        let values: [String]
    }

    private struct RuleGroup {
        let matchesAll: Bool
        let rules: [Rule]

        func encode(at index: Int, into query: inout [String: String]) {
            let prefix = "groups[\(index)]"
            query["\(prefix)[match]"] = matchesAll ? "all" : "any"
            for (ruleIndex, rule) in rules.enumerated() {
                let rulePrefix = "\(prefix)[rules][\(ruleIndex)]"
                query["\(rulePrefix)[field]"] = rule.field
                query["\(rulePrefix)[op]"] = rule.op
                if rule.values.count == 1 {
                    query["\(rulePrefix)[value]"] = rule.values[0]
                } else {
                    for (valueIndex, value) in rule.values.enumerated() {
                        query["\(rulePrefix)[value][\(valueIndex)]"] = value
                    }
                }
            }
        }
    }

    private static func ruleGroups(for state: CatalogFilterState) -> [RuleGroup] {
        var groups: [RuleGroup] = []
        if let scope = state.mediaScope {
            groups.append(RuleGroup(matchesAll: true, rules: [Rule(field: "type", op: "is", values: [scope])]))
        }
        let valueSets: [(field: String, op: String, values: Set<String>)] = [
            ("genre", "contains", state.genres),
            ("studio", "is", state.studios),
            ("network", "is", state.networks),
            ("country", "is", state.countries),
            ("content_rating", "is", state.contentRatings),
            ("resolution", "is", state.resolutions),
            ("audio_language", "is", state.audioLanguages),
            ("subtitle_language", "is", state.subtitleLanguages),
            ("original_language", "is", state.originalLanguages),
        ]
        for set in valueSets where !set.values.isEmpty {
            let rules = set.values.sorted().map { Rule(field: set.field, op: set.op, values: [$0]) }
            groups.append(RuleGroup(matchesAll: false, rules: rules))
        }
        if !state.decades.isEmpty {
            let rules = state.decades.sorted().map {
                Rule(field: "year", op: "between", values: [String($0), String($0 + 9)])
            }
            groups.append(RuleGroup(matchesAll: false, rules: rules))
        }
        if state.hdr || state.dolbyVision {
            var rules: [Rule] = []
            if state.hdr { rules.append(Rule(field: "hdr", op: "is", values: ["true"])) }
            if state.dolbyVision { rules.append(Rule(field: "dolby_vision", op: "is", values: ["true"])) }
            groups.append(RuleGroup(matchesAll: false, rules: rules))
        }
        if let status = state.watchStatus {
            groups.append(RuleGroup(matchesAll: true, rules: [watchRule(for: status)]))
        }
        return groups
    }

    private static func watchRule(for status: CatalogFilterState.WatchStatus) -> Rule {
        switch status {
        case .unwatched: Rule(field: "watched", op: "is", values: ["false"])
        case .watched: Rule(field: "watched", op: "is", values: ["true"])
        case .inProgress: Rule(field: "in_progress", op: "is", values: ["true"])
        case .favorited: Rule(field: "favorited", op: "is", values: ["true"])
        case .watchlist: Rule(field: "in_watchlist", op: "is", values: ["true"])
        }
    }
}
