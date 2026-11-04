#if os(tvOS) || os(iOS)
import Foundation

/// Which Home rows feed the spotlight, up to three, saved for each server
/// and profile. Separate from which rows Home shows.
@Observable
@MainActor
final class TVHomeSpotlightPreferences {
    static let shared = TVHomeSpotlightPreferences()

    private static let maximumRows = 3
    private static let maximumSlides = 10

    /// nil until a choice is saved; Home then uses its first three rows.
    private(set) var selectedRowIDs: [String]?
    private var loadedKey: String?
    private let defaults = SharedDefaults.shared

    init() { refresh() }

    func refresh(force: Bool = false) {
        let key = storageKey
        guard force || key != loadedKey else { return }
        loadedKey = key
        selectedRowIDs = key.flatMap(Self.savedRowIDs(forKey:))
    }

    static func savedRowIDs(server: String, profile: String) -> [String]? {
        savedRowIDs(forKey: storageKey(server: server, profile: profile))
    }

    /// The rows the spotlight can draw from, with Continue Watching and Next
    /// Up combined when Home combines them, regardless of which rows Home
    /// shows or its row limit.
    func sourceSections(from sections: [ResolvedSection]) -> [ResolvedSection] {
        let home = HomeSectionPreferences.shared
        home.refresh()
        let provider = MediaServerProvider.active
        let combined = provider == .jellyfin ? home.combineJellyfinNextUp : home.combineEmbyNextUp
        return Self.projectedSources(sections, combined: combined, provider: provider)
    }

    /// Home's combined rows. On Emby and Jellyfin the combined Continue
    /// Watching row takes turns between resume and next-up items, so a full
    /// resume row can't crowd every next episode out of the ten slides.
    nonisolated static func projectedSources(_ sections: [ResolvedSection], combined: Bool,
                                             provider: MediaServerProvider) -> [ResolvedSection] {
        let projected = HomeSectionPreferences.combinedSections(sections, enabled: combined, provider: provider)
        guard combined, provider.usesNativeUser else { return projected }
        let sources = sections.filter { $0.sectionType == "continue_watching" }
            + sections.filter { $0.sectionType == "next_up" }
        var seen = Set<String>()
        let items = interleaved(sources).filter { seen.insert($0.item.contentId).inserted }.map(\.item)
        return projected.map { row in
            guard row.sectionType == "continue_watching" else { return row }
            return ResolvedSection(id: row.id, sectionType: row.sectionType, title: row.title,
                featured: row.featured, itemLimit: row.itemLimit, totalCount: items.count,
                isCustom: row.isCustom, customized: row.customized, items: items)
        }
    }

    /// Saves a first choice of the first three rows with items, and starts
    /// over when none of the saved rows exists any more. A saved Next Up row
    /// that Home has merged into Continue Watching becomes the combined row.
    func initializeIfNeeded(from sections: [ResolvedSection]) {
        refresh()
        let sources = sourceSections(from: sections)
        let candidates = sources.filter { !$0.items.isEmpty }
        if let selectedRowIDs, sections.contains(where: { $0.sectionType == "next_up" }),
           !sources.contains(where: { $0.sectionType == "next_up" }),
           let combined = sources.first(where: { $0.sectionType == "continue_watching" }) {
            let mergedIDs = Set(sections
                .filter { $0.sectionType == "continue_watching" || $0.sectionType == "next_up" }
                .map(\.id))
            var seen = Set<String>()
            let normalised = selectedRowIDs.map { mergedIDs.contains($0) ? combined.id : $0 }
                .filter { seen.insert($0).inserted }
            if normalised != selectedRowIDs { save(normalised) }
        }
        guard !candidates.isEmpty, storageKey != nil else { return }
        let firstChoice = candidates.prefix(Self.maximumRows).map(\.id)
        guard let selectedRowIDs else {
            save(firstChoice)
            return
        }
        let available = Set(sources.map(\.id))
        if !selectedRowIDs.isEmpty, selectedRowIDs.allSatisfy({ !available.contains($0) }) {
            save(firstChoice)
        }
    }

    /// Adds or removes a row. A fourth row is ignored.
    func toggle(_ rowID: String) {
        refresh()
        var ids = selectedRowIDs ?? []
        if ids.contains(rowID) {
            ids.removeAll { $0 == rowID }
        } else if ids.count < Self.maximumRows {
            ids.append(rowID)
        } else {
            return
        }
        save(ids)
        TVHomeMetadataCache.shared.reconcilePreferences()
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }

