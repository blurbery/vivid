import SwiftUI

func libraryCollectionAccessibilityLabel(_ collection: LibraryCollection) -> String {
    let type = collection.kind == .userCollections
        ? "User collection"
        : collection.collectionType?.capitalized ?? "Collection"
    let count = if let itemCount = collection.itemCount {
        "\(itemCount) item\(itemCount == 1 ? "" : "s")"
    } else {
        "Smart"
    }
    return [collection.name, type, count].joined(separator: ", ")
}

/// List of user-created collections, grouped into named buckets +
/// "Ungrouped". Mirrors the web app's `Collections` page.
struct CollectionsView: View {
    @State private var viewModel = CollectionsViewModel()
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if !viewModel.collections.isEmpty || !viewModel.groups.isEmpty {
                sectionedList
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadCollections() } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack",
                    title: "No collections",
                    subtitle: "Create a collection to organize your media"
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Collections")
        .vividNavigationTitleDisplayMode(.large)
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button {
                    viewModel.pendingGroupAction = .create
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(.vividPrimary)
                }
            }
            ToolbarItem {
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.vividPrimary)
                }
            }
            #else
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.pendingGroupAction = .create
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(.vividPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.vividPrimary)
                }
            }
            #endif
        }
        .sheet(isPresented: $viewModel.showCreateSheet) {
            createSheet
        }
        .sheet(item: $viewModel.pendingGroupAction) { action in
            GroupActionSheet(action: action, viewModel: viewModel)
        }
        .task {
            await viewModel.loadCollections()
        }
        .refreshable {
            await viewModel.loadCollections()
        }
    }

    // MARK: - Sectioned list

    private var sectionedList: some View {
        List {
            ForEach(viewModel.sections) { section in
                Section {
                    if section.collections.isEmpty {
                        Text("Drop collections here to add them to this group.")
                            .font(.vividSmall)
                            .foregroundColor(.vividSecondaryText)
                            .listRowBackground(Color.vividSurface)
                    } else {
                        ForEach(section.collections) { collection in
                            collectionRow(collection)
                                .listRowBackground(Color.vividSurface)
                                #if !os(tvOS)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await viewModel.deleteCollection(id: collection.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        viewModel.pendingGroupAction = .move(collection)
                                    } label: {
                                        Label("Move", systemImage: "folder")
                                    }
                                    .tint(.vividPrimary)
                                }
                                #endif
                        }
                    }
                } header: {
                    sectionHeader(section)
                }
            }
        }
        #if os(tvOS) || os(macOS)
        .listStyle(.plain)
        #else
        .listStyle(.insetGrouped)
        #endif
        .vividScrollContentBackgroundHidden()
    }

    @ViewBuilder
    private func sectionHeader(_ section: UserCollectionSection) -> some View {
        HStack {
            Text(section.name)
                .font(.vividCaption)
                .foregroundColor(.vividSecondaryText)
            Spacer()
            if let groupId = section.groupId,
               let group = viewModel.groups.first(where: { $0.id == groupId }) {
                Menu {
                    Button {
                        viewModel.pendingGroupAction = .rename(group)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        viewModel.pendingGroupAction = .delete(group)
                    } label: {
                        Label("Delete group", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.vividSecondaryText)
                }
            }
        }
    }

    private func collectionRow(_ collection: UserCollection) -> some View {
        Button {
            router.navigate(to: .collectionDetail(collectionId: collection.id))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name)
                        .font(.vividBody)
                        .foregroundColor(.vividOnSurface)

                    Text(rowSubtitle(for: collection))
                        .font(.vividCaption)
                        .foregroundColor(.vividSecondaryText)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)
            }
            .padding(.vertical, 4)
        }
    }

    private func rowSubtitle(for collection: UserCollection) -> String {
        let kind = (collection.collectionType ?? "custom").capitalized
        if let count = collection.itemCount, count > 0 {
            return "\(kind) · \(count) item\(count == 1 ? "" : "s")"
        }
        return kind
    }

    // MARK: - Create Sheet

    private var createSheet: some View {
        NavigationStack {
            VStack(spacing: VividTheme.largePadding) {
                TextField("Collection name", text: $viewModel.newCollectionName)
                    .textFieldStyle(VividTextFieldStyle())

                Button("Create Collection") {
                    Task { await viewModel.createCollection() }
                }
                .vividPrimaryButton()
                .disabled(viewModel.newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(VividTheme.padding)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("New Collection")
            .vividNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showCreateSheet = false
                    }
                    .foregroundColor(.vividSecondaryText)
                }
            }
            .vividNavigationBarSurfaceBackground()
        }
        .presentationDetents([.medium])
    }
}

