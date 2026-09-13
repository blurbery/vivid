#if os(tvOS)
import SwiftUI

/// `Collections` pill content of a library tab: a vertical grid of every
/// collection in the scoped library (Skyline §6.3). Pressing a card pushes
/// the existing collection detail screen.
struct TVLibraryCollectionsView: View {
    @Environment(\.forYouScrollHeader) private var scrollHeader
    let library: Library?
    var combinedLibraries: [Library] = []
    var namePrefix: String? = nil
    var suppressesEdgeShading = false
    var topContentInset: CGFloat = VividTheme.Skyline.libraryContentTopInset
    var fixedColumnCount: Int? = nil
    @State private var availableWidth: CGFloat = 1760
    @State private var visibleCollectionKeys: Set<String> = []
    @State private var lastFocusedCollectionKey: String?
    @State private var artworkWindow = TVPosterArtworkWindow()
    @Environment(\.displayScale) private var displayScale

    private var flatCollections: [LibraryCollection] { displayedSections.flatMap(\.collections) }
    private var flatCollectionKeys: [String] {
        displayedSections.flatMap { section in section.collections.map { collectionKey($0, kind: section.kind) } }
    }
    private var artworkRange: Range<Int> {
        let first = flatCollectionKeys.firstIndex { visibleCollectionKeys.contains($0) } ?? 0
        return TVPosterArtworkWindow.range(
            firstVisible: first,
            focusedIndex: flatCollectionKeys.firstIndex { $0 == lastFocusedCollectionKey },
            itemCount: flatCollections.count,
            columns: resolvedColumnCount
        )
    }
    private var retainedCollectionKeys: Set<String> {
        Set(flatCollectionKeys[artworkRange])
    }
    private var artworkEntries: [TVPosterArtworkEntry] {
        guard let columns = fixedColumnCount else { return [] }
        let width = max(1, (availableWidth - CGFloat(columns - 1) * VividTheme.Skyline.collectionGridColumnSpacing) / CGFloat(columns)) * displayScale
        return flatCollections[artworkRange].compactMap {
            guard let raw = $0.posterUrl, let url = URL(string: raw) else { return nil }
            return TVPosterArtworkEntry(url: url, size: CGSize(width: width, height: width * 1.5))
        }
    }

    private struct CachedCollections {
        let sections: [LibraryCollectionSection]
        let libraryIds: [String: Int]
    }
    private var cacheKey: String {
        "personal:tvCollections:\(library == nil ? "combined" : "library"):\(sourceLibraries.map { String($0.id) }.joined(separator: ","))"
    }
    /// Focus hand-down token from the shell — claims the first card on
    /// tab entry when this pill is the restored destination.
    var focusRequest: Int = 0
    /// Whether the top menu currently holds focus; deferred entry claims
    /// are dropped while the user is up in the menu.
    var isTopMenuFocused: Bool = false
    /// Boundary hand-up toward the pill row for the first visual grid row.
    let onMoveUp: (() -> Void)?

    @State private var collectionSections: [LibraryCollectionSection] = []
    private var displayedSections: [LibraryCollectionSection] {
        guard let namePrefix else { return collectionSections }
        return collectionSections.compactMap { section in
            let matching = section.collections.filter { collection in
                let title = collection.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if namePrefix == "#" {
                    guard let first = title.unicodeScalars.first else { return false }
                    return !(65...90).contains(Int(first.value))
                }
                return title.hasPrefix(namePrefix)
            }
            guard !matching.isEmpty else { return nil }
            return LibraryCollectionSection(id: section.id, name: section.name, kind: section.kind, collections: matching)
        }
    }

    @State private var isLoadingCollections = true
    @State private var collectionsError: ErrorState?
    @State private var collectionLibraryIds: [String: Int] = [:]
    @State private var uiCustomization = UICustomizationPreferences.shared

    @State private var hasPendingFocusClaim = false
    @State private var lastShellFocusRequest = 0
    @State private var contentFocusToken = 0
    @FocusState private var isEmptyContentFocused: Bool

