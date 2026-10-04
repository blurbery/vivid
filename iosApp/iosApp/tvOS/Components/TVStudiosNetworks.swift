#if os(tvOS)
import CollectionHStack
import SwiftUI

/// Logo tile shared by the Home row, the settings preview and the pick grid.
private struct TVStudioNetworkTile: View {
    let id: String
    let width: CGFloat
    @State private var store = StudiosNetworksStore.shared

    var body: some View {
        StudioNetworkLogo(brand: store.brand(id), url: store.results[id]?.logoURL, fallbackName: id)
            .frame(maxWidth: width * 0.62, maxHeight: width * 9 / 16 * 0.42)
            .frame(width: width, height: width * 9 / 16)
            .background(Color.white.opacity(0.06))
    }
}

// MARK: - Home row

/// Pinned under the Spotlight with no header. Six tiles span the hero's
/// width, so the row never scrolls.
struct TVStudiosNetworksRow: View {
    /// Increments when the Spotlight hands focus down to this row.
    let enterRequest: Int
    /// Only when the row tops Home: Up returns to the top menu, as from
    /// the first Home row without a Spotlight.
    var onMoveUp: (() -> Void)? = nil
    let onFocused: () -> Void
    /// Called just before a tile opens its page, so Home can return focus here.
    let onOpen: () -> Void

    @State private var store = StudiosNetworksStore.shared
    @FocusState private var focusedTile: String?
    @State private var lastTile: String?
    @Environment(AppRouter.self) private var router

    private static let spacing: CGFloat = 30
    /// The Spotlight card's inset on each side.
    private static let heroInset: CGFloat = 60

    static func tileWidth(screenWidth: CGFloat) -> CGFloat {
        let rowWidth = screenWidth - heroInset * 2
        return (rowWidth - spacing * CGFloat(StudiosNetworksStore.maxPicks - 1)) / CGFloat(StudiosNetworksStore.maxPicks)
    }

    var body: some View {
        if store.showsRow {
            GeometryReader { proxy in
                let tileWidth = Self.tileWidth(screenWidth: proxy.size.width)
                HStack(spacing: Self.spacing) {
                    ForEach(store.picks, id: \.self) { id in
                        Button {
                            lastTile = id
                            onOpen()
                            router.navigate(to: .studioNetwork(brandId: id))
                        } label: {
                            TVStudioNetworkTile(id: id, width: tileWidth)
                        }
                        .buttonStyle(.card)
                        .focused($focusedTile, equals: id)
                        .accessibilityLabel(store.brand(id)?.name ?? id)
                    }
                }
                .padding(.horizontal, Self.heroInset)
                // Up and Down are native, like moving between other Home
                // rows. A manual claim here raced the focus engine on swipes
                // and pulled focus to the remembered Continue Watching card.
                .focusSection()
                .onMoveCommand { direction in
                    guard let onMoveUp, direction == .up, focusedTile != nil else { return }
                    onMoveUp()
                }
                .onChange(of: focusedTile) { _, tile in
                    guard let tile else { return }
                    lastTile = tile
                    onFocused()
                }
                .onChange(of: enterRequest) { _, _ in
                    focusedTile = lastTile.flatMap { store.picks.contains($0) ? $0 : nil } ?? store.picks.first
                }
            }
            .frame(height: Self.tileWidth(screenWidth: 1920) * 9 / 16)
        }
    }
}

// MARK: - Brand page

struct TVStudioNetworkPage: View {
    let brandId: String
    @State private var store = StudiosNetworksStore.shared
    @State private var homeCards = TVHomeCardPreferences.shared
    @State private var uiCustomization = UICustomizationPreferences.shared

    var body: some View {
        // The store changes while other brands load or refresh. Only this
        // brand's rows reach the content, so those changes don't rebuild
        // every card on the page.
        let result = store.results[brandId] ?? StudioNetworkResult()
        TVStudioNetworkPageContent(
            brandId: brandId,
            brand: store.brand(brandId),
            logoURL: result.logoURL,
            rows: store.pageRows(for: brandId).map { TVStudioNetworkPageContent.Row(title: $0.title, items: $0.items) },
            all: result.all,
            railPosterSize: homeCards.presentation.posterSize,
            gridPosterSize: uiCustomization.cardPresentation.posterSize
        )
        .equatable()
        .task { await store.loadIfNeeded() }
    }
}

