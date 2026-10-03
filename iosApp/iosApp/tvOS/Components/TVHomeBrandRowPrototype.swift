#if os(tvOS)
import SwiftUI

// PROTOTYPE ONLY, not for the PR: Apple TV views for Studios & Networks. Data
// lives in Components/BrandPrototypeStore.swift.

private struct BrandTileFace: View {
    let id: String
    let width: CGFloat
    @State private var store = TVBrandPrototypeStore.shared

    var body: some View {
        BrandLogo(url: store.results[id]?.logoURL, name: store.info(id)?.name ?? id,
                  knocksOutText: store.info(id)?.knocksOutLogoText ?? false)
            .frame(maxWidth: width * 0.62, maxHeight: width * 9 / 16 * 0.42)
            .frame(width: width, height: width * 9 / 16)
            .background(Color.white.opacity(0.06))
    }
}

// MARK: - Home row

struct TVHomeBrandRowPrototype: View {
    let enterRequest: Int
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    var onFocused: () -> Void = {}

    @State private var store = TVBrandPrototypeStore.shared
    @State private var tmdb = TVTMDbStore.shared
    @FocusState private var focusedTile: String?
    @State private var lastTile: String?
    @Environment(AppRouter.self) private var router

    private static let spacing: CGFloat = 30

    static func tileWidth(rowWidth: CGFloat) -> CGFloat {
        (rowWidth - spacing * CGFloat(TVBrandPrototypeStore.maxPicks - 1)) / CGFloat(TVBrandPrototypeStore.maxPicks)
    }

    var body: some View {
        Group {
            if store.showsRow {
                GeometryReader { proxy in
                    // Matches the hero card: 60pt inset each side.
                    let tileWidth = Self.tileWidth(rowWidth: proxy.size.width - 120)
                    HStack(spacing: Self.spacing) {
                        ForEach(store.picks, id: \.self) { id in
                            Button { router.navigate(to: .brandPrototype(brandId: id)) } label: {
                                BrandTileFace(id: id, width: tileWidth)
                            }
                            .buttonStyle(.card)
                            .focused($focusedTile, equals: id)
                            .accessibilityLabel(store.info(id)?.name ?? id)
                        }
                    }
                    .padding(.horizontal, 60)
                    .focusSection()
                    .onMoveCommand { direction in
                        guard focusedTile != nil else { return }
                        if direction == .down { onMoveDown() }
                        if direction == .up { onMoveUp() }
                    }
                    .onChange(of: focusedTile) { _, tile in
                        if let tile { lastTile = tile; onFocused() }
                    }
                    .onChange(of: enterRequest) { _, _ in
                        focusedTile = lastTile.flatMap { store.picks.contains($0) ? $0 : nil } ?? store.picks.first
                    }
                }
                .frame(height: Self.tileWidth(rowWidth: 1920 - 120) * 9 / 16)
            }
        }
    }
}

// MARK: - Brand page

struct TVBrandPagePrototype: View {
    let brandId: String
    @State private var store = TVBrandPrototypeStore.shared
    @Environment(AppRouter.self) private var router

    private var info: BrandTileInfo? { store.info(brandId) }
    private var result: BrandResult { store.results[brandId] ?? BrandResult() }

