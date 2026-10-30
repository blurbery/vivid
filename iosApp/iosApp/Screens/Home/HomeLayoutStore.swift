import Foundation
import Observation

extension Notification.Name {
    /// Asks a visible Home to fetch its rows again.
    static let homeSectionsShouldRefresh = Notification.Name("homeSectionsShouldRefresh")
}

/// Which Home rows show, in what order, and whether Continue Watching and
/// Next Up merge, kept per server and profile in the app-group defaults.
@Observable @MainActor
final class HomeSectionPreferences {
    static let shared = HomeSectionPreferences()
    static let maximumVisibleRows = 6

    private(set) var orderedSectionIds: [String] = []
    private(set) var hiddenSectionIds: Set<String> = []
    private(set) var layoutRevision = 0
    private(set) var combineEmbyNextUp = false
    private(set) var combineJellyfinNextUp = false

    private let defaults: SharedDefaults
    private let storageKey: @MainActor () -> String?
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var knownBytes: Data?
    @ObservationIgnored private var rememberedRows: [ResolvedSection] = []
    @ObservationIgnored private var seenSectionIds: Set<String> = []
    @ObservationIgnored private var owesSave = false

    init(
        defaults: SharedDefaults = .shared,
        storageKey: @escaping @MainActor () -> String? = {
            guard let profile = AuthService.shared.profileId, !profile.isEmpty else { return nil }
            let server = ServerRegistry.shared.activeServerId ?? "default"
            return "tvos.homeSections.v1.\(server).\(profile)"
        }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        refresh()
    }

    // MARK: Reading

    var visibleRowCount: Int {
        arrangedSections(rememberedRows, includingHidden: true)
            .filter { !hiddenSectionIds.contains($0.id) }
            .count
    }

    func isVisible(_ sectionId: String) -> Bool {
        !hiddenSectionIds.contains(sectionId)
    }

    func refresh(force: Bool = false) {
        let key = storageKey()
        guard force || key != loadedKey else { return }
        loadedKey = key
        rememberedRows = []
        apply(key.flatMap { defaults.data(forKey: $0) })
    }

