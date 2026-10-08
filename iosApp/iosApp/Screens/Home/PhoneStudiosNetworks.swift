#if os(iOS)
import SwiftUI

/// Logo tile shared by the Home row, the settings preview and the pick grid.
private struct PhoneStudioNetworkTile: View {
    let id: String
    let width: CGFloat
    @State private var store = StudiosNetworksStore.shared

    var body: some View {
        StudioNetworkLogo(brand: store.brand(id), url: store.results[id]?.logoURL, fallbackName: id)
            .frame(maxWidth: width * 0.62, maxHeight: width * 9 / 16 * 0.42 * (store.brand(id)?.logoHeightScale ?? 1))
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

/// Pinned under the Spotlight with no header. Scrolls like the other Home
/// rows, with tiles half the width of a Continue Watching still at the
/// current Poster Size.
struct PhoneStudiosNetworksRow: View {
    @State private var store = StudiosNetworksStore.shared
    @State private var homeCards = TVHomeCardPreferences.shared
    @Environment(AppRouter.self) private var router

    private var tileWidth: CGFloat {
        HomeFeedMetrics.stillWidth * homeCards.presentation.posterSize.scale / 2
    }

    var body: some View {
        if store.showsRow {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: HomeFeedMetrics.cardSpacing) {
                    ForEach(store.picks, id: \.self) { id in
                        Button { router.navigate(to: .studioNetwork(brandId: id)) } label: {
                            PhoneStudioNetworkTile(id: id, width: tileWidth)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(store.brand(id)?.name ?? id)
                    }
                }
            }
            .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
        }
    }
}

// MARK: - Brand page

struct PhoneStudioNetworkPage: View {
    let brandId: String
    @State private var store = StudiosNetworksStore.shared
    @Environment(AppRouter.self) private var router