    private var rows: [(title: String, items: [BrowseItem])] {
        // Shows with a new season or episodes in the past year, keeping the
        // series' main poster. The grid below still lists every show.
        // Networks show what's new; studios release only a few films a year,
        // so their pages keep the all-time most popular.
        let isStudio = info?.kind == .studio
        let series = ("Popular Series", isStudio ? result.series : result.recentSeries)
        let movies = ("Popular Movies", isStudio ? result.movies : result.recentMovies)
        let ordered = isStudio ? [movies, series] : [series, movies]
        return ordered
            .filter { $0.1.count >= TVBrandPrototypeStore.minimumCount }
            .map { ($0.0, Array($0.1.prefix(TVBrandPrototypeStore.rowLimit))) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 48) {
                header
                if store.status == .loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(rows, id: \.title) { row in
                    rail(title: row.title, items: row.items)
                }
                if !result.all.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("All in Your Library")
                            .font(.system(size: 36, weight: .semibold))
                            .padding(.leading, 80)
                        libraryGrid(Array(result.all.prefix(100)))
                        .padding(.horizontal, 80)
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .frame(width: 1920, alignment: .leading)
        .vividBackground()
        // Like the Home feed: own the 80pt inset instead of stacking it on
        // the system safe area.
        .ignoresSafeArea()
        .task { await store.loadIfNeeded() }
    }

    private var header: some View {
        BrandLogo(url: result.logoURL, name: info?.name ?? brandId, knocksOutText: info?.knocksOutLogoText ?? false)
            .frame(maxWidth: 480, maxHeight: 150)
            .frame(maxWidth: .infinity)
            .padding(.top, 110)
            .padding(.bottom, 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(info?.name ?? brandId)
    }

    /// Built eagerly (at most 100 posters) so a Down press from the last rail
    /// always finds the first grid row, even before it has scrolled on screen.
    private func libraryGrid(_ items: [BrowseItem]) -> some View {
        let columns = 7
        let spacing: CGFloat = 40
        // TVMediaCard scales by the Poster Size setting, so divide it back out
        // (as TVCatalogGrid does) to keep seven columns inside the screen.
        let cardWidth = (1920 - 160 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            / UICustomizationPreferences.shared.cardPresentation.posterSize.scale
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        return VStack(alignment: .leading, spacing: 60) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[index]) { item in
                        TVMediaCard(
                            title: item.title,
                            posterUrl: item.posterUrl ?? "",
                            posterThumbhash: item.posterThumbhash,
                            year: item.year,
                            userState: item.userState,
                            action: { router.navigate(to: .itemDetail(browseItem: item)) },
                            cardWidth: cardWidth,
                            contentId: item.contentId
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            }
        }
    }

    private func rail(title: String, items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 36, weight: .semibold))
                .padding(.leading, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(items) { item in
                        TVMediaCard(
                            title: item.title,
                            posterUrl: item.posterUrl ?? "",
                            posterThumbhash: item.posterThumbhash,
                            year: item.year,
                            userState: item.userState,
                            action: { router.navigate(to: .itemDetail(browseItem: item)) },
                            contentId: item.contentId
                        )
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }
}

// MARK: - Settings editor

struct TVStudiosNetworksSettingsView: View {
    @State private var store = TVBrandPrototypeStore.shared
    @State private var movingID: String?
    @FocusState private var focus: Target?
    @Environment(\.dismiss) private var dismiss

    private enum Target: Hashable { case done, slot(String), pick(String), reset }

    private let previewSpacing: CGFloat = 24
    private var previewTileWidth: CGFloat {
        (TVSettingsLayout.contentWidth - previewSpacing * CGFloat(TVBrandPrototypeStore.maxPicks - 1))
            / CGFloat(TVBrandPrototypeStore.maxPicks)
    }

    private var subtitle: String {
        switch store.status {
        case .needsTMDB: "Connect TMDb in Settings → Plugins → TMDb to use Studios & Networks."
        case .loading, .idle: "Matching your library with TMDb…"
        case .failed: "Couldn’t load from TMDb or your server. \(store.lastError ?? "")"
        case .ready: "Pinned under the hero on Home. \(store.picks.count) of \(TVBrandPrototypeStore.maxPicks) chosen."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TVSettingsPageHeader(title: "Studios & Networks", subtitle: subtitle) {
                    Button("Done") { dismiss() }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($focus, equals: .done)
                }

                if store.status == .ready {
                    TVSettingsGroup {
                        TVSettingsToggleRow(title: "Show on Home", isOn: store.isEnabled) {
                            store.isEnabled.toggle()
                        }
                    }

                    TVSettingsSectionHeader("PREVIEW")
                    preview
                    TVSettingsFooter(movingID == nil
                        ? "Press and hold a tile to rearrange. Changes save automatically."
                        : "Move left or right, then press centre to drop. Press Play/Pause to remove.")

                    pickSection(title: "NETWORKS", kind: .network)
                    pickSection(title: "STUDIOS", kind: .studio)
                    TVSettingsFooter("Counts are titles in your library matched with TMDb’s most popular for each. Brands need at least \(TVBrandPrototypeStore.minimumCount).")

                    Button("Reset to Automatic") { store.resetToAutomatic() }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($focus, equals: .reset)
                        .frame(maxWidth: .infinity)
                } else if store.status == .loading || store.status == .idle {
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
                    TVSettingsFooter(TVBrandPrototypeStore.firstLoadNotice)
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
            if movingID != nil { movingID = nil } else { dismiss() }
        }
    }

    // MARK: Preview with arrange mode

    private var preview: some View {
        HStack(spacing: previewSpacing) {
            ForEach(0..<TVBrandPrototypeStore.maxPicks, id: \.self) { index in
                if index < store.picks.count {
                    slot(store.picks[index])
                } else {
                    emptySlot
                }
            }
        }
        .focusSection()
        .animation(.easeInOut(duration: 0.2), value: store.picks)
    }

    private func tileFace(_ id: String) -> some View {
        BrandTileFace(id: id, width: previewTileWidth)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func slot(_ id: String) -> some View {
        if let moving = movingID {
            if moving == id {
                Button { movingID = nil } label: {
                    tileFace(id)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white, lineWidth: 3))
                        .scaleEffect(1.08)
                        .modifier(ProfileArrangeWobble(active: true))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focused($focus, equals: .slot(id))
                .onAppear { focus = .slot(id) }
                .onMoveCommand { direction in
                    switch direction {
                    case .left: store.move(id, by: -1)
                    case .right: store.move(id, by: 1)
                    default: break
                    }
                }
                .onPlayPauseCommand {
                    store.toggle(id)
                    movingID = nil
                }
                .accessibilityLabel("Move \(store.info(id)?.name ?? id). Move left or right, then press centre to drop.")
            } else {
                tileFace(id)
                    .opacity(0.8)
                    .modifier(ProfileArrangeWobble(active: true))
            }
        } else {
            Button {} label: { tileFace(id) }
                .buttonStyle(.card)
                .focused($focus, equals: .slot(id))
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in movingID = id })
                .accessibilityLabel(store.info(id)?.name ?? id)
                .accessibilityAction(named: "Rearrange") { movingID = id }
        }
    }

    private var emptySlot: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .frame(width: previewTileWidth, height: previewTileWidth * 9 / 16)
            .overlay(Image(systemName: "plus").font(.system(size: 28, weight: .semibold)).opacity(0.45))
            .accessibilityLabel("Empty slot")
    }

