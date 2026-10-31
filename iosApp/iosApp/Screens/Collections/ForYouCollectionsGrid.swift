#if os(iOS)
import SwiftUI

/// The active Silo profile's own collections, for For You. Starts from the
/// cached list so a return visit shows them straight away.
@MainActor @Observable
final class PersonalCollectionsLoader {
    private(set) var collections: [UserCollection] = []
    private(set) var groups: [CollectionGroup] = []
    private(set) var error: ErrorState?

    init() {
        if let cached = ResponseCache.shared.get(CacheKey.collections, as: CollectionsResponse.self) {
            adopt(cached)
        }
    }

    func load() async {
        error = nil
        do {
            let response = try await VividAPI.shared.collections()
            ResponseCache.shared.set(response, for: CacheKey.collections)
            adopt(response)
        } catch {
            if collections.isEmpty && groups.isEmpty { self.error = ErrorState(error) }
        }
    }

    private func adopt(_ response: CollectionsResponse) {
        collections = response.collections ?? []
        groups = response.groups ?? []
    }
}

/// For You's Collections tab: the libraries' collections and, on Silo, the
/// profile's own, grouped into User Collections and Collections.
struct ForYouCollectionsGrid: View {
    /// A collection and the library it belongs to (0 for Emby, Jellyfin and
    /// personal collections).
    private struct Entry: Identifiable {
        let libraryID: Int
        let collection: LibraryCollection
        var id: String { "\((collection.kind ?? .regular).rawValue):\(collection.id)" }
    }

    private struct Section: Identifiable {
        let kind: LibraryCollectionKind
        let title: LocalizedStringKey
        let entries: [Entry]
        var id: String { kind.rawValue }
    }

    let filter: PersonalListFilter

    @State private var personal = PersonalCollectionsLoader()
    @State private var entries: [Entry] = []
    @State private var isLoading = true
    @State private var error: ErrorState?
    /// Emby and Jellyfin loads: the newest started, and the newest on screen.
    @State private var latestNativeLoad = 0
    @State private var shownNativeLoad = 0
    @State private var gridWidth: CGFloat = 0
    @Environment(\.forYouPageTabs) private var pageTabs
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let spacing: CGFloat = 12

