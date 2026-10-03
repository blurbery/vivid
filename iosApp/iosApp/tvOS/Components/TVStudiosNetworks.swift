#if os(tvOS)
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

/// Pinned under the Spotlight with no header. Five tiles span the hero's
/// width, so every tile is one left or right press away.
struct TVStudiosNetworksRow: View {
    /// Increments when the Spotlight hands focus down to this row.
    let enterRequest: Int
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onFocused: () -> Void

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
                        Button { router.navigate(to: .studioNetwork(brandId: id)) } label: {
                            TVStudioNetworkTile(id: id, width: tileWidth)
                        }
                        .buttonStyle(.card)
                        .focused($focusedTile, equals: id)
                        .accessibilityLabel(store.brand(id)?.name ?? id)
                    }
                }
                .padding(.horizontal, Self.heroInset)
                .focusSection()
                // Mirrors the Spotlight: this row makes the single focus claim
                // when moving to its neighbours.
                .onMoveCommand { direction in
                    guard focusedTile != nil else { return }
                    if direction == .down { onMoveDown() }
                    if direction == .up { onMoveUp() }
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
    @Environment(AppRouter.self) private var router

    private static let inset: CGFloat = 80
    private static let columns = 7
    private static let columnSpacing: CGFloat = 40

    private var brand: StudioNetworkBrand? { store.brand(brandId) }
    private var result: StudioNetworkResult { store.results[brandId] ?? StudioNetworkResult() }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 48) {
                StudioNetworkLogo(brand: brand, url: result.logoURL, fallbackName: brandId)
                    .frame(maxWidth: 480, maxHeight: 150)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 110)
                    .padding(.bottom, 20)
                    .accessibilityElement()
                    .accessibilityLabel(brand?.name ?? brandId)
                    .accessibilityAddTraits(.isHeader)

                ForEach(store.pageRows(for: brandId), id: \.title) { row in
                    rail(title: row.title, items: row.items)
                }

                if !result.all.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        sectionTitle("All in Your Library")
                        libraryGrid(result.all)
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
        .task { await store.loadIfNeeded() }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 36, weight: .semibold))
            .padding(.leading, Self.inset)
            .accessibilityAddTraits(.isHeader)
    }

    private func rail(title: String, items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Self.columnSpacing) {
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
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    /// Built eagerly (at most 100 posters) so a Down press from the last rail
    /// always finds the first grid row before it has scrolled on screen.
    private func libraryGrid(_ items: [BrowseItem]) -> some View {
        let columns = Self.columns
        // TVMediaCard scales by the Poster Size setting, so divide it back out
        // to keep seven columns inside the screen.
        let cardWidth = (1920 - Self.inset * 2 - Self.columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
            / UICustomizationPreferences.shared.cardPresentation.posterSize.scale
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        return VStack(alignment: .leading, spacing: 60) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: Self.columnSpacing) {
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
            if movingID != nil { movingID = nil } else { dismiss() }
        }
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
            ForEach(0..<StudiosNetworksStore.maxPicks, id: \.self) { index in
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
        TVStudioNetworkTile(id: id, width: previewTileWidth)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func slot(_ id: String) -> some View {
        let name = store.brand(id)?.name ?? id
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
                .accessibilityLabel("Move \(name). Move left or right, then press centre to drop.")
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
                .accessibilityLabel(name)
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