    @Environment(AppRouter.self) private var router
    @Namespace private var collectionsFocusNamespace

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            scrollHeader
            LazyVStack(spacing: 44, pinnedViews: []) {
                Color.clear
                    .frame(height: topContentInset)

                gridContent
            }
            .padding(.bottom, VividTheme.largePadding)
        }
        .contentMargins(.top, 28, for: .scrollContent)
        .scrollClipDisabled()
        .modifier(TVPersonalScrollAppearance(enabled: suppressesEdgeShading))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: artworkEntries) { _, entries in artworkWindow.update(entries) }
        .onAppear { artworkWindow.update(artworkEntries) }
        .onDisappear { artworkWindow.clear() }
        .onGeometryChange(for: CGFloat.self) { max(1, $0.size.width - 2 * VividTheme.safePadding) } action: { availableWidth = $0 }
        .task(id: sourceLibraries.map(\.id)) {
            await loadCollections()
        }
        .onAppear { noteShellFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in noteShellFocusRequest(request) }
        .onChange(of: displayedSections.isEmpty) { _, isEmpty in
            if !isEmpty, hasPendingFocusClaim {
                claimContentFocusIfReady()
            }
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if displayedSections.isEmpty {
            emptyContent
        } else {
            // Only the very first card of the first NON-EMPTY section
            // claims default focus when the tab appears. Skipping empty
            // sections matters: grouped responses can include groups with
            // no collections, and falling back to `collectionSections.first`
            // would leave the Collections pill without an initial focus
            // target on tvOS.
            let focusTarget = displayedSections
                .first(where: { !$0.collections.isEmpty })
            let firstSectionId = focusTarget?.id
            let firstCardId = focusTarget?.collections.first?.id
            let residentKeys = retainedCollectionKeys
            let firstVisualRowIds = Set(
                focusTarget?.collections.prefix(resolvedColumnCount).map(\.id) ?? []
            )

            VStack(alignment: .leading, spacing: 44) {
                ForEach(displayedSections) { section in
                    VStack(alignment: .leading, spacing: 20) {
                        if !section.name.isEmpty {
                            // §6.3 mono group header — same grammar as the
                            // cascade/dropdown section headers, at grid scale.
                            Text(section.name.uppercased())
                                .font(.system(
                                    size: VividTheme.Skyline.collectionGridGroupHeaderSize,
                                    design: .monospaced
                                ))
                                .tracking(VividTheme.Skyline.collectionGridGroupHeaderSize * 0.26)
                                .foregroundColor(.vividOnSurface.opacity(0.38))
                                .lineLimit(1)
                                .padding(.leading, VividTheme.safePadding)
                        }
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(
                                    .flexible(),
                                    spacing: VividTheme.Skyline.collectionGridColumnSpacing,
                                    alignment: .top
                                ),
                                count: resolvedColumnCount
                            ),
                            alignment: .leading,
                            spacing: VividTheme.Skyline.collectionGridRowSpacing
                        ) {
                            ForEach(section.collections) { collection in
                                let isFirstOverall =
                                    section.id == firstSectionId && collection.id == firstCardId
                                let isInFirstVisualRow =
                                    section.id == firstSectionId
                                    && firstVisualRowIds.contains(collection.id)
                                TVCollectionCard(
                                    collection: collection,
                                    cardWidth: fixedColumnCount.map {
                                        max(1, (availableWidth - CGFloat($0 - 1) * VividTheme.Skyline.collectionGridColumnSpacing) / CGFloat($0))
                                            / uiCustomization.cardPresentation.posterSize.scale
                                    } ?? VividTheme.posterCardWidth,
                                    loadsArtwork: fixedColumnCount == nil || residentKeys.contains(collectionKey(collection, kind: section.kind)),
                                    prefersDefaultFocus: isFirstOverall,
                                    defaultFocusNamespace: collectionsFocusNamespace,
                                    focusRequest: isFirstOverall ? contentFocusToken : 0,
                                    onMoveUp: isInFirstVisualRow ? onMoveUp : nil,
                                    onFocused: { lastFocusedCollectionKey = collectionKey(collection, kind: section.kind) },
                                    action: {
                                        guard let sourceId = collectionLibraryIds[collectionKey(collection, kind: section.kind)] ?? library?.id else { return }
                                        router.navigate(to: .libraryCollection(
                                            libraryId: sourceId,
                                            collectionId: collection.id,
                                            title: collection.name,
                                            kind: collection.kind ?? section.kind
                                        ))
                                    }
                                )
                                .frame(maxWidth: .infinity)
                                .onScrollVisibilityChange(threshold: 0.01) { visible in
                                    let key = collectionKey(collection, kind: section.kind)
                                    if visible { visibleCollectionKeys.insert(key) } else { visibleCollectionKeys.remove(key) }
                                }
                            }
                        }
                        .padding(.horizontal, VividTheme.safePadding)
                    }
                }
            }
            .focusScope(collectionsFocusNamespace)
            .focusSection()
        }
    }

    private var emptyContent: some View {
        ZStack {
            if isLoadingCollections {
                Color.clear
            } else if let collectionsError {
                ErrorView(state: collectionsError, onRetry: { Task { await loadCollections() } })
            } else {
                EmptyStateView(
                    icon: "square.stack",
                    title: namePrefix == nil ? "No collections yet" : "No collections starting with \(namePrefix!)",
                    subtitle: namePrefix == nil ? "Collections created on the server will appear here." : "Choose another letter or All."
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .contentShape(Rectangle())
        .focusable(true)
        .focused($isEmptyContentFocused)
        .focusEffectDisabled()
        .accessibilityLabel(isLoadingCollections ? "Loading collections" : "No collections yet")
        .onMoveCommand { direction in
            if direction == .up {
                onMoveUp?()
            }
        }
        .task(id: focusRequest) {
            guard !isTopMenuFocused else { return }
            await Task.yield()
            guard displayedSections.isEmpty, !isTopMenuFocused else { return }
            isEmptyContentFocused = true
        }
    }

    // MARK: - Focus hand-down

    private func noteShellFocusRequest(_ request: Int) {
        guard request > 0, request != lastShellFocusRequest else { return }
        lastShellFocusRequest = request
        claimContentFocusIfReady()
    }

    private func claimContentFocusIfReady() {
        guard displayedSections.contains(where: { !$0.collections.isEmpty }) else {
            hasPendingFocusClaim = true
            return
        }
        if hasPendingFocusClaim, isTopMenuFocused {
            hasPendingFocusClaim = false
            return
        }
        hasPendingFocusClaim = false
        contentFocusToken += 1
    }

    // MARK: - Data

    private var sourceLibraries: [Library] {
        library.map { [$0] } ?? combinedLibraries
    }

    private func collectionKey(_ collection: LibraryCollection, kind: LibraryCollectionKind) -> String {
        "\((collection.kind ?? kind).rawValue):\(collection.id)"
    }

    private func loadCollections() async {
        isLoadingCollections = true
        collectionsError = nil
        if let cached: CachedCollections = ResponseCache.shared.get(cacheKey) {
            collectionSections = cached.sections
            collectionLibraryIds = cached.libraryIds
            isLoadingCollections = false
        }

        // Library tabs cache their own collection responses. Reuse those
        // immediately when the combined Collections page has not yet built
        // its aggregate cache, then replace them as fresh responses arrive.
        var responses: [Int: [LibraryCollectionSection]] = [:]
        for source in sourceLibraries {
            let key = "library:\(source.id):collections"
            if let cached: [LibraryCollectionSection] = ResponseCache.shared.get(key) {
                responses[source.id] = cached
            }
        }
        if collectionSections.isEmpty, !responses.isEmpty {
            applyCollectionResponses(responses)
            isLoadingCollections = false
        }

        do {
            try await withThrowingTaskGroup(of: (Int, [LibraryCollectionSection]).self) { group in
                for source in sourceLibraries {
                    group.addTask {
                        let response = try await VividAPI.shared.libraryCollections(libraryId: source.id)
                        return (source.id, response.resolvedSections)
                    }
                }

                // Publish each completed library instead of leaving the page
                // empty until the slowest server response finishes.
                for try await (id, sections) in group {
                    try Task.checkCancellation()
                    responses[id] = sections
                    ResponseCache.shared.set(sections, for: "library:\(id):collections")
                    applyCollectionResponses(responses)
                    isLoadingCollections = false
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            if collectionSections.isEmpty {
                collectionsError = ErrorState(error)
            }
        }
        isLoadingCollections = false
    }

    private func applyCollectionResponses(
        _ responses: [Int: [LibraryCollectionSection]]
    ) {
        var sections: [LibraryCollectionSection] = []
        var sources: [String: Int] = [:]
        var combined: [LibraryCollectionKind: [LibraryCollection]] = [:]
        var seen = Set<String>()

        for source in sourceLibraries {
            guard let responseSections = responses[source.id] else { continue }
            for section in responseSections {
                for collection in section.collections {
                    let kind = collection.kind ?? section.kind
                    let key = collectionKey(collection, kind: kind)
                    guard seen.insert(key).inserted else { continue }
                    sources[key] = source.id
                    combined[kind, default: []].append(collection)
                }
            }
            if library != nil { sections = responseSections }
        }

        if library == nil {
            sections = [LibraryCollectionKind.regular, .userCollections].compactMap { kind in
                guard let items = combined[kind], !items.isEmpty else { return nil }
                return LibraryCollectionSection(
                    id: kind.rawValue,
                    name: kind == .regular ? "Collections" : "User Collections",
                    kind: kind,
                    collections: items.sorted { lhs, rhs in
                        let order = lhs.name.localizedStandardCompare(rhs.name)
                        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
                    }
                )
            }
        }

        collectionLibraryIds = sources
        collectionSections = sections
        ResponseCache.shared.set(
            CachedCollections(sections: sections, libraryIds: sources),
            for: cacheKey
        )
    }

    private var resolvedColumnCount: Int {
        if let fixedColumnCount { return fixedColumnCount }
        let standard = VividTheme.Skyline.collectionGridColumnCount
        switch uiCustomization.cardPresentation.posterSize {
        case .compact: return standard + 1
        case .standard: return standard
        case .large: return max(3, standard - 1)
        }
    }
}

// MARK: - Collection card

/// Attaches an Up-move handler only when one is supplied, so lower grid rows
/// do not intercept the command the focus engine needs to move upward.
private struct TVCollectionCardMoveUpHandler: ViewModifier {
    let onMoveUp: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onMoveUp {
            content.onMoveCommand { direction in
                if direction == .up {
                    onMoveUp()
                }
            }
        } else {
            content
        }
    }
}

/// Grid wrapper around `TVCollectionPosterCard` (§6.3) that carries the
/// Collections pill's focus machinery: the programmatic entry kick, the
/// first-row hand-up to the pill row, and the recycle guard. The visual
/// is the shared poster card; this struct owns only focus plumbing.
private struct TVCollectionCard: View {
    let collection: LibraryCollection
    var cardWidth: CGFloat = VividTheme.posterCardWidth
    var loadsArtwork: Bool = true
    var prefersDefaultFocus: Bool = false
    var defaultFocusNamespace: Namespace.ID? = nil
    /// Programmatic focus kick: when this becomes non-zero (the Collections
    /// pill was restored on tab entry) focus jumps to this card, since
    /// `prefersDefaultFocus` alone doesn't fire when the scope isn't being
    /// entered by the engine.
    var focusRequest: Int = 0
    /// Supplied to every card in the first visual grid row: Up returns focus
    /// to the pill row. Lower rows omit it so native grid movement still walks
    /// through every intervening collection row.
    var onMoveUp: (() -> Void)? = nil
    var onFocused: (() -> Void)? = nil
    let action: () -> Void

    /// Drives the programmatic entry kick through the poster card's external
    /// focus binding. A single-card binding keyed on the collection id is
    /// enough — only the first card is ever handed a non-zero token.
    @FocusState private var focusedId: String?
    /// Last hand-down token applied, so each token claims focus exactly once.
    /// The card lives in a `LazyVGrid`; without the guard, `onAppear` re-fires
    /// when the first card is recycled back into view on scroll-up and would
    /// yank focus away from the row the user was navigating.
    @State private var lastAppliedFocusRequest = 0

    var body: some View {
        TVCollectionPosterCard(
            collection: collection,
            action: action,
            cardWidth: cardWidth,
            loadsArtwork: loadsArtwork,
            prefersDefaultFocus: prefersDefaultFocus,
            defaultFocusNamespace: defaultFocusNamespace,
            focusBinding: $focusedId,
            focusContentId: collection.id
        )
        .onChange(of: focusedId) { _, id in
            if id == collection.id { onFocused?() }
        }
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .modifier(TVCollectionCardMoveUpHandler(onMoveUp: onMoveUp))
    }

    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest else { return }
        lastAppliedFocusRequest = request
        focusedId = collection.id
    }
}
/// Keep For You's scroll geometry and edge shading consistent across list sizes.
struct TVPersonalScrollAppearance: ViewModifier {
    var enabled = true
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            if #available(tvOS 26.0, *) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollEdgeEffectHidden()
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else { content }
    }
}
#endif
