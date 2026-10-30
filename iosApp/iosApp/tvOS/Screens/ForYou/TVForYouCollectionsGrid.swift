#if os(tvOS)
import SwiftUI

extension TVMainTabView {
    /// For You's Collections: every movie, series and mixed library's
    /// collections and, on Silo, the profile's own, in User Collections and
    /// Collections sections.
    struct TVLibraryCollectionsView: View {
        let libraries: [Library]
        let filter: PersonalListFilter
        /// The bar, a sub-tab, A–Z or Filter holds focus.
        let isFocusUp: Bool

        @State private var shelves: [Shelf] = []
        @State private var isLoading = true
        @State private var error: ErrorState?
        @State private var visibleKeys: Set<String> = []
        @State private var lastFocusedKey: String?
        @State private var measuredWidth: CGFloat?
        @State private var artwork = TVPosterArtworkWindow()
        @State private var retryCount = 0
        @FocusState private var emptyFocused: Bool
        @Namespace private var scope
        @Environment(\.displayScale) private var displayScale
        @Environment(AppRouter.self) private var router

        /// Reloads when the libraries change or Retry is chosen, cancelling any load still running.
        private var loadKey: String {
            libraries.map { "\($0.id)" }.joined(separator: ",") + "#\(retryCount)"
        }

        private static let columns = 7
        private static let columnSpacing = VividTheme.Skyline.collectionGridColumnSpacing

        var body: some View {
            let displayed = displayedShelves
            LazyVStack(spacing: 44) {
                Color.clear.frame(height: 0)
                if displayed.isEmpty {
                    emptyContent
                } else {
                    grid(displayed)
                }
            }
            .padding(.bottom, VividTheme.largePadding)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
            .task(id: loadKey) { await load() }
            .onChange(of: artworkEntries(displayed)) { _, entries in artwork.update(entries) }
            .onAppear { artwork.update(artworkEntries(displayed)) }
            .onDisappear {
                artwork.clear()
                visibleKeys = []
            }
        }

        // MARK: Layout

        private var cellWidth: CGFloat {
            let gridWidth = measuredWidth.map { max(1, $0 - 160) } ?? 1760
            let gaps = Self.columnSpacing * CGFloat(Self.columns - 1)
            return max(1, (gridWidth - gaps) / CGFloat(Self.columns))
        }