/// Modal for create-group / rename-group / delete-group / move-collection.
private struct GroupActionSheet: View {
    let action: CollectionsViewModel.GroupAction
    let viewModel: CollectionsViewModel

    @State private var name: String = ""
    @State private var pendingMoveTarget: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .background(Color.black.ignoresSafeArea())
                .vividNavigationTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.vividSecondaryText)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmLabel) { Task { await confirm() } }
                            .foregroundColor(.vividPrimary)
                            .disabled(!canConfirm)
                    }
                }
                .vividNavigationBarSurfaceBackground()
        }
        .presentationDetents([.medium])
        .onAppear {
            switch action {
            case .rename(let g): name = g.name
            case .move(let c): pendingMoveTarget = c.groupId
            default: break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch action {
        case .create:
            nameForm(title: "New group", prompt: "Group name")
        case .rename(let group):
            nameForm(title: "Rename “\(group.name)”", prompt: "Group name")
        case .delete(let group):
            VStack(spacing: VividTheme.padding) {
                Text("Delete “\(group.name)”?")
                    .font(.vividTitle)
                    .foregroundStyle(Color.vividOnSurface)
                Text("Collections in this group will move to Ungrouped. This cannot be undone.")
                    .font(.vividBody)
                    .foregroundStyle(Color.vividSecondaryText)
                    .multilineTextAlignment(.center)
                errorBanner
                Spacer()
            }
            .padding(VividTheme.padding)
            .navigationTitle("Delete group")
        case .move(let collection):
            VStack(spacing: 0) {
                List {
                    Section("Move “\(collection.name)” to") {
                        Button {
                            pendingMoveTarget = nil
                        } label: {
                            moveOptionRow(label: "Ungrouped", selected: pendingMoveTarget == nil)
                        }
                        .listRowBackground(Color.vividSurface)
                        ForEach(viewModel.groups) { group in
                            Button {
                                pendingMoveTarget = group.id
                            } label: {
                                moveOptionRow(label: group.name, selected: pendingMoveTarget == group.id)
                            }
                            .listRowBackground(Color.vividSurface)
                        }
                    }
                }
                #if os(tvOS) || os(macOS)
                .listStyle(.plain)
                #else
                .listStyle(.insetGrouped)
                #endif
                .vividScrollContentBackgroundHidden()
                errorBanner
                    .padding(.horizontal, VividTheme.padding)
                    .padding(.bottom, VividTheme.padding)
            }
            .navigationTitle("Move collection")
        }
    }

    private func nameForm(title: String, prompt: String) -> some View {
        VStack(spacing: VividTheme.largePadding) {
            TextField(prompt, text: $name)
                .textFieldStyle(VividTextFieldStyle())
            errorBanner
            Spacer()
        }
        .padding(VividTheme.padding)
        .navigationTitle(title)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = viewModel.groupError {
            Text(message)
                .font(.vividCaption)
                .foregroundColor(.vividError)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func moveOptionRow(label: String, selected: Bool) -> some View {
        HStack {
            Text(label)
                .font(.vividBody)
                .foregroundColor(.vividOnSurface)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundColor(.vividPrimary)
            }
        }
    }

    private var confirmLabel: String {
        switch action {
        case .create: return "Create"
        case .rename: return "Save"
        case .delete: return "Delete"
        case .move: return "Move"
        }
    }

    private var canConfirm: Bool {
        switch action {
        case .create, .rename:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .delete, .move:
            return true
        }
    }

    private func confirm() async {
        switch action {
        case .create:
            await viewModel.createGroup(name: name)
        case .rename(let group):
            await viewModel.renameGroup(id: group.id, name: name)
        case .delete(let group):
            await viewModel.deleteGroup(id: group.id)
        case .move(let collection):
            await viewModel.moveCollection(id: collection.id, toGroupId: pendingMoveTarget)
        }
        // The view model clears `pendingGroupAction` only on success;
        // keep the sheet open on error so the user sees the failure
        // surfaced on the main view.
        if viewModel.pendingGroupAction == nil {
            dismiss()
        }
    }
}

@Observable
@MainActor
private class LibraryCollectionsViewModel {
    /// Ordered render sections — either named groups from the server or
    /// a single anonymous section synthesized from a flat response.
    var sections: [LibraryCollectionSection] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?

    var isEmpty: Bool { sections.allSatisfy { $0.collections.isEmpty } }

    func loadCollections(libraryId: Int) async {
        let key = "library:\(libraryId):collections"
        if sections.isEmpty,
           let cached: [LibraryCollectionSection] = ResponseCache.shared.get(key) {
            sections = cached
        }
        if sections.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil

        do {
            let response = try await VividAPI.shared.libraryCollections(libraryId: libraryId)
            let resolved = response.resolvedSections
            ResponseCache.shared.set(resolved, for: key)
            sections = resolved
        } catch let err {
            if sections.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
        isRefreshing = false
    }
}

struct LibraryCollectionsView: View {
    let libraryId: Int

    @State private var viewModel = LibraryCollectionsViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return Array(repeating: GridItem(.flexible(), spacing: 12),
                         count: AdaptiveColumns.tabletPosterCount(containerWidth: gridWidth, spacing: 12))
        }
        #endif
        if usesThreeColumnPhoneLayout {
            return Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: 3
            )
        }
        return AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    var body: some View {
        Group {
            if !viewModel.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: VividTheme.padding) {
                        ForEach(viewModel.sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(VividTheme.padding)
                    .padding(.bottom, VividTheme.largePadding)
                }
                .reportsPageChromeScroll()
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadCollections(libraryId: libraryId) } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up.fill",
                    title: "No collections yet",
                    subtitle: "Create library collections in the web app to feature curated shelves here."
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: libraryId) {
            await viewModel.loadCollections(libraryId: libraryId)
        }
        .refreshable {
            await viewModel.loadCollections(libraryId: libraryId)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: LibraryCollectionSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !section.name.isEmpty {
                Text(section.name)
                    .font(.vividTitle)
                    .foregroundColor(.vividOnSurface)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(section.collections) { collection in
                    NavigationLink(
                        value: Route.libraryCollection(
                            libraryId: libraryId,
                            collectionId: collection.id,
                            title: collection.name,
                            kind: collection.kind
                        )
                    ) {
                        LibraryCollectionCard(
                            collection: collection,
                            cardWidthOverride: libraryCollectionCardWidthOverride
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(libraryCollectionAccessibilityLabel(collection))
                }
            }
            #if os(iOS)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard abs(width - gridWidth) >= 0.5 else { return }
                gridWidth = width
            }
            #endif
        }
    }

    private var usesThreeColumnPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone || hSize != .regular
        #else
        false
        #endif
    }

    private var libraryCollectionCardWidthOverride: CGFloat? {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return AdaptiveColumns.tabletPosterWidth(containerWidth: gridWidth, spacing: 12)
        }
        return AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: columns.count,
            spacing: 12
        )
        #else
        return nil
        #endif
    }
}