    /// Up to ten slides, taking turns between the chosen rows and skipping
    /// items already shown.
    func slides(from sections: [ResolvedSection]) -> [TVHomeSpotlightSlide] {
        let projected = sourceSections(from: sections)
        let ids = selectedRowIDs ?? projected.prefix(Self.maximumRows).map(\.id)
        let nextUpMerged = !projected.contains { $0.sectionType == "next_up" }
        let sources = ids.compactMap { id -> ResolvedSection? in
            if let row = projected.first(where: { $0.id == id }) { return row }
            // A chosen Next Up row now lives in the combined Continue Watching row.
            if nextUpMerged, sections.contains(where: { $0.id == id && $0.sectionType == "next_up" }) {
                return projected.first { $0.sectionType == "continue_watching" }
            }
            return nil
        }
        var seen = Set<String>()
        return Array(Self.interleaved(sources)
            .filter { seen.insert($0.item.contentId).inserted }
            .prefix(Self.maximumSlides)
            .map { TVHomeSpotlightSlide(item: $0.item, rowID: $0.row.id, rowTitle: $0.row.title) })
    }

    /// Each row's first item, then each row's second, and so on.
    nonisolated private static func interleaved(_ rows: [ResolvedSection]) -> [(item: SectionItem, row: ResolvedSection)] {
        let longest = rows.map(\.items.count).max() ?? 0
        return (0..<longest).flatMap { index in
            rows.compactMap { row -> (item: SectionItem, row: ResolvedSection)? in
                row.items.indices.contains(index) ? (row.items[index], row) : nil
            }
        }
    }

    private var storageKey: String? {
        guard let profile = AuthService.shared.profileId, !profile.isEmpty,
              let server = ServerRegistry.shared.activeServerId else { return nil }
        return Self.storageKey(server: server, profile: profile)
    }

    nonisolated private static func storageKey(server: String, profile: String) -> String {
        "tvos.homeSpotlight.v1.\(server).\(profile)"
    }

    /// The saved choice without repeats, at most three rows.
    private static func savedRowIDs(forKey key: String) -> [String]? {
        guard let data = SharedDefaults.shared.data(forKey: key),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        let unique = NSOrderedSet(array: ids).array.compactMap { $0 as? String }
        return Array(unique.prefix(maximumRows))
    }

    private func save(_ ids: [String]) {
        guard let key = storageKey, let data = try? JSONEncoder().encode(ids) else { return }
        defaults.set(data, forKey: key)
        loadedKey = key
        selectedRowIDs = ids
    }
}

struct TVHomeSpotlightSlide: Identifiable, Codable, Equatable {
    let item: SectionItem
    let rowID: String
    let rowTitle: String
    var id: String { item.contentId }

    #if os(tvOS)
    /// The slide's text and artwork, with an episode's series background
    /// once it's known.
    @MainActor var content: TVMarqueeContent {
        TVMarqueeContent(item: item, backdropUrl: HomeSeriesBackdrops.shared.art(for: item).url,
                         rowId: rowID, rowTitle: rowTitle)
    }
    #endif
}

/// Home card captions on this device, for each server and profile. Home
/// posters are always Large; only the caption can be chosen.
@Observable
@MainActor
final class TVHomeCardPreferences {
    static let shared = TVHomeCardPreferences()

    /// Bumped on every change, so readers see it.
    private var revision = 0
    private let defaults = SharedDefaults.shared
    /// Cards read `presentation` many times per body, so it's worked out once
    /// per profile key and revision.
    @ObservationIgnored private var cachedPresentation: (key: String?, revision: Int, value: CardPresentationPreference)?

    private var captionKey: String? {
        guard let server = ServerRegistry.shared.activeServerId,
              let profile = AuthService.shared.profileId else { return nil }
        return "tvos.homeCards.v1.\(server).\(profile).captions"
    }

    /// A poster size saved by an older build, or synced from a device still
    /// running one, is ignored.
    var presentation: CardPresentationPreference {
        let revision = revision
        let key = captionKey
        if let cached = cachedPresentation, cached.key == key, cached.revision == revision {
            return cached.value
        }
        let caption = key.flatMap { defaults.string(forKey: $0) }
            .flatMap(CardCaptionStyle.init(rawValue:)) ?? .titleMetadata
        let value = CardPresentationPreference(posterSize: .large, caption: caption)
        cachedPresentation = (key, revision, value)
        return value
    }

    func cloudPreferencesChanged() { revision += 1 }

    func setCaptionStyle(_ caption: CardCaptionStyle) {
        guard let captionKey else { return }
        defaults.set(caption.rawValue, forKey: captionKey)
        revision += 1
    }

    func reset() {
        guard let captionKey else { return }
        defaults.removeObject(forKey: captionKey)
        revision += 1
    }
}
#endif