        private func grid(_ displayed: [Shelf]) -> some View {
            let cardWidth = cellWidth / UICustomizationPreferences.shared.cardPresentation.posterSize.scale
            let flat = displayed.flatMap(\.entries)
            let band = artworkBand(flat)
            let firstKey = flat.first?.key
            var positions: [String: Int] = [:]
            for (position, entry) in flat.enumerated() where positions[entry.key] == nil {
                positions[entry.key] = position
            }
            return VStack(alignment: .leading, spacing: 44) {
                ForEach(displayed) { shelf in
                    VStack(alignment: .leading, spacing: 20) {
                        if !shelf.name.isEmpty {
                            Text(verbatim: shelf.name)
                                .textCase(.uppercase)
                                .font(.system(size: VividTheme.Skyline.collectionGridGroupHeaderSize, design: .monospaced))
                                .tracking(VividTheme.Skyline.collectionGridGroupHeaderSize * 0.26)
                                .foregroundStyle(Color.vividOnSurface.opacity(0.38))
                                .lineLimit(1)
                                .padding(.leading, 80)
                        }
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: Self.columnSpacing, alignment: .top),
                                count: Self.columns
                            ),
                            alignment: .leading,
                            spacing: VividTheme.Skyline.collectionGridRowSpacing
                        ) {
                            ForEach(shelf.entries) { entry in
                                card(
                                    entry,
                                    shelf: shelf,
                                    width: cardWidth,
                                    loadsArtwork: band.contains(positions[entry.key] ?? 0),
                                    isFirst: entry.key == firstKey
                                )
                            }
                        }
                        .padding(.horizontal, 80)
                    }
                }
            }
            .focusScope(scope)
            .focusSection()
        }

        private func card(
            _ entry: Entry,
            shelf: Shelf,
            width: CGFloat,
            loadsArtwork: Bool,
            isFirst: Bool
        ) -> some View {
            CollectionPosterCard(
                collection: entry.collection,
                cardWidth: width,
                loadsArtwork: loadsArtwork,
                prefersDefaultFocus: isFirst,
                namespace: scope,
                onFocus: { lastFocusedKey = entry.key },
                action: { open(entry, shelf: shelf) }
            )
            .frame(maxWidth: .infinity)
            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                if isVisible { visibleKeys.insert(entry.key) } else { visibleKeys.remove(entry.key) }
            }
            .onDisappear { visibleKeys.remove(entry.key) }
        }

        private var emptyContent: some View {
            let filterActive = filter.limited(to: .collections).isActive
            let title: LocalizedStringKey = filterActive ? "No collections match these filters" : "No collections yet"
            let subtitle: LocalizedStringKey? = filterActive ? nil : "Collections created on the server will appear here."
            return ZStack {
                if isLoading {
                    Color.clear
                } else if let error {
                    ErrorView(state: error, onRetry: { retryCount += 1 })
                } else {
                    EmptyStateView(
                        icon: filterActive ? "line.3.horizontal.decrease" : "square.stack",
                        title: title,
                        subtitle: subtitle
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 400)
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($emptyFocused)
            .accessibilityLabel(isLoading ? Text("Loading collections") : Text(title))
            .task {
                // Judged once, as focus stood when the empty content appeared.
                let focusWasUp = isFocusUp
                guard !focusWasUp else { return }
                await Task.yield()
                guard displayedShelves.isEmpty else { return }
                emptyFocused = true
            }
        }

        private func open(_ entry: Entry, shelf: Shelf) {
            router.navigate(to: .libraryCollection(
                libraryId: entry.libraryId,
                collectionId: entry.collection.id,
                title: entry.collection.name,
                kind: entry.collection.kind ?? shelf.kind
            ))
        }

        // MARK: What shows

        private var displayedShelves: [Shelf] {
            let usesNativeUser = MediaServerProvider.active.usesNativeUser
            let active = filter.limited(to: .collections)
            let profileID = ServerRegistry.shared.activeProfileId
            return shelves.compactMap { shelf in
                var entries = shelf.entries
                if active.isActive {
                    entries = entries.filter {
                        active.matchesCollection(
                            kind: $0.collection.kind ?? shelf.kind,
                            creatorProfileID: $0.collection.creatorProfileId,
                            activeProfileID: profileID
                        )
                    }
                }
                if usesNativeUser {
                    entries = entries.map { entry in
                        Entry(
                            key: entry.key,
                            libraryId: entry.libraryId,
                            collection: HomeCollectionsStore.shared.withKnownCount(entry.collection)
                        )
                    }
                }
                guard !entries.isEmpty else { return nil }
                return Shelf(kind: shelf.kind, name: shelf.name, entries: entries)
            }
        }

        // MARK: Artwork

        private func artworkBand(_ flat: [Entry]) -> Range<Int> {
            let firstVisible = flat.firstIndex { visibleKeys.contains($0.key) }
            let focused = lastFocusedKey.flatMap { key in flat.firstIndex { $0.key == key } }
            return TVPosterArtworkWindow.range(
                firstVisible: firstVisible,
                focusedIndex: focused,
                itemCount: flat.count,
                columns: Self.columns
            )
        }

        private func artworkEntries(_ displayed: [Shelf]) -> [TVPosterArtworkWindow.Entry] {
            let flat = displayed.flatMap(\.entries)
            let band = artworkBand(flat)
            let pixelWidth = cellWidth * displayScale
            let pixelSize = CGSize(width: pixelWidth, height: pixelWidth * 1.5)
            return flat[band].compactMap { entry in
                guard let raw = entry.collection.posterUrl, let url = URL(string: raw) else { return nil }
                return TVPosterArtworkWindow.Entry(url: url, pixelSize: pixelSize)
            }
        }

        // MARK: Loading

        private func load() async {
            isLoading = true
            error = nil
            let provider = MediaServerProvider.active
            if provider.usesNativeUser {
                Task { await HomeCollectionsStore.shared.loadIfNeeded() }
            }
            let ids = libraries.map(\.id)
            let pageKey = Self.pageKey(ids)

            var personal: [LibraryCollection]?
            if let cached = ResponseCache.shared.get(pageKey, as: CachedPage.self) {
                shelves = cached.shelves
                personal = cached.personal
                isLoading = false
            }

            var sectionsByLibrary: [Int: [LibraryCollectionSection]] = [:]
            for id in ids {
                if let cached = ResponseCache.shared.get(Self.libraryKey(id), as: [LibraryCollectionSection].self) {
                    sectionsByLibrary[id] = cached
                }
            }
            if shelves.isEmpty && !sectionsByLibrary.isEmpty {
                publish(ids: ids, sections: sectionsByLibrary, personal: personal, pageKey: pageKey)
                isLoading = false
            }

            let profileID = ServerRegistry.shared.activeProfileId
            var firstFailure: Error?
            await withTaskGroup(of: Outcome.self) { group in
                for id in ids {
                    group.addTask {
                        do {
                            return .library(id, .success(try await VividAPI.shared.visibleLibraryCollections(libraryId: id).resolvedSections))
                        } catch {
                            return .library(id, .failure(error))
                        }
                    }
                }
                if provider == .silo {
                    group.addTask { .personal(try? await VividAPI.shared.personalCollections(profileID: profileID)) }
                }
                for await outcome in group {
                    guard !Task.isCancelled else { continue }
                    switch outcome {
                    case .library(let id, .success(let sections)):
                        sectionsByLibrary[id] = sections
                        ResponseCache.shared.set(sections, for: Self.libraryKey(id))
                    case .library(_, .failure(let failure)):
                        if firstFailure == nil { firstFailure = failure }
                        continue
                    case .personal(let list):
                        guard let list else { continue }
                        personal = list
                    }
                    publish(ids: ids, sections: sectionsByLibrary, personal: personal, pageKey: pageKey)
                    isLoading = false
                }
            }

            guard !Task.isCancelled else { return }
            if shelves.isEmpty, let firstFailure { error = ErrorState(firstFailure) }
            isLoading = false
        }

        /// Libraries in order, first copy of each collection wins, then the
        /// profile's own collections not already listed.
        private func publish(
            ids: [Int],
            sections: [Int: [LibraryCollectionSection]],
            personal: [LibraryCollection]?,
            pageKey: String
        ) {
            var seen = Set<String>()
            var grouped: [LibraryCollectionKind: [Entry]] = [:]
            for id in ids {
                for section in sections[id] ?? [] {
                    for collection in section.collections {
                        let kind = collection.kind ?? section.kind
                        let key = "\(kind.rawValue):\(collection.id)"
                        guard seen.insert(key).inserted else { continue }
                        grouped[kind, default: []].append(Entry(key: key, libraryId: id, collection: collection))
                    }
                }
            }
            for collection in personal ?? [] {
                let key = "\((collection.kind ?? .userCollections).rawValue):\(collection.id)"
                guard seen.insert(key).inserted else { continue }
                grouped[.userCollections, default: []].append(
                    Entry(key: key, libraryId: HomeCollection.personalLibraryID, collection: collection)
                )
            }

            let layout: [(LibraryCollectionKind, String)] = [
                (.userCollections, String(localized: "User Collections")),
                (.regular, String(localized: "Collections")),
            ]
            let built = layout.compactMap { kind, name -> Shelf? in
                guard let entries = grouped[kind], !entries.isEmpty else { return nil }
                return Shelf(kind: kind, name: name, entries: entries.sorted(by: Self.byName))
            }
            shelves = built
            ResponseCache.shared.set(CachedPage(shelves: built, personal: personal), for: pageKey)
        }

        private static func byName(_ lhs: Entry, _ rhs: Entry) -> Bool {
            switch lhs.collection.name.localizedStandardCompare(rhs.collection.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.collection.id < rhs.collection.id
            }
        }

        private static func libraryKey(_ id: Int) -> String { "library:\(id):collections" }

        private static func pageKey(_ ids: [Int]) -> String {
            "personal:tvForYouCollections:" + ids.map(String.init).joined(separator: ",")
        }

        // MARK: Types

        private enum Outcome {
            case library(Int, Result<[LibraryCollectionSection], Error>)
            case personal([LibraryCollection]?)
        }

        fileprivate struct Entry: Identifiable {
            /// The kind's raw value and the collection id, such as `user_collections:42`.
            let key: String
            let libraryId: Int
            let collection: LibraryCollection
            var id: String { collection.id }
        }

        fileprivate struct Shelf: Identifiable {
            let kind: LibraryCollectionKind
            let name: String
            let entries: [Entry]
            var id: String { kind.rawValue }
        }

        /// The built shelves, which carry the library each key belongs to,
        /// and the personal list they were built with.
        private struct CachedPage {
            let shelves: [Shelf]
            let personal: [LibraryCollection]?
        }
    }
}