private struct LibraryCollectionCard: View {
    let collection: LibraryCollection
    let cardWidthOverride: CGFloat?
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var cardWidth: CGFloat {
        cardWidthOverride
            ?? (VividTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale)
    }
    private var cardHeight: CGFloat {
        cardWidth * (VividTheme.posterCardHeight / VividTheme.posterCardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                poster

                Text(countLabel)
                    .font(.vividSmall)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .padding(8)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius))

            if uiCustomization.cardPresentation.caption.showsTitle {
                Text(collection.name)
                    .font(.vividCaption)
                    .foregroundStyle(Color.vividOnSurface)
                    .lineLimit(2, reservesSpace: true)
            }

            if uiCustomization.cardPresentation.caption.showsMetadata {
                Text(typeLabel)
                    .font(.vividSmall)
                    .foregroundStyle(Color.vividSecondaryText)
                    .lineLimit(1)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    @ViewBuilder
    private var poster: some View {
        if let posterUrl = collection.posterUrl, !posterUrl.isEmpty {
            AsyncImageView(
                url: posterUrl,
                thumbhash: collection.posterThumbhash,
                targetSize: CGSize(width: cardWidth, height: cardHeight),
                contentMode: .fill
            )
            .frame(width: cardWidth, height: cardHeight)
            .clipped()
        } else {
            ZStack {
                Color.vividSurfaceVariant
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.vividSecondaryText)
            }
            .frame(width: cardWidth, height: cardHeight)
        }
    }

    private var countLabel: String {
        if let itemCount = collection.itemCount {
            return "\(itemCount)"
        }
        return "Smart"
    }

