#if os(iOS)
import SwiftUI

// PROTOTYPE ONLY, not for the PR: iPhone and iPad views for Studios &
// Networks. Data lives in Components/BrandPrototypeStore.swift.

private struct PhoneBrandTileFace: View {
    let id: String
    let width: CGFloat
    @State private var store = TVBrandPrototypeStore.shared

    var body: some View {
        BrandLogo(url: store.results[id]?.logoURL, name: store.info(id)?.name ?? id,
                  knocksOutText: store.info(id)?.knocksOutLogoText ?? false)
            .frame(maxWidth: width * 0.62, maxHeight: width * 9 / 16 * 0.42)
            .frame(width: width, height: width * 9 / 16)
            .background(Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: HomeFeedMetrics.stillRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HomeFeedMetrics.stillRadius, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - Home row

/// No header, scrolls like the other Home rows. Tiles are half the width of a
/// Continue Watching still.
struct PhoneHomeBrandRowPrototype: View {
    @State private var store = TVBrandPrototypeStore.shared
    @Environment(AppRouter.self) private var router

    static let tileWidth = HomeFeedMetrics.stillWidth / 2

    var body: some View {
        if store.showsRow {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: HomeFeedMetrics.cardSpacing) {
                    ForEach(store.picks, id: \.self) { id in
                        Button { router.navigate(to: .brandPrototype(brandId: id)) } label: {
                            PhoneBrandTileFace(id: id, width: Self.tileWidth)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(store.info(id)?.name ?? id)
                    }
                }
            }
            .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
        }
    }
}

// MARK: - Brand page

struct PhoneBrandPagePrototype: View {
    let brandId: String
    @State private var store = TVBrandPrototypeStore.shared
    @Environment(AppRouter.self) private var router

    private var info: BrandTileInfo? { store.info(brandId) }
    private var result: BrandResult { store.results[brandId] ?? BrandResult() }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: HomeFeedMetrics.sectionSpacing) {
                BrandLogo(url: result.logoURL, name: info?.name ?? brandId,
                          knocksOutText: info?.knocksOutLogoText ?? false)
                    .frame(maxWidth: 220, maxHeight: 70)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(info?.name ?? brandId)

                if store.status == .loading {
                    ProgressView().frame(maxWidth: .infinity)
                }

                ForEach(store.pageRows(for: brandId), id: \.title) { row in
                    rail(title: row.title, items: row.items)
                }

                if !result.all.isEmpty {
                    VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
                        header("All in Your Library")
                        CatalogGrid(
                            items: Array(result.all.prefix(100)),
                            isLoading: false,
                            hasMore: false,
                            forcesThreeColumnsOnPhone: true,
                            onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                            onLoadMore: {}
                        )
                        .padding(.horizontal, VividTheme.padding)
                    }
                }
            }
            .padding(.bottom, HomeFeedMetrics.bottomRunway)
        }
        .vividBackground()
        // The logo is the title, as on Apple TV.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadIfNeeded() }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .padding(.horizontal, HomeFeedMetrics.gutter)
    }

    private func rail(title: String, items: [BrowseItem]) -> some View {
        VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
            header(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: HomeFeedMetrics.cardSpacing) {
                    ForEach(items) { item in
                        MediaCard(
                            title: item.title,
                            posterUrl: item.posterUrl ?? "",
                            thumbhash: item.posterThumbhash,
                            year: item.year,
                            userState: item.userState,
                            action: { router.navigate(to: .itemDetail(browseItem: item)) },
                            contentId: item.contentId,
                            cardWidthOverride: HomeFeedMetrics.posterWidth
                        )
                    }
                }
            }
            .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
        }
    }
}

// MARK: - Settings editor

struct PhoneStudiosNetworksSettingsView: View {
    @State private var store = TVBrandPrototypeStore.shared
    @State private var isArranging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusText: String {
        switch store.status {
        case .needsTMDB: "Connect TMDb in Settings → Plugins → TMDb to use Studios & Networks."
        case .loading, .idle: "Matching your library with TMDb…"
        case .failed: "Couldn’t load from TMDb or your server. \(store.lastError ?? "")"
        case .ready: "Pinned under the hero on Home. \(store.picks.count) of \(TVBrandPrototypeStore.maxPicks) chosen."
        }
    }