    private var brand: StudioNetworkBrand? { store.brand(brandId) }
    private var result: StudioNetworkResult { store.results[brandId] ?? StudioNetworkResult() }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: HomeFeedMetrics.sectionSpacing) {
                StudioNetworkLogo(brand: brand, url: result.logoURL, fallbackName: brandId)
                    .frame(maxWidth: 220, maxHeight: 70)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .accessibilityElement()
                    .accessibilityLabel(brand?.name ?? brandId)
                    .accessibilityAddTraits(.isHeader)

                ForEach(store.pageRows(for: brandId), id: \.title) { row in
                    rail(title: row.title, items: row.items)
                }

                if !result.all.isEmpty {
                    VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
                        header("All in Your Library")
                        CatalogGrid(
                            items: result.all,
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
            .accessibilityAddTraits(.isHeader)
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
    @State private var store = StudiosNetworksStore.shared
    @State private var isArranging = false
    // Drag state, as in the saved profile cards: a floating copy follows the
    // finger while a draft order previews the drop and saves on release.
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var draftOrder: [String] = []
    @State private var movingID: String?
    @State private var dragStartFrame: CGRect = .zero
    @State private var dragOffset: CGSize = .zero
    @GestureState private var reorderGestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let previewSpace = "studiosNetworksPreview"

    private var statusText: String {
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
        List {
            SettingsPageHeader(title: "Studios & Networks", subtitle: statusText, systemImage: "square.grid.3x1.below.line.grid.1x2")
                .settingsPageHeaderRow()

            switch store.status {
            case .ready:
                readyContent
            case .loading, .idle:
                Section {
                    VStack(spacing: 12) {
                        ProgressView()
                        if let progress = store.progressText {
                            Text(progress).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } footer: {
                    Label(StudiosNetworksStore.firstLoadNotice, systemImage: "exclamationmark.triangle.fill")
                }
            case .failed:
                Section {
                    Button("Try Again") { Task { await store.loadIfNeeded() } }
                        .frame(maxWidth: .infinity)
                }
            case .needsTMDB:
                EmptyView()
            }
        }
        .settingsListChrome()
        .navigationTitle("")
        // Six are required while the row shows on Home.
        .navigationBarBackButtonHidden(store.needsMorePicks)
        .onAppear { store.beginEditing() }
        .onDisappear { store.endEditing() }
        .task { await store.loadIfNeeded() }
    }

    @ViewBuilder
    private var readyContent: some View {
        Section {
            Toggle("Show on Home", isOn: Binding(get: { store.isEnabled }, set: { store.setEnabled($0) }))
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
            Text("Counts are titles in your library matched with TMDb’s most popular for each. Brands need at least \(StudiosNetworksStore.minimumCount).")
        }
    }

    // MARK: Preview with wiggle mode

    private var preview: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let width = (proxy.size.width - spacing * CGFloat(StudiosNetworksStore.maxPicks - 1))
                / CGFloat(StudiosNetworksStore.maxPicks)
            HStack(spacing: spacing) {
                // Keyed by brand so a tile keeps its gesture while the draft
                // order moves it between slots.
                ForEach(displayedPicks, id: \.self) { id in
                    slot(id, width: width)
                }
                ForEach(displayedPicks.count..<StudiosNetworksStore.maxPicks, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: width, height: width * 9 / 16)
                        .overlay(Image(systemName: "plus").font(.caption.weight(.semibold)).opacity(0.45))
                        .accessibilityLabel("Empty slot")
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.picks)
            .coordinateSpace(name: Self.previewSpace)
            .onPreferenceChange(StudioNetworkTileFrames.self) { tileFrames = $0 }
            .overlay(alignment: .topLeading) {
                if let movingID {
                    PhoneStudioNetworkTile(id: movingID, width: dragStartFrame.width)
                        .scaleEffect(reduceMotion ? 1 : 1.08)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        .position(x: dragStartFrame.midX + dragOffset.width,
                                  y: dragStartFrame.midY + dragOffset.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        // Five 16:9 tiles plus their gaps.
        .aspectRatio(CGFloat(StudiosNetworksStore.maxPicks) * 16 / 9 * 0.93, contentMode: .fit)
        .onChange(of: reorderGestureActive) { _, active in
            if !active { resetDrag() }
        }
        .onDisappear { resetDrag() }
    }

    private var displayedPicks: [String] {
        movingID == nil ? store.picks : draftOrder
    }

    private func slot(_ id: String, width: CGFloat) -> some View {
        let name = store.brand(id)?.name ?? id
        return PhoneStudioNetworkTile(id: id, width: width)
            .modifier(ProfileArrangeWobble(active: isArranging))
            .opacity(movingID == id ? 0 : 1)
            .overlay(alignment: .topLeading) {
                if isArranging && movingID == nil {
                    Button { withAnimation { store.toggle(id) } } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                    .accessibilityLabel("Remove \(name)")
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: StudioNetworkTileFrames.self,
                        value: [id: geometry.frame(in: .named(Self.previewSpace))])
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(reorderGesture(for: id))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name)
            .accessibilityAction(named: "Move earlier") { store.move(id, by: -1) }
            .accessibilityAction(named: "Move later") { store.move(id, by: 1) }
    }

    /// Hold to start wiggling, then keep dragging to move the tile. Once
    /// wiggling, a shorter hold picks a tile up so it can be dragged again.
    private func reorderGesture(for id: String) -> some Gesture {
        LongPressGesture(minimumDuration: isArranging ? 0.15 : 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.previewSpace)))
            .updating($reorderGestureActive) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isArranging { withAnimation { isArranging = true } }
                if movingID == nil {
                    dragStartFrame = tileFrames[id] ?? .zero
                    draftOrder = store.picks
                    movingID = id
                }
                guard movingID == id, let drag else { return }
                dragOffset = drag.translation
                previewReorder(at: drag.location, moving: id)
            }
            .onEnded { value in
                defer { resetDrag() }
                // Letting go away from the tiles cancels, as with saved
                // profile cards.
                guard movingID == id, case .second(true, let drag?) = value,
                      tileFrames.values.contains(where: { $0.insetBy(dx: -6, dy: -6).contains(drag.location) }),
                      let index = draftOrder.firstIndex(of: id),
                      draftOrder != store.picks else { return }
                store.place(id, at: index)
            }
    }

    private func previewReorder(at point: CGPoint, moving id: String) {
        guard let target = draftOrder.first(where: {
            $0 != id && tileFrames[$0]?.contains(point) == true
        }), let from = draftOrder.firstIndex(of: id),
              let to = draftOrder.firstIndex(of: target) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            draftOrder.remove(at: from)
            draftOrder.insert(id, at: to)
        }
    }

    private func resetDrag() {
        movingID = nil
        draftOrder = []
        dragOffset = .zero
        dragStartFrame = .zero
    }

    // MARK: Pick grid

    private func pickSection(title: String, kind: StudioNetworkBrand.Kind) -> some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                      alignment: .leading, spacing: 16) {
                ForEach(StudiosNetworksStore.catalogue.filter { $0.kind == kind }) { brand in
                    pickTile(brand)
                }
            }
            .padding(.vertical, 6)
        } header: {
            PhoneSettingsSectionHeader(title)
        }
    }

    private func pickTile(_ brand: StudioNetworkBrand) -> some View {
        let picked = store.picks.contains(brand.id)
        let count = store.count(brand.id)
        let eligible = store.isEligible(brand.id)
        let unavailable = !eligible || (store.picks.count >= StudiosNetworksStore.maxPicks && !picked)
        return Button { withAnimation { store.toggle(brand.id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { proxy in
                    PhoneStudioNetworkTile(id: brand.id, width: proxy.size.width)
                        .overlay(alignment: .topTrailing) {
                            if picked { WatchedCheckPill().scaleEffect(0.8).padding(4) }
                        }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                Text(brand.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(eligible ? "\(count) titles" : count == 0 ? "None in library" : "Only \(count) titles")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .accessibilityLabel("\(brand.name), \(count) titles\(picked ? ", chosen" : "")")
    }
}

private struct StudioNetworkTileFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#endif