    // MARK: Pick grid

    private func pickSection(title: String, kind: BrandTileInfo.Kind) -> some View {
        let items = TVBrandPrototypeStore.catalogue.filter { $0.kind == kind }
        let width = (TVSettingsLayout.contentWidth - 24 * 3) / 4
        return VStack(alignment: .leading, spacing: 16) {
            TVSettingsSectionHeader(title)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 24), count: 4),
                      alignment: .leading, spacing: 36) {
                ForEach(items) { info in
                    pickTile(info, width: width)
                }
            }
            .focusSection()
            .disabled(movingID != nil)
        }
    }

    private func pickTile(_ info: BrandTileInfo, width: CGFloat) -> some View {
        let picked = store.picks.contains(info.id)
        let count = store.count(info.id)
        let eligible = store.isEligible(info.id)
        let full = store.picks.count >= TVBrandPrototypeStore.maxPicks
        let unavailable = !eligible || (full && !picked)
        return VStack(alignment: .leading, spacing: 10) {
            Button { store.toggle(info.id) } label: {
                BrandTileFace(id: info.id, width: width)
                    .overlay(alignment: .topTrailing) {
                        if picked { WatchedCheckPill().padding(10) }
                    }
            }
            .buttonStyle(.card)
            .focused($focus, equals: .pick(info.id))
            .disabled(unavailable)
            .opacity(unavailable ? 0.4 : 1)
            .accessibilityLabel("\(info.name), \(count) titles\(picked ? ", chosen" : "")")

            Text(info.name).font(.system(size: 22, weight: .semibold))
            Text(eligible ? "\(count) titles" : count == 0 ? "None in your library" : "Only \(count) titles")
                .font(.system(size: 19))
                .opacity(0.6)
        }
    }
}
#endif