private struct TVStudioNetworkPageContent: View, Equatable {
    struct Row: Equatable {
        let title: String
        let items: [BrowseItem]
    }

    let brandId: String
    let brand: StudioNetworkBrand?
    let logoURL: URL?
    let rows: [Row]
    let all: [BrowseItem]
    let railPosterSize: CardPosterSize
    /// The grid's poster size, so the first row resizes with the rest of the
    /// grid when the setting changes.
    let gridPosterSize: CardPosterSize

    @Environment(AppRouter.self) private var router
    @EnvironmentObject private var overlayStore: OverlayPrefsStore

    private static let inset: CGFloat = 80
    private static let columns = 7
    private static let columnSpacing: CGFloat = 40
    /// Matches TVCatalogGrid's row spacing.
    private static let gridRowSpacing: CGFloat = 60

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.brandId == rhs.brandId && lhs.brand == rhs.brand && lhs.logoURL == rhs.logoURL
            && lhs.rows == rhs.rows && lhs.all == rhs.all && lhs.railPosterSize == rhs.railPosterSize
            && lhs.gridPosterSize == rhs.gridPosterSize
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 48) {
                StudioNetworkLogo(brand: brand, url: logoURL, fallbackName: brandId)
                    .frame(maxWidth: 480, maxHeight: 150)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 110)
                    .padding(.bottom, 20)
                    .accessibilityElement()
                    .accessibilityLabel(brand?.name ?? brandId)
                    .accessibilityAddTraits(.isHeader)

                ForEach(rows, id: \.title) { row in
                    rail(title: row.title, items: row.items)
                }

                if !all.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        sectionTitle("All in Your Library")
                        // The first row is built up front so Down from the
                        // last rail always has somewhere to land. The rest is
                        // the For You and library grid, which builds rows as
                        // they near the screen and prefetches their artwork.
                        VStack(alignment: .leading, spacing: Self.gridRowSpacing) {
                            firstGridRow(Array(all.prefix(Self.columns)))
                            if all.count > Self.columns {
                                TVCatalogGrid(
                                    items: Array(all.dropFirst(Self.columns)),
                                    isLoading: false,
                                    hasMore: false,
                                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                                    onNearEnd: { _ in },
                                    fixedColumnCount: Self.columns
                                )
                            }
                        }
                        .padding(.horizontal, Self.inset)
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .frame(width: 1920, alignment: .leading)
        .vividBackground()
        // Owns the 80pt inset itself, like the Home feed, instead of stacking
        // it on the system safe area.
        .ignoresSafeArea()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 36, weight: .semibold))
            .padding(.leading, Self.inset)
            .accessibilityAddTraits(.isHeader)
    }

    /// Uses the same collection row as Home, which keeps left and right
    /// movement smooth by reusing cells instead of building SwiftUI cards.
    private func rail(title: String, items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            CollectionHStack(uniqueElements: items, layout: .selfSizingSameSize(rows: 1)) { item in
                TVMediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    posterThumbhash: item.posterThumbhash,
                    year: item.year,
                    userState: item.userState,
                    action: { router.navigate(to: .itemDetail(browseItem: item)) },
                    // Same size as Home posters, like More Like This.
                    cardWidth: VividTheme.Skyline.densePosterCardWidth,
                    posterSize: railPosterSize,
                    contentId: item.contentId
                )
                .environmentObject(overlayStore)
            }
            .clipsToBounds(false)
            .insets(horizontal: Self.inset, vertical: 30)
            .itemSpacing(Self.columnSpacing)
            .scrollBehavior(.continuousLeadingEdge)
            .focusSection()
        }
    }

    /// Laid out like a TVCatalogGrid row: seven equal columns across the
    /// inset width, cards sized to fill them.
    private func firstGridRow(_ items: [BrowseItem]) -> some View {
        let width = (1920 - Self.inset * 2 - Self.columnSpacing * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
            / gridPosterSize.scale
        return HStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(items) { item in
                TVMediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    posterThumbhash: item.posterThumbhash,
                    year: item.year,
                    userState: item.userState,
                    overlayData: OverlayData.from(item),
                    action: { router.navigate(to: .itemDetail(browseItem: item)) },
                    cardWidth: width,
                    contentId: item.contentId
                )
                .frame(maxWidth: .infinity)
            }
            ForEach(items.count..<Self.columns, id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }
}

