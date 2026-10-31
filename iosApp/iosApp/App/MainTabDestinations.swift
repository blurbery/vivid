import Foundation

/// One tab of the iPhone and iPad tab bar: an app page, or a Movies or
/// Series page over the matching libraries.
enum MainTabDestinationID: Hashable {
    case app(AppTab)
    case libraryCategory(PrimaryMenuBuiltin)
}

struct MainTabDestination: Identifiable, Equatable {
    let id: MainTabDestinationID
    let title: String
    let icon: String
    let selectedIcon: String

    static func app(_ tab: AppTab) -> MainTabDestination {
        MainTabDestination(id: .app(tab), title: tab.title, icon: tab.icon, selectedIcon: tab.selectedIcon)
    }

    static func libraryCategory(_ category: PrimaryMenuBuiltin) -> MainTabDestination {
        MainTabDestination(
            id: .libraryCategory(category), title: category.title,
            icon: category.navigationIcon, selectedIcon: category.navigationIcon
        )
    }
}

/// The tabs a top menu gives on iPhone and iPad. Movies and Series need a
/// matching library; libraries, sections and collections never become tabs.
func projectedMainTabDestinations(primaryMenu: PrimaryMenuPreference?, availableLibraries: [Library] = []) -> [MainTabDestination] {
    guard let primaryMenu else { return AppTab.visibleCases.map(MainTabDestination.app) }

    var items = primaryMenu.items
    if items.count == 1, items[0].isHome {
        items = appleDefaultPrimaryMenuItems()
    }

    var destinations: [MainTabDestination] = []
    for item in items where mainTabSupportsDestination(item, availableLibraries: availableLibraries) {
        let destination: MainTabDestination
        switch item {
        case .builtin(.home): destination = .app(.home)
        case .builtin(.movies): destination = .libraryCategory(.movies)
        case .builtin(.series): destination = .libraryCategory(.series)
        case .builtin(.forYou): destination = .app(.recommendations)
        case .library, .section, .collection: continue
        }
        if !destinations.contains(where: { $0.id == destination.id }) {
            destinations.append(destination)
        }
    }

    if !destinations.contains(where: { $0.id == .app(.home) }) {
        destinations.insert(.app(.home), at: 0)
    }

    // A menu that came down to Home alone still offers the usual tabs.
    guard destinations.map(\.id) == [.app(.home)] else { return destinations }
    var fallback: [MainTabDestination] = [.app(.home)]
    if availableLibraries.contains(where: { libraryMatchesPrimaryMenuCategory($0, category: .movies) }) {
        fallback.append(.libraryCategory(.movies))
    }
    if availableLibraries.contains(where: { libraryMatchesPrimaryMenuCategory($0, category: .series) }) {
        fallback.append(.libraryCategory(.series))
    }
    fallback.append(.app(.recommendations))
    return fallback
}

func mainTabSupportsDestination(_ item: PrimaryMenuItem, availableLibraries: [Library]) -> Bool {
    switch item {
    case .builtin(.movies):
        availableLibraries.contains { libraryMatchesPrimaryMenuCategory($0, category: .movies) }
    case .builtin(.series):
        availableLibraries.contains { libraryMatchesPrimaryMenuCategory($0, category: .series) }
    case .builtin(.home), .builtin(.forYou):
        true
    case .library, .section, .collection:
        false
    }
}

/// The requested tab when it's showing, otherwise Home.
func resolvedVisibleMainTabDestination(
    _ requestedDestination: MainTabDestinationID,
    visibleDestinations: [MainTabDestination]
) -> MainTabDestinationID {
    visibleDestinations.contains { $0.id == requestedDestination } ? requestedDestination : .app(.home)
}

/// A request for Libraries opens the first Movies or Series tab when the
/// bar has no Libraries tab of its own.
func resolvedRequestedMainTabDestination(
    _ requestedTab: AppTab,
    visibleDestinations: [MainTabDestination]
) -> MainTabDestinationID {
    if requestedTab == .libraries, !visibleDestinations.contains(where: { $0.id == .app(.libraries) }),
       let category = visibleDestinations.first(where: {
           if case .libraryCategory = $0.id { return true }
           return false
       }) {
        return category.id
    }
    return resolvedVisibleMainTabDestination(.app(requestedTab), visibleDestinations: visibleDestinations)
}

/// The server and profile a set of libraries belongs to.
struct MainTabLibraryAuthority: Hashable {
    let serverId: String
    let profileId: String

    init?(serverId: String?, profileId: String?) {
        guard let serverId, !serverId.isEmpty, let profileId, !profileId.isEmpty else { return nil }
        self.serverId = serverId
        self.profileId = profileId
    }
}

/// Libraries remembered for one server and profile, so another profile's
/// libraries never decide which tabs show.
struct MainTabLibrarySnapshot: Equatable {
    let authority: MainTabLibraryAuthority?
    let libraries: [Library]

    init(authority: MainTabLibraryAuthority?, libraries: [Library]) {
        self.authority = authority
        self.libraries = libraries
    }

    func availableLibraries(for currentAuthority: MainTabLibraryAuthority?) -> [Library] {
        guard let currentAuthority, currentAuthority == authority else { return [] }
        return libraries
    }

    @MainActor
    static func cachedForCurrentAuthority() -> Self {
        let registry = ServerRegistry.shared
        let cached = ResponseCache.shared.get(CacheKey.userLibraries, as: LibrariesResponse.self)
        return MainTabLibrarySnapshot(
            authority: MainTabLibraryAuthority(serverId: registry.activeServerId, profileId: registry.activeProfileId),
            libraries: cached?.libraries ?? []
        )
    }
}