/// A collection's poster, or a stable colour when it has none, with its
/// name and title count below.
private struct CollectionPosterCard: View {
    let collection: LibraryCollection
    let cardWidth: CGFloat
    let loadsArtwork: Bool
    let prefersDefaultFocus: Bool
    let namespace: Namespace.ID?
    let onFocus: () -> Void
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private var size: CGSize {
        let width = cardWidth * UICustomizationPreferences.shared.cardPresentation.posterSize.scale
        return CGSize(width: width, height: width * 1.5)
    }

    private var count: Int { collection.itemCount ?? 0 }

    var body: some View {
        let size = size
        let caption = UICustomizationPreferences.shared.cardPresentation.caption
        VStack(alignment: .leading, spacing: 16) {
            Button(action: action) {
                poster(size)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .applyDefaultFocusIfNeeded(prefersDefaultFocus, namespace: namespace)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .onChange(of: isFocused) { if isFocused { onFocus() } }

            if caption.showsTitle {
                VStack(spacing: 4) {
                    Text(verbatim: collection.name)
                        .font(.vividPosterTitle)
                        .foregroundStyle(isFocused ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: size.width)
                        .clipped()
                    if caption.showsMetadata, count > 0 {
                        countText
                            .textCase(.uppercase)
                            .font(.vividPosterMetadata)
                            .foregroundStyle(Color.vividSecondaryText)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(width: size.width)
            }
        }
        .frame(width: size.width)
    }

    private var accessibilityText: Text {
        count > 0
            ? Text("\(collection.name), collection, \(count) items")
            : Text("\(collection.name), collection")
    }

    private var countText: Text {
        switch collection.collectionType?.lowercased() {
        case "movie", "movies": Text("\(count) movies")
        case "series", "show", "shows", "tvshows": Text("\(count) shows")
        case "album", "albums": Text("\(count) albums")
        default: Text("\(count) items")
        }
    }

    @ViewBuilder
    private func poster(_ size: CGSize) -> some View {
        if !loadsArtwork {
            Color.vividSurface
        } else if let url = collection.posterUrl, !url.isEmpty {
            CachedAsyncImage(url: url, targetSize: size, thumbhash: collection.posterThumbhash, contentMode: .fill)
        } else {
            let hue = Self.placeholderHue(collection.id)
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.50, brightness: 0.42),
                        Color(hue: hue, saturation: 0.32, brightness: 0.22),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "square.stack.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
    }

    /// 64-bit FNV-1a over the id's UTF-8 bytes, so a collection keeps its
    /// colour on every launch and device.
    private static func placeholderHue(_ id: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Double(hash % 360) / 360
    }
}
#endif