    private var typeLabel: String {
        if collection.kind == .userCollections {
            return "User collection"
        }
        return collection.collectionType?.capitalized ?? "Collection"
    }
}

struct LibraryCollectionDetailView: View {
    let libraryId: Int
    let collectionId: String
    let title: String?
    let kind: LibraryCollectionKind?

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var hasMore = true
    @State private var totalItems: Int?
    @State private var nextOffset = 0
    @State private var snapshot: String?

    @Environment(AppRouter.self) private var router

    private let pageSize = 60

    var body: some View {
        Group {
            if !items.isEmpty {
                content
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadItems(reset: true) } })
            } else if isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up.fill",
                    title: "Collection is empty",
                    subtitle: "This collection does not have any items yet."
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(title ?? "Collection")
        .vividNavigationTitleDisplayMode(.large)
        .task(id: "\(libraryId)-\(collectionId)") {
            await loadItems(reset: true)
        }
        .refreshable {
            await loadItems(reset: true)
        }
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: VividTheme.padding) {
                Text(countLabel)
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)

                CatalogGrid(
                    items: items,
                    isLoading: isLoading,
                    hasMore: hasMore,
                    forcesThreeColumnsOnPhone: true,
                    onItemTap: { item in
                        router.navigate(to: .itemDetail(browseItem: item))
                    },
                    onLoadMore: {
                        Task { await loadMoreIfNeeded() }
                    }
                )
            }
            .padding(.horizontal, VividTheme.padding)
            .padding(.top, VividTheme.smallPadding)
            .padding(.bottom, VividTheme.largePadding)
        }
    }

    private var countLabel: String {
        if let totalItems, !hasMore {
            return "\(totalItems) item\(totalItems == 1 ? "" : "s")"
        }
        let suffix = hasMore ? "+" : ""
        return "\(items.count)\(suffix) item\(items.count == 1 && !hasMore ? "" : "s")"
    }

    private func loadMoreIfNeeded() async {
        guard hasMore, !isLoading else { return }
        await loadItems(reset: false)
    }

    private func loadItems(reset: Bool) async {
        guard !isLoading else { return }
        if reset {
            // Surface the cached page-1 snapshot instantly so the grid
            // doesn't blank out while the network call runs.
            if items.isEmpty, MediaServerProvider.active != .emby,
               let cached: CatalogResponse = ResponseCache.shared.get(
                   CacheKey.collectionItems(collectionId)
               ) {
                items = cached.items
                hasMore = cached.hasMore ?? false
                totalItems = cached.totalExact == false ? nil : cached.total
                nextOffset = cached.items.count
                snapshot = cached.snapshot
            } else {
                items = []
                hasMore = true
                totalItems = nil
                nextOffset = 0
                snapshot = nil
            }
        }
        guard hasMore else { return }

        isLoading = true
        error = nil

        do {
            let response: CatalogResponse
            if kind == .userCollections {
                response = try await VividAPI.shared.userCollectionItems(
                    collectionId: collectionId,
                    offset: nextOffset,
                    limit: pageSize,
                    snapshot: snapshot
                )
            } else {
                response = try await VividAPI.shared.libraryCollectionItems(
                    libraryId: libraryId,
                    collectionId: collectionId,
                    offset: nextOffset,
                    limit: pageSize,
                    snapshot: snapshot
                )
            }
            if reset {
                items = response.items
                ResponseCache.shared.set(response, for: CacheKey.collectionItems(collectionId))
            } else {
                items.append(contentsOf: response.items)
            }
            totalItems = response.totalExact == false ? nil : response.total
            hasMore = response.hasMore ?? false
            nextOffset += response.items.count
            if snapshot == nil {
                snapshot = response.snapshot
            }
        } catch let err {
            if items.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
    }
}

#if os(iOS)
struct MobileForYouCollections: View {
    @Environment(\.forYouScrollHeader) private var scrollHeader
    private struct Entry: Identifiable {
        let libraryID: Int
        let collection: LibraryCollection
        var id: String { "\(libraryID):\(collection.kind?.rawValue ?? "regular"):\(collection.id)" }
    }

    @State private var personal = CollectionsViewModel()
    @State private var entries: [Entry] = []
    @State private var isLoading = true
    @State private var error: ErrorState?
    @State private var gridWidth: CGFloat = 0
    @Environment(AppRouter.self) private var router

    @Environment(\.horizontalSizeClass) private var hSize