    var body: some View {
        List {
            SettingsPageHeader(title: "Studios & Networks", subtitle: statusText, systemImage: "square.grid.3x1.below.line.grid.1x2")
                .settingsPageHeaderRow()

            if store.status == .ready {
                Section {
                    Toggle("Show on Home", isOn: Binding(get: { store.isEnabled }, set: { store.isEnabled = $0 }))
                }

                Section {
                    preview
                        .listRowInsets(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
                } header: {
                    HStack {
                        PhoneSettingsSectionHeader("Preview")
                        Spacer()
                        if isArranging {
                            Button("Done") { withAnimation { isArranging = false } }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                } footer: {
                    Text(isArranging
                         ? "Drag tiles to reorder. Tap − to remove."
                         : "Touch and hold a tile to rearrange. Changes save automatically.")
                }

                pickSection(title: "Networks", kind: .network)
                pickSection(title: "Studios", kind: .studio)

                Section {
                    Button("Reset to Automatic") { store.resetToAutomatic() }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("Counts are titles in your library matched with TMDb’s most popular for each. Brands need at least \(TVBrandPrototypeStore.minimumCount).")
                }
            } else if store.status == .loading || store.status == .idle {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .settingsListChrome()
        .navigationTitle("")
        .task { await store.loadIfNeeded() }
    }

    // MARK: Preview with wiggle mode

    private var preview: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let width = (proxy.size.width - spacing * CGFloat(TVBrandPrototypeStore.maxPicks - 1))
                / CGFloat(TVBrandPrototypeStore.maxPicks)
            HStack(spacing: spacing) {
                ForEach(0..<TVBrandPrototypeStore.maxPicks, id: \.self) { index in
                    if index < store.picks.count {
                        slot(store.picks[index], index: index, width: width)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: width, height: width * 9 / 16)
                            .overlay(Image(systemName: "plus").font(.caption.weight(.semibold)).opacity(0.45))
                            .accessibilityLabel("Empty slot")
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.picks)
        }
        .aspectRatio(CGFloat(TVBrandPrototypeStore.maxPicks) * 16 / 9 * 0.93, contentMode: .fit)
    }

    private func slot(_ id: String, index: Int, width: CGFloat) -> some View {
        PhoneBrandTileFace(id: id, width: width)
            .modifier(ProfileArrangeWobble(active: isArranging))
            .overlay(alignment: .topLeading) {
                if isArranging {
                    Button { withAnimation { store.toggle(id) } } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                    .accessibilityLabel("Remove \(store.info(id)?.name ?? id)")
                }
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                withAnimation { isArranging = true }
            }
            .draggable(id) {
                PhoneBrandTileFace(id: id, width: width)
            }
            .dropDestination(for: String.self) { dropped, _ in
                guard let moving = dropped.first else { return false }
                withAnimation { store.place(moving, at: index) }
                return true
            }
            .accessibilityLabel(store.info(id)?.name ?? id)
            .accessibilityAction(named: "Move earlier") { store.move(id, by: -1) }
            .accessibilityAction(named: "Move later") { store.move(id, by: 1) }
    }

    // MARK: Pick grid

    private func pickSection(title: String, kind: BrandTileInfo.Kind) -> some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                      alignment: .leading, spacing: 16) {
                ForEach(TVBrandPrototypeStore.catalogue.filter { $0.kind == kind }) { info in
                    pickTile(info)
                }
            }
            .padding(.vertical, 6)
        } header: {
            PhoneSettingsSectionHeader(title)
        }
    }

    private func pickTile(_ info: BrandTileInfo) -> some View {
        let picked = store.picks.contains(info.id)
        let count = store.count(info.id)
        let eligible = store.isEligible(info.id)
        let full = store.picks.count >= TVBrandPrototypeStore.maxPicks
        let unavailable = !eligible || (full && !picked)
        return Button { withAnimation { store.toggle(info.id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { proxy in
                    PhoneBrandTileFace(id: info.id, width: proxy.size.width)
                        .overlay(alignment: .topTrailing) {
                            if picked { WatchedCheckPill().scaleEffect(0.8).padding(4) }
                        }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                Text(info.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(eligible ? "\(count) titles" : count == 0 ? "None in library" : "Only \(count) titles")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .accessibilityLabel("\(info.name), \(count) titles\(picked ? ", chosen" : "")")
    }
}
#endif