    var body: some View {
        let sections = visibleSections
        let activeFilter = filter.limited(to: .collections)
        ScrollView {
            pageTabs
            LazyVStack(spacing: 24) {
                ForEach(sections) { section in
                    sectionView(section)
                }
                if isLoading {
                    ProgressView().tint(.white)
                }
                if let error {
                    ErrorView(state: error, onRetry: { Task { await load() } })
                } else if !isLoading && sections.isEmpty {
                    if activeFilter.isActive {
                        EmptyStateView(icon: "line.3.horizontal.decrease", title: "No collections match these filters")
                    } else {
                        EmptyStateView(icon: "square.stack", title: "No collections", subtitle: "Your collections will appear here.")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .padding(16)
        }
        .reportsPageChromeScroll()
        .vividBackground()
        .refreshable { await load() }
        .task { await load() }
    }

    private func sectionView(_ section: Section) -> some View {
        let columns = columnCount
        let cardWidth = cardWidth(columns: columns)
        return VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .tracking(12 * 0.26)
                .textCase(.uppercase)
                .foregroundStyle(Color.vividOnSurface.opacity(0.38))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: 16) {
                ForEach(section.entries) { entry in
                    NavigationLink(value: Route.libraryCollection(
                        libraryId: entry.libraryID,
                        collectionId: entry.collection.id,
                        title: entry.collection.name,
                        kind: entry.collection.kind ?? section.kind
                    )) {
                        ForYouCollectionCard(collection: entry.collection, width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(libraryCollectionAccessibilityLabel(entry.collection))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: What shows

    private var visibleSections: [Section] {
        let activeFilter = filter.limited(to: .collections)
        let profileID = ServerRegistry.shared.activeProfileId
        let personalIDs = Set(personal.collections.map(\.id))

        var shown: [Entry] = []
        if MediaServerProvider.active == .silo, activeFilter.source == .all || activeFilter.source == .mine {
            shown += personal.collections.map {
                Entry(
                    libraryID: HomeCollection.personalLibraryID,
                    collection: LibraryCollection(personal: $0, profileID: profileID)
                )
            }
        }
        shown += entries.filter { entry in
            let kind = entry.collection.kind ?? .regular
            if kind == .userCollections && personalIDs.contains(entry.collection.id) { return false }
            return activeFilter.matchesCollection(
                kind: kind,
                creatorProfileID: entry.collection.creatorProfileId,
                activeProfileID: profileID
            )
        }

        let ordered: (Entry, Entry) -> Bool = { lhs, rhs in
            switch TitleSortOrder.compare(lhs.collection.name, rhs.collection.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.collection.id < rhs.collection.id
            }
        }
        let layout: [(LibraryCollectionKind, LocalizedStringKey)] = [
            (.userCollections, "User Collections"),
            (.regular, "Collections"),
        ]
        return layout.compactMap { kind, title in
            let members = shown.filter { ($0.collection.kind ?? .regular) == kind }.sorted(by: ordered)
            return members.isEmpty ? nil : Section(kind: kind, title: title, entries: members)
        }
    }

    private var usesDuoWideLayout: Bool { PhoneDuo.usesWideLayout(horizontalSizeClass) }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var columnCount: Int {
        if usesDuoWideLayout { return AdaptiveColumns.duoPosterCount(containerWidth: gridWidth, spacing: spacing) }
        if isPad { return AdaptiveColumns.tabletPosterCount(containerWidth: gridWidth, spacing: spacing) }
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        return horizontalSizeClass == .regular && !isPhone ? 5 : 3
    }

    private func cardWidth(columns: Int) -> CGFloat {
        if usesDuoWideLayout { return AdaptiveColumns.duoPosterWidth(containerWidth: gridWidth, spacing: spacing) }
        if isPad { return AdaptiveColumns.tabletPosterWidth(containerWidth: gridWidth, spacing: spacing) }
        return AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth, columnCount: columns, spacing: spacing, maximumWidth: nil
        )
    }

    // MARK: Loading

    private func load() async {
        if MediaServerProvider.active.usesNativeUser {
            await loadNativeCollections()
        } else {
            await loadSiloCollections()
        }
    }

    /// Emby and Jellyfin answer with every box set in one list.
    private func loadNativeCollections() async {
        isLoading = true
        error = nil
        // Supplies the item counts Emby leaves out of its list.
        Task { await HomeCollectionsStore.shared.loadIfNeeded() }
        latestNativeLoad += 1
        let load = latestNativeLoad
        defer { if load == latestNativeLoad { isLoading = false } }

        if let cached = ResponseCache.shared.get(CacheKey.nativeCollections, as: [LibraryCollection].self) {
            entries = cached.map { Entry(libraryID: 0, collection: $0) }
            isLoading = false
        }
        do {
            let response: LibraryCollectionsWireResponse = try await HTTPClient.shared.get("/api/v1/collections")
            guard load > shownNativeLoad else { return }
            shownNativeLoad = load
            ResponseCache.shared.set(response.collections, for: CacheKey.nativeCollections)
            entries = response.collections.map { Entry(libraryID: 0, collection: $0) }
            error = nil
        } catch {
            if load == latestNativeLoad, shownNativeLoad < load, entries.isEmpty {
                self.error = ErrorState(error)
            }
        }
    }

    /// Silo: each movie, series and mixed library's collections, fetched
    /// together, alongside the profile's own collections.
    private func loadSiloCollections() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        async let personalLoad: Void = personal.load()

        let libraries: [Library]
        do {
            libraries = try await StartupContentPrefetcher.fetchUserLibraries().libraries
                .filter { $0.isMovieLibrary || $0.isSeriesLibrary || $0.isMixedLibrary }
        } catch {
            await personalLoad
            if entries.isEmpty && personal.collections.isEmpty {
                self.error = ErrorState(error)
            } else {
                self.error = nil
            }
            return
        }

        var sectionsByLibrary: [Int: [LibraryCollectionSection]] = [:]
        for library in libraries {
            if let cached = ResponseCache.shared.get(Self.cacheKey(library.id), as: [LibraryCollectionSection].self) {
                sectionsByLibrary[library.id] = cached
            }
        }
        publish(libraries: libraries, sections: sectionsByLibrary)

        var firstFailure: Error?
        await withTaskGroup(of: (Int, Result<[LibraryCollectionSection], Error>).self) { group in
            for library in libraries {
                let id = library.id
                group.addTask {
                    do {
                        return (id, .success(try await VividAPI.shared.visibleLibraryCollections(libraryId: id).resolvedSections))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                guard !Task.isCancelled else { continue }
                switch result {
                case .success(let sections):
                    sectionsByLibrary[id] = sections
                    ResponseCache.shared.set(sections, for: Self.cacheKey(id))
                    publish(libraries: libraries, sections: sectionsByLibrary)
                case .failure(let failure):
                    if firstFailure == nil { firstFailure = failure }
                }
            }
        }

        await personalLoad
        if entries.isEmpty && personal.collections.isEmpty {
            error = firstFailure.map { ErrorState($0) } ?? personal.error
        } else {
            error = nil
        }
    }

    /// Libraries in order, then their sections and collections in order; the
    /// first copy of a collection wins.
    private func publish(libraries: [Library], sections: [Int: [LibraryCollectionSection]]) {
        var seen = Set<String>()
        var published: [Entry] = []
        for library in libraries {
            for section in sections[library.id] ?? [] {
                for collection in section.collections {
                    let entry = Entry(libraryID: library.id, collection: collection)
                    if seen.insert(entry.id).inserted { published.append(entry) }
                }
            }
        }
        entries = published
    }

    private static func cacheKey(_ libraryID: Int) -> String { "library:\(libraryID):collections" }
}

/// A collection's poster with its title count badge, sized like a poster card.
private struct ForYouCollectionCard: View {
    let collection: LibraryCollection
    let width: CGFloat

    private var height: CGFloat { width * VividTheme.posterCardHeight / VividTheme.posterCardWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                poster
                if let badge = libraryCollectionCountBadge(collection) {
                    Text(badge)
                        .font(.vividSmall)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                        .padding(8)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius))

            if UICustomizationPreferences.shared.cardPresentation.caption.showsTitle {
                Text(collection.name)
                    .homePosterTitleStyle()
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private var poster: some View {
        if let url = collection.posterUrl, !url.isEmpty {
            AsyncImageView(
                url: url,
                thumbhash: collection.posterThumbhash,
                targetSize: CGSize(width: width, height: height),
                contentMode: .fill
            )
            .frame(width: width, height: height)
            .clipped()
        } else {
            ZStack {
                Color.vividSurfaceVariant
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.vividSecondaryText)
            }
            .frame(width: width, height: height)
        }
    }
}
#endif