    func arrangedSections(_ sections: [ResolvedSection], includingHidden: Bool = false) -> [ResolvedSection] {
        let provider = MediaServerProvider.active
        let combines = provider == .jellyfin ? combineJellyfinNextUp : combineEmbyNextUp
        let kept = Self.combinedSections(sections, enabled: combines, provider: provider).filter { section in
            guard includingHidden || !section.items.isEmpty else { return false }
            guard provider == .emby else { return true }
            return !EmbyAdapter.excludesHomeRow(id: section.id, type: section.sectionType, title: section.title)
        }

        var position: [String: Int] = [:]
        for (index, id) in orderedSectionIds.enumerated() where position[id] == nil {
            position[id] = index
        }
        let placed = kept.enumerated()
            .compactMap { offset, section in position[section.id].map { (rank: $0, offset: offset, section: section) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.section)
        let arranged = placed + kept.filter { position[$0.id] == nil }

        guard !includingHidden else { return arranged }
        return Array(arranged.filter { !hiddenSectionIds.contains($0.id) }.prefix(Self.maximumVisibleRows))
    }

    // MARK: The six-row limit

    func enforceVisibleRowLimit(in sections: [ResolvedSection], provider: MediaServerProvider = .active) {
        refresh()
        pickUpOutsideChanges()
        rememberedRows = sections

        let arranged = arrangedSections(sections, includingHidden: true)
        var hidden = hiddenSectionIds
        let seenVisible = arranged.filter { seenSectionIds.contains($0.id) && !hidden.contains($0.id) }.count
        var room = max(0, Self.maximumVisibleRows - seenVisible)
        var hidRows = false
        for section in arranged where !seenSectionIds.contains(section.id) && !hidden.contains(section.id) {
            if room > 0 {
                room -= 1
            } else {
                hidden.insert(section.id)
                hidRows = true
            }
        }

        var order = orderedSectionIds
        var orderGrew = false
        if provider == .silo {
            var ordered = Set(order)
            for section in arranged where ordered.insert(section.id).inserted {
                order.append(section.id)
                orderGrew = true
            }
        }

        let seen = seenSectionIds.union(arranged.map(\.id))
        let sawNewRows = seen.count != seenSectionIds.count
        let wasOwed = owesSave
        seenSectionIds = seen
        owesSave = false
        if hidRows {
            hiddenSectionIds = hidden
            layoutRevision &+= 1
        }
        if orderGrew {
            orderedSectionIds = order
            layoutRevision &+= 1
        }
        if sawNewRows || hidRows || orderGrew || wasOwed {
            save()
        }
    }

    // MARK: Editing

    func setVisible(_ visible: Bool, sectionId: String) {
        let isHidden = hiddenSectionIds.contains(sectionId)
        if visible, isHidden, visibleRowCount >= Self.maximumVisibleRows { return }
        guard isHidden == visible else { return }
        if visible {
            hiddenSectionIds.remove(sectionId)
        } else {
            hiddenSectionIds.insert(sectionId)
        }
        layoutRevision &+= 1
        save()
        if !visible {
            TVHomeMetadataCache.shared.clear(sectionId)
        }
        TVHomeMetadataCache.shared.reconcilePreferences()
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }

    func setOrder(_ sectionIds: [String]) {
        var listed = Set<String>()
        let leading = sectionIds.filter { listed.insert($0).inserted }
        let order = leading + orderedSectionIds.filter { !listed.contains($0) }
        guard order != orderedSectionIds else { return }
        orderedSectionIds = order
        layoutRevision &+= 1
        save()
    }

    func setCombineEmbyNextUp(_ enabled: Bool) {
        setCombined(enabled, for: .emby)
    }

    func setCombineJellyfinNextUp(_ enabled: Bool) {
        setCombined(enabled, for: .jellyfin)
    }

    private func setCombined(_ enabled: Bool, for provider: MediaServerProvider) {
        guard MediaServerProvider.active == provider else { return }
        refresh()
        let current = provider == .jellyfin ? combineJellyfinNextUp : combineEmbyNextUp
        guard current != enabled else { return }
        if provider == .jellyfin {
            combineJellyfinNextUp = enabled
        } else {
            combineEmbyNextUp = enabled
        }

        enforceVisibleRowLimit(in: rememberedRows)
        // Only visible rows count towards the limit; rows already hidden stay as they are.
        var hidden = hiddenSectionIds
        var visibleCount = 0
        for section in arrangedSections(rememberedRows, includingHidden: true)
        where !hiddenSectionIds.contains(section.id) {
            if visibleCount >= Self.maximumVisibleRows {
                hidden.insert(section.id)
            } else {
                visibleCount += 1
            }
        }
        if hidden != hiddenSectionIds {
            hiddenSectionIds = hidden
        }
        layoutRevision &+= 1
        save()
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }

    // MARK: Reads for other servers and profiles

    static func hiddenSections(server: String, profile: String) -> Set<String> {
        guard let layout = storedLayout(server: server, profile: profile), layout.seenSectionIds != nil else { return [] }
        return Set(layout.hiddenSectionIds ?? [])
    }

    static func combinesEmbyNextUp(server: String, profile: String) -> Bool {
        storedLayout(server: server, profile: profile)?.combineEmbyNextUp ?? false
    }

    private static func storedLayout(server: String, profile: String) -> StoredLayout? {
        SharedDefaults.shared.data(forKey: "tvos.homeSections.v1.\(server).\(profile)").flatMap(StoredLayout.decode)
    }

    // MARK: Merging Continue Watching and Next Up

    nonisolated static func combinedSections(
        _ sections: [ResolvedSection],
        enabled: Bool,
        provider: MediaServerProvider
    ) -> [ResolvedSection] {
        guard enabled, provider == .emby || provider == .jellyfin else { return sections }
        var firstResume: Int?
        var firstNextUp: Int?
        for (index, section) in sections.enumerated() {
            if section.sectionType == "continue_watching", firstResume == nil { firstResume = index }
            if section.sectionType == "next_up", firstNextUp == nil { firstNextUp = index }
        }
        guard let anchorIndex = firstResume ?? firstNextUp else { return sections }

        var seen = Set<String>()
        var items: [SectionItem] = []
        for kind in ["continue_watching", "next_up"] {
            for section in sections where section.sectionType == kind {
                for item in section.items where seen.insert(item.contentId).inserted {
                    items.append(item)
                }
            }
        }

        let anchor = sections[anchorIndex]
        let merged = ResolvedSection(
            id: firstResume.map { sections[$0].id } ?? "continue_watching",
            sectionType: "continue_watching",
            title: String(localized: "Continue Watching"),
            featured: false,
            itemLimit: nil,
            totalCount: items.count,
            isCustom: anchor.isCustom,
            customized: anchor.customized,
            items: items
        )

        var result: [ResolvedSection] = []
        result.reserveCapacity(sections.count)
        for (index, section) in sections.enumerated() {
            if index == anchorIndex {
                result.append(merged)
            } else if section.sectionType != "continue_watching", section.sectionType != "next_up" {
                result.append(section)
            }
        }
        return result
    }

    // MARK: Storage

    private var layoutValues: LayoutValues {
        LayoutValues(
            order: orderedSectionIds,
            hidden: hiddenSectionIds,
            seen: seenSectionIds,
            combinesEmby: combineEmbyNextUp,
            combinesJellyfin: combineJellyfinNextUp
        )
    }

    /// Applies a value stored elsewhere since it was last read or written.
    /// A value that changes nothing doesn't count as a revision.
    private func pickUpOutsideChanges() {
        guard let key = loadedKey else { return }
        let stored = defaults.data(forKey: key)
        guard stored != knownBytes else { return }
        let before = layoutValues
        let revision = layoutRevision
        apply(stored)
        if layoutValues == before {
            layoutRevision = revision
        }
    }

    private func apply(_ data: Data?) {
        if let layout = data.flatMap(StoredLayout.decode),
           let order = layout.orderedSectionIds,
           let hidden = layout.hiddenSectionIds {
            var listed = Set<String>()
            orderedSectionIds = order.filter { listed.insert($0).inserted }
            combineEmbyNextUp = layout.combineEmbyNextUp ?? false
            combineJellyfinNextUp = layout.combineJellyfinNextUp ?? false
            if let seen = layout.seenSectionIds {
                hiddenSectionIds = Set(hidden)
                seenSectionIds = Set(seen)
                owesSave = false
            } else {
                // Saved before rows were tracked as seen: its hidden rows
                // can't be trusted, so start over and save the new form.
                hiddenSectionIds = []
                seenSectionIds = []
                owesSave = true
            }
        } else {
            orderedSectionIds = []
            hiddenSectionIds = []
            seenSectionIds = []
            combineEmbyNextUp = false
            combineJellyfinNextUp = false
            owesSave = false
        }
        knownBytes = data
        layoutRevision &+= 1
    }

    private func save() {
        guard let key = storageKey() else { return }
        loadedKey = key
        let layout = SavedLayout(
            orderedSectionIds: orderedSectionIds,
            hiddenSectionIds: hiddenSectionIds.sorted(),
            combineEmbyNextUp: combineEmbyNextUp,
            combineJellyfinNextUp: combineJellyfinNextUp,
            seenSectionIds: seenSectionIds.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(layout) else { return }
        owesSave = false
        knownBytes = data
        // Identical bytes are never rewritten, so iCloud sync stays quiet.
        if defaults.data(forKey: key) != data {
            defaults.set(data, forKey: key)
        }
    }
}

private struct LayoutValues: Equatable {
    let order: [String]
    let hidden: Set<String>
    let seen: Set<String>
    let combinesEmby: Bool
    let combinesJellyfin: Bool
}

/// The stored layout as read: every key may be missing.
private struct StoredLayout: Decodable {
    let orderedSectionIds: [String]?
    let hiddenSectionIds: [String]?
    let combineEmbyNextUp: Bool?
    let combineJellyfinNextUp: Bool?
    let seenSectionIds: [String]?

    static func decode(_ data: Data) -> StoredLayout? {
        guard let layout = try? JSONDecoder().decode(StoredLayout.self, from: data),
              layout.orderedSectionIds != nil, layout.hiddenSectionIds != nil else { return nil }
        return layout
    }
}

/// The stored layout as written: all five keys, always.
private struct SavedLayout: Encodable {
    let orderedSectionIds: [String]
    let hiddenSectionIds: [String]
    let combineEmbyNextUp: Bool
    let combineJellyfinNextUp: Bool
    let seenSectionIds: [String]
}

extension ResolvedSection {
    var isContinueWatchingSection: Bool {
        let type = sectionType.lowercased()
        return type == "continue_watching" || type == "in_progress"
    }

    #if os(tvOS)
    var tvHomeUsesLandscapeArtwork: Bool {
        if isContinueWatchingSection || sectionType.lowercased().contains("next") { return true }
        return MediaServerProvider.active != .jellyfin
            && items.contains { $0.type.lowercased() == "episode" }
    }
    #endif
}