// MARK: - Settings editor

struct TVStudiosNetworksSettingsView: View {
    @State private var store = StudiosNetworksStore.shared
    @State private var movingID: String?
    @FocusState private var focus: Target?
    @Environment(\.dismiss) private var dismiss

    private enum Target: Hashable { case done, slot(String), pick(String), reset }

    private let previewSpacing: CGFloat = 24
    private var previewTileWidth: CGFloat {
        (TVSettingsLayout.contentWidth - previewSpacing * CGFloat(StudiosNetworksStore.maxPicks - 1))
            / CGFloat(StudiosNetworksStore.maxPicks)
    }

    private var subtitle: String {
        switch store.status {
        case .needsTMDB: "Connect TMDb in Settings → Plugins → TMDb to use Studios & Networks."
        case .loading, .idle: "Matching your library with TMDb…"
        case .failed: "Couldn’t load from TMDb or your server. Check your connection and try again."
        case .ready where store.needsMorePicks:
            "Choose \(store.missingPicks) more to finish, or turn off Show on Home."
        case .ready: "Pinned under the Spotlight on Home. \(store.picks.count) of \(StudiosNetworksStore.maxPicks) chosen."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TVSettingsPageHeader(title: "Studios & Networks", subtitle: subtitle) {
                    Button("Done") { dismiss() }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($focus, equals: .done)
                        .disabled(store.needsMorePicks)
                }

                switch store.status {
                case .ready:
                    readyContent
                case .loading, .idle:
                    TVSettingsGroup {
                        VStack(spacing: 18) {
                            ProgressView()
                            if let progress = store.progressText {
                                Text(progress).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                    TVSettingsFooter(StudiosNetworksStore.firstLoadNotice)
                case .failed:
                    Button("Try Again") { Task { await store.loadIfNeeded() } }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                case .needsTMDB:
                    EmptyView()
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, 72)
            .padding(.vertical, 36)
        }
        .tvSettingsPageSurface()
        .defaultFocus($focus, .done)
        .task { await store.loadIfNeeded() }
        .onExitCommand {
            if movingID != nil { movingID = nil } else if !store.needsMorePicks { dismiss() }
        }
        .onAppear { store.beginEditing() }
        .onDisappear { store.endEditing() }
    }

    @ViewBuilder
    private var readyContent: some View {
        TVSettingsGroup {
            TVSettingsToggleRow(title: "Show on Home", isOn: store.isEnabled) {
                store.setEnabled(!store.isEnabled)
            }
        }

        TVSettingsSectionHeader("PREVIEW")
        preview
        TVSettingsFooter(movingID == nil
            ? "Press and hold a tile to rearrange. Changes save automatically."
            : "Move left or right, then press centre to drop. Press Play/Pause to remove.")

        pickSection(title: "NETWORKS", kind: .network)
        pickSection(title: "STUDIOS", kind: .studio)
        TVSettingsFooter("Counts are titles in your library matched with TMDb’s most popular for each. Brands need at least \(StudiosNetworksStore.minimumCount).")

        Button("Reset to Automatic") { store.resetToAutomatic() }
            .buttonStyle(TVHomeSectionsControlButtonStyle())
            .focused($focus, equals: .reset)
            .frame(maxWidth: .infinity)
    }

    // MARK: Preview with arrange mode

    private var preview: some View {
        HStack(spacing: previewSpacing) {
            // Keyed by brand so the picked-up tile keeps its identity, and
            // its focus, as it moves between slots.
            ForEach(store.picks, id: \.self) { id in
                slot(id)
            }
            ForEach(store.picks.count..<StudiosNetworksStore.maxPicks, id: \.self) { _ in
                emptySlot
            }
        }
        .focusSection()
        .animation(.easeInOut(duration: 0.2), value: store.picks)
    }

    private func tileFace(_ id: String) -> some View {
        TVStudioNetworkTile(id: id, width: previewTileWidth)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func slot(_ id: String) -> some View {
        let name = store.brand(id)?.name ?? id
        let isMoving = movingID == id
        // One button for both states. Swapping it for another view when the
        // tile is picked up tears down the focused view, and focus falls back
        // to Done before the tile can move. The picked-up tile keeps the
        // normal card focus look and wobbles; centre places it.
        Button { if isMoving { movingID = nil } } label: {
            tileFace(id)
                .opacity(movingID != nil && !isMoving ? 0.8 : 1)
                .modifier(ProfileArrangeWobble(active: movingID != nil))
        }
        .buttonStyle(.card)
        .focused($focus, equals: .slot(id))
        .disabled(movingID != nil && !isMoving)
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            if movingID == nil { movingID = id }
        })
        .onMoveCommand { direction in
            guard isMoving else { return }
            switch direction {
            case .left: store.move(id, by: -1)
            case .right: store.move(id, by: 1)
            default: break
            }
        }
        .onPlayPauseCommand {
            guard isMoving else { return }
            store.toggle(id)
            movingID = nil
        }
        .accessibilityLabel(isMoving ? "Move \(name). Move left or right, then press centre to drop." : name)
        .accessibilityAction(named: "Rearrange") { movingID = id }
    }

    private var emptySlot: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .frame(width: previewTileWidth, height: previewTileWidth * 9 / 16)
            .overlay(Image(systemName: "plus").font(.system(size: 28, weight: .semibold)).opacity(0.45))
            .accessibilityLabel("Empty slot")
    }

    // MARK: Pick grid

    private func pickSection(title: String, kind: StudioNetworkBrand.Kind) -> some View {
        let brands = StudiosNetworksStore.catalogue.filter { $0.kind == kind }
        let width = (TVSettingsLayout.contentWidth - 24 * 3) / 4
        return VStack(alignment: .leading, spacing: 16) {
            TVSettingsSectionHeader(title)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 24), count: 4),
                      alignment: .leading, spacing: 36) {
                ForEach(brands) { brand in
                    pickTile(brand, width: width)
                }
            }
            .focusSection()
            .disabled(movingID != nil)
        }
    }

    private func pickTile(_ brand: StudioNetworkBrand, width: CGFloat) -> some View {
        let picked = store.picks.contains(brand.id)
        let count = store.count(brand.id)
        let eligible = store.isEligible(brand.id)
        let unavailable = !eligible || (store.picks.count >= StudiosNetworksStore.maxPicks && !picked)
        return VStack(alignment: .leading, spacing: 10) {
            Button { store.toggle(brand.id) } label: {
                TVStudioNetworkTile(id: brand.id, width: width)
                    .overlay(alignment: .topTrailing) {
                        if picked { WatchedCheckPill().padding(10) }
                    }
            }
            .buttonStyle(.card)
            .focused($focus, equals: .pick(brand.id))
            .disabled(unavailable)
            .opacity(unavailable ? 0.4 : 1)
            .accessibilityLabel("\(brand.name), \(count) titles\(picked ? ", chosen" : "")")

            Text(brand.name).font(.system(size: 22, weight: .semibold))
            Text(Self.countLabel(count, eligible: eligible))
                .font(.system(size: 19))
                .opacity(0.6)
        }
    }

    static func countLabel(_ count: Int, eligible: Bool) -> String {
        if eligible { return "\(count) titles" }
        return count == 0 ? "None in your library" : "Only \(count) titles"
    }
}
#endif
