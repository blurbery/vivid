#if os(tvOS) || os(iOS)
import Foundation

@Observable
@MainActor
final class TVHomeSpotlightPreferences {
    static let shared = TVHomeSpotlightPreferences()
    private(set) var selectedRowIDs: [String]?
    private var loadedKey: String?
    private let defaults = SharedDefaults.shared

    init() { refresh() }

    func refresh(force: Bool = false) {
        let key = storageKey
        guard force || key != loadedKey else { return }
        loadedKey = key
        selectedRowIDs = key.flatMap { key in
            defaults.data(forKey: key).flatMap {
                try? JSONDecoder().decode([String].self, from: $0)
            }
        }.map { Array(NSOrderedSet(array: $0).array.compactMap { $0 as? String }.prefix(3)) }
    }

    static func savedRowIDs(server: String, profile: String) -> [String]? {
        let key = "tvos.homeSpotlight.v1.\(server).\(profile)"
        return SharedDefaults.shared.data(forKey: key).flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        }.map { Array(NSOrderedSet(array: $0).array.compactMap { $0 as? String }.prefix(3)) }
    }

    func initializeIfNeeded(from sections: [ResolvedSection]) {
        refresh()
        guard !sections.isEmpty, storageKey != nil else { return }
        if let selectedRowIDs, !selectedRowIDs.isEmpty {
            let available = Set(sections.map(\.id))
            if selectedRowIDs.allSatisfy({ !available.contains($0) }) {
                save(Array(sections.prefix(3).map(\.id)))
                return
            }
        }
        guard selectedRowIDs == nil else { return }
        save(Array(sections.prefix(3).map(\.id)))
    }

    func toggle(_ rowID: String) {
        refresh()
        var ids = selectedRowIDs ?? []
        if ids.contains(rowID) {
            ids.removeAll { $0 == rowID }
        } else if ids.count < 3 {
            ids.append(rowID)
        } else {
            return
        }
        save(ids)
        TVHomeMetadataCache.shared.reconcilePreferences()
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }

    func slides(from sections: [ResolvedSection]) -> [TVHomeSpotlightSlide] {
        let ids = selectedRowIDs ?? Array(sections.prefix(3).map(\.id))
        let sources = ids.compactMap { id in sections.first { $0.id == id } }
        var slides: [TVHomeSpotlightSlide] = []
        var seen = Set<String>()
        let longestRow = sources.map { $0.items.count }.max() ?? 0
        for index in 0..<longestRow {
            for section in sources where section.items.indices.contains(index) {
                let item = section.items[index]
                guard seen.insert(item.contentId).inserted else { continue }
                slides.append(TVHomeSpotlightSlide(item: item, rowID: section.id, rowTitle: section.title))
                if slides.count == 10 { return slides }
            }
        }
        return slides
    }

    private var storageKey: String? {
        guard let profile = AuthService.shared.profileId, !profile.isEmpty,
              let server = ServerRegistry.shared.activeServerId else { return nil }
        return "tvos.homeSpotlight.v1.\(server).\(profile)"
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
    var content: TVMarqueeContent {
        TVMarqueeContent(item: item, rowId: rowID, rowTitle: rowTitle)
    }
    #endif
}
/// Device-local card choices for Home, isolated by server and viewing profile.
@Observable
@MainActor
final class TVHomeCardPreferences {
    static let shared = TVHomeCardPreferences()
    static let profileDefault = CardPresentationPreference(posterSize: .large, caption: .title)
    private var revision = 0
    private let defaults = SharedDefaults.shared
    private var key: String? {
        guard let server = ServerRegistry.shared.activeServerId,
              let profile = AuthService.shared.profileId else { return nil }
        return "tvos.homeCards.v1.\(server).\(profile)"
    }
    var presentation: CardPresentationPreference {
        _ = revision
        var value = Self.profileDefault
        if let key, let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(CardPresentationPreference.self, from: data) {
            value = saved
        }
        value.caption = key.flatMap { defaults.string(forKey: $0 + ".captions") }
            .flatMap(CardCaptionStyle.init(rawValue:)) ?? .titleMetadata
        return value
    }
    func cloudPreferencesChanged() { revision += 1 }
    func setPosterSize(_ size: CardPosterSize) {
        var value = presentation; value.posterSize = size; save(value)
    }
    func setCaptionStyle(_ caption: CardCaptionStyle) {
        guard let key else { return }
        defaults.set(caption.rawValue, forKey: key + ".captions")
        revision += 1
    }
    func reset() {
        if let key { defaults.removeObject(forKey: key + ".captions") }
        save(Self.profileDefault)
    }
    private func save(_ value: CardPresentationPreference) {
        guard let key, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
        revision += 1
    }
}
#endif