    private var columnCount: Int {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return AdaptiveColumns.tabletPosterCount(containerWidth: gridWidth, spacing: 12)
        }
        return hSize == .regular && UIDevice.current.userInterfaceIdiom != .phone ? 5 : 3
    }
    private var cardWidth: CGFloat? {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return AdaptiveColumns.tabletPosterWidth(containerWidth: gridWidth, spacing: 12)
        }
        return AdaptiveColumns.fittedPosterWidth(containerWidth: gridWidth, columnCount: columnCount, spacing: 12)
    }

    var body: some View {
        ScrollView {
            scrollHeader
            LazyVStack(spacing: 16) {
                ForEach(personal.collections) { collection in
                    Button {
                        router.navigate(to: .collectionDetail(collectionId: collection.id))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.stack")
                            Text(collection.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), spacing: 16) {
                    ForEach(entries) { entry in
                        NavigationLink(value: Route.libraryCollection(
                            libraryId: entry.libraryID,
                            collectionId: entry.collection.id,
                            title: entry.collection.name,
                            kind: entry.collection.kind
                        )) {
                            LibraryCollectionCard(collection: entry.collection, cardWidthOverride: cardWidth)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(libraryCollectionAccessibilityLabel(entry.collection))
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                if isLoading { ProgressView().tint(.white) }
                if let error {
                    ErrorView(state: error, onRetry: { Task { await load() } })
                } else if !isLoading && entries.isEmpty && personal.collections.isEmpty {
                    EmptyStateView(icon: "square.stack", title: "No collections", subtitle: "Your collections will appear here.")
                }
            }.padding(16)
        }
        .reportsPageChromeScroll()
        .background(Color.black.ignoresSafeArea())
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        if MediaServerProvider.active == .emby {
            do {
                let response: LibraryCollectionsWireResponse = try await HTTPClient.shared.get("/api/v1/collections")
                entries = response.collections.map { Entry(libraryID:0,collection:$0) }
            } catch { self.error = ErrorState(error) }
            isLoading = false
            return
        }

        async let personalLoad: Void = personal.loadCollections()
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            let libraries = response.libraries.filter {
                $0.isMovieLibrary || $0.isSeriesLibrary || $0.isMixedLibrary
            }
            var sectionsByLibrary: [Int: [LibraryCollectionSection]] = [:]

            // Paint any library collection cache before refreshing the
            // network. This makes a return visit immediate.
            for library in libraries {
                let key = "library:\(library.id):collections"
                if let cached: [LibraryCollectionSection] = ResponseCache.shared.get(key) {
                    sectionsByLibrary[library.id] = cached
                }
            }
            publishEntries(
                from: sectionsByLibrary,
                libraries: libraries,
                excludingPersonalIDs: []
            )

            try await withThrowingTaskGroup(of: (Int, [LibraryCollectionSection]).self) { group in
                for library in libraries {
                    group.addTask {
                        let response = try await VividAPI.shared.libraryCollections(libraryId: library.id)
                        return (library.id, response.resolvedSections)
                    }
                }
                for try await (libraryID, sections) in group {
                    try Task.checkCancellation()
                    sectionsByLibrary[libraryID] = sections
                    ResponseCache.shared.set(sections, for: "library:\(libraryID):collections")
                    publishEntries(
                        from: sectionsByLibrary,
                        libraries: libraries,
                        excludingPersonalIDs: []
                    )
                }
            }

            await personalLoad
            error = personal.error
            publishEntries(
                from: sectionsByLibrary,
                libraries: libraries,
                excludingPersonalIDs: Set(personal.collections.map(\.id))
            )
        } catch {
            self.error = ErrorState(error)
            await personalLoad
            if self.error == nil { self.error = personal.error }
        }
        isLoading = false
    }

    private func publishEntries(
        from sectionsByLibrary: [Int: [LibraryCollectionSection]],
        libraries: [Library],
        excludingPersonalIDs personalIDs: Set<String>
    ) {
        var loaded: [Entry] = []
        var seen = Set<String>()
        for library in libraries {
            for collection in sectionsByLibrary[library.id, default: []].flatMap(\.collections) {
                if collection.kind == .userCollections,
                   personalIDs.contains(collection.id) { continue }
                let entry = Entry(libraryID: library.id, collection: collection)
                if seen.insert(entry.id).inserted { loaded.append(entry) }
            }
        }
        entries = loaded.sorted {
            $0.collection.name.localizedStandardCompare($1.collection.name) == .orderedAscending
        }
    }
}
#endif
