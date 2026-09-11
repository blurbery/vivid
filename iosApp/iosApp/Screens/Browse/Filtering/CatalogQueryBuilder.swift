import Foundation

/// Builds the `/api/v1/catalog` query params from a `CatalogFilterState`.
///
/// Multi-value facets are encoded as one structured group per facet
/// (`match=any` inside, one rule per value) using the server's indexed
/// bracket keys (`groups[g][rules][r][value][k]`). That is the only
/// multi-value form expressible through the `[String: String]` HTTP layer
/// (which emits one query item per key and cannot repeat a key), and it is
/// the same shape the server itself produces for multi content-rating — see
/// `catalog_parser.go`. The top-level `match` controls AND/OR across facets.
enum CatalogQueryBuilder {
    static func embyQuery(_ state: CatalogFilterState, base: [String: String]) -> [String: String] {
        var query = base.filter { !$0.key.hasPrefix("groups[") && $0.key != "match" }
        if let scope = state.mediaScope { query["type"] = scope }
        if !state.genres.isEmpty { query["genre"] = state.genres.sorted().joined(separator: "|") }
        if !state.contentRatings.isEmpty { query["content_rating"] = state.contentRatings.sorted().joined(separator: "|") }
        if !state.decades.isEmpty {
            query["years"] = state.decades.sorted().flatMap { Array($0...($0 + 9)) }.map(String.init).joined(separator: ",")
        }
        if state.watchStatus == .watchlist { query["source"] = "watchlist" }
        else if let status = state.watchStatus { query["emby_watch_status"] = status.rawValue }
        return query
    }

    static func build(
        _ state: CatalogFilterState,
        libraryId: Int?,
        mediaType: BrowseMediaType,
        offset: Int,
        limit: Int,
        snapshot: String? = nil,
        includeTotal: Bool = true,
        /// Whether to emit the `type` media-scope param. iOS omits it — a
        /// `library_id`-scoped query is already homogeneous. tvOS sends it
        /// because it knows the library type.
        includeType: Bool = true
    ) -> [String: String] {
        var q: [String: String] = [
            "source": "query",
            "offset": String(offset),
            "limit": String(limit),
            "sort": state.sort.field,
            "order": state.effectiveOrder.rawValue,
            "match": state.matchAll ? "all" : "any",
        ]
        if let libraryId { q["library_id"] = String(libraryId) }
        if state.mediaScope == nil,
           includeType,
           let type = mediaType.catalogTypeParam {
            q["type"] = type
        }
        if let prefix = state.namePrefix { q["name_prefix"] = prefix }
        if let snapshot { q["snapshot"] = snapshot }
        if !includeTotal { q["include_total"] = "false" }

        var groups = GroupAccumulator()
        // A user-chosen Type facet (mixed libraries) is a filter facet, not an
        // unconditional media_scope. Keep it inside the grouped filter logic so
        // top-level Match All / Match Any applies consistently across facets.
        if let scope = state.mediaScope {
            groups.add(field: "type", op: "is", value: scope)
        }
        // Array columns accept `contains`; scalar columns accept `is`.
        groups.add(field: "genre", op: "contains", values: state.genres)
        groups.add(field: "studio", op: "is", values: state.studios)
        groups.add(field: "network", op: "is", values: state.networks)
        groups.add(field: "country", op: "is", values: state.countries)
        groups.add(field: "content_rating", op: "is", values: state.contentRatings)
        groups.add(field: "resolution", op: "is", values: state.resolutions)
        groups.add(field: "audio_language", op: "is", values: state.audioLanguages)
        groups.add(field: "subtitle_language", op: "is", values: state.subtitleLanguages)
        groups.add(field: "original_language", op: "is", values: state.originalLanguages)
        groups.addYearRanges(state.decades)
        groups.addDynamicRange(hdr: state.hdr, dolbyVision: state.dolbyVision)
        if let status = state.watchStatus { groups.addWatchStatus(status) }
        groups.encode(into: &q)

        return MediaServerProvider.active == .emby ? embyQuery(state, base: q) : q
    }
}

/// Accumulates `QueryGroup`s and flattens them into the server's bracketed
/// `groups[…]` query keys.
private struct GroupAccumulator {
    private struct Rule {
        let field: String
        let op: String
        /// One element → scalar value; two → an ordered range (for `between`).
        let values: [String]
    }
    private var groups: [(match: String, rules: [Rule])] = []

    /// One group per facet: a rule per value, OR'd within the facet.
    mutating func add(field: String, op: String, values: Set<String>) {
        guard !values.isEmpty else { return }
        let rules = values.sorted().map { Rule(field: field, op: op, values: [$0]) }
        groups.append((match: "any", rules: rules))
    }

    mutating func addBool(field: String, value: Bool) {
        groups.append((match: "all", rules: [Rule(field: field, op: "is", values: [value ? "true" : "false"])]))
    }

    mutating func add(field: String, op: String, value: String) {
        groups.append((match: "all", rules: [Rule(field: field, op: op, values: [value])]))
    }

    mutating func addDynamicRange(hdr: Bool, dolbyVision: Bool) {
        var rules: [Rule] = []
        if hdr { rules.append(Rule(field: "hdr", op: "is", values: ["true"])) }
        if dolbyVision { rules.append(Rule(field: "dolby_vision", op: "is", values: ["true"])) }
        guard !rules.isEmpty else { return }
        groups.append((match: "any", rules: rules))
    }

    mutating func addWatchStatus(_ status: WatchStatusFilter) {
        let rule: Rule
        switch status {
        case .unwatched: rule = Rule(field: "watched", op: "is", values: ["false"])
        case .watched: rule = Rule(field: "watched", op: "is", values: ["true"])
        case .inProgress: rule = Rule(field: "in_progress", op: "is", values: ["true"])
        case .favorited: rule = Rule(field: "favorited", op: "is", values: ["true"])
        case .watchlist: rule = Rule(field: "in_watchlist", op: "is", values: ["true"])
        }
        groups.append((match: "all", rules: [rule]))
    }

    /// Each decade becomes a `year between [start, start+9]` rule, OR'd.
    mutating func addYearRanges(_ decades: Set<Int>) {
        guard !decades.isEmpty else { return }
        let rules = decades.sorted().map { start in
            Rule(field: "year", op: "between", values: [String(start), String(start + 9)])
        }
        groups.append((match: "any", rules: rules))
    }

    func encode(into q: inout [String: String]) {
        for (g, group) in groups.enumerated() {
            q["groups[\(g)][match]"] = group.match
            for (r, rule) in group.rules.enumerated() {
                let base = "groups[\(g)][rules][\(r)]"
                q["\(base)[field]"] = rule.field
                q["\(base)[op]"] = rule.op
                if rule.values.count == 1 {
                    q["\(base)[value]"] = rule.values[0]
                } else {
                    for (v, value) in rule.values.enumerated() {
                        q["\(base)[value][\(v)]"] = value
                    }
                }
            }
        }
    }
}
