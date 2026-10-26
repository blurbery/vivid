#if os(iOS)
import SwiftUI

/// A collection's poster, or a stack glyph when the server has none. Shared
/// by the Home row, the settings preview and the pick carousels.
private struct PhoneHomeCollectionPoster: View {
    let collection: LibraryCollection
    let width: CGFloat
    var cornerRadius: CGFloat = HomeFeedMetrics.posterRadius

    private var height: CGFloat { (width * HomeFeedMetrics.posterAspect).rounded() }

    var body: some View {
        Group {
            if let url = collection.posterUrl, !url.isEmpty {
                AsyncImageView(
                    url: url,
                    thumbhash: collection.posterThumbhash,
                    targetSize: CGSize(width: width, height: height),
                    contentMode: .fill
                )
            } else {
                ZStack {
                    Color.vividSurfaceVariant
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: width * 0.2, weight: .semibold))
                        .foregroundColor(.vividSecondaryText)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // The same hairline as Home's posters, so dark artwork keeps its edge.
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private func collectionCountLabel(_ collection: LibraryCollection) -> String? {
    collection.itemCount.map { String(localized: "\($0) titles") }
}

// MARK: - Home row

/// Always the last row on Home, outside the server's own rows. Posters
/// match the other Home rows and open the collection's page.
struct PhoneHomeCollectionsRow: View {
    @State private var store = HomeCollectionsStore.shared
    @State private var homeCards = TVHomeCardPreferences.shared
    @Environment(AppRouter.self) private var router

    var body: some View {
        if store.showsRow {
            VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
                HomeSectionHeader(title: String(localized: "Collections"))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: HomeFeedMetrics.cardSpacing) {
                        ForEach(store.rowCollections) { entry in
                            card(entry)
                        }
                    }
                    .scrollTargetLayout()
                    .phoneMediaRailBounds()
                }
                .scrollTargetBehavior(HorizontalMediaRailLayout.targetBehavior)
                .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
                .scrollClipDisabled()
            }
        }
    }

    private func card(_ entry: HomeCollection) -> some View {
        let width = HomeFeedMetrics.posterWidth * homeCards.presentation.posterSize.scale
        let caption = homeCards.presentation.caption
        return Button {
            router.navigate(to: .libraryCollection(
                libraryId: entry.libraryID, collectionId: entry.id,
                title: entry.collection.name, kind: .regular
            ))
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                PhoneHomeCollectionPoster(collection: entry.collection, width: width)
                if caption.showsTitle {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.collection.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.vividOnSurface)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if caption.showsMetadata, let count = collectionCountLabel(entry.collection) {
                            Text(count)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Color.vividOnSurface.opacity(0.5))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(libraryCollectionAccessibilityLabel(entry.collection))
    }
}

// MARK: - Settings

struct PhoneHomeCollectionsSettingsView: View {
    @State private var store = HomeCollectionsStore.shared
    @State private var isArranging = false
    // Drag state, as in Studios & Networks: a floating copy follows the
    // finger while a draft order previews the drop and saves on release.
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var draftOrder: [String] = []
    @State private var movingID: String?
    @State private var dragStartFrame: CGRect = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var previewWidth: CGFloat = 0
    @GestureState private var reorderGestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let previewSpace = "homeCollectionsPreview"
    /// Preview posters across before the grid wraps.
    private static let previewColumns = 5
    private static let pickWidth: CGFloat = 72

    private var statusText: String {
        switch store.status {
        case .needsAccount: String(localized: "Sign in to a server and choose a profile to use Collections.")
        case .loading, .idle: String(localized: "Loading your server’s collections…")
        case .failed: String(localized: "Couldn’t load your server’s collections. Check your connection and try again.")
        case .ready where store.collections.isEmpty: String(localized: "This server has no collections yet.")
        case .ready: String(localized: "The last row on Home. \(store.picks.count) of \(HomeCollectionsStore.maxPicks) chosen.")
        }
    }

    var body: some View {
        List {
            SettingsPageHeader(title: Text("Collections"), subtitle: Text(statusText), systemImage: "square.stack.3d.up")
                .settingsPageHeaderRow()

            switch store.status {
            case .ready:
                readyContent
            case .loading, .idle:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            case .failed:
                Section {
                    Button("Try Again") { Task { await store.loadIfNeeded(force: true) } }
                        .frame(maxWidth: .infinity)
                }
            case .needsAccount:
                EmptyView()
            }
        }
        .settingsListChrome()
        .navigationTitle("")
        .task { await store.loadIfNeeded(force: true) }
    }

    @ViewBuilder
    private var readyContent: some View {
        Section {
            Toggle("Show on Home", isOn: Binding(get: { store.isEnabled }, set: { store.setEnabled($0) }))
        }

        if !store.collections.isEmpty {
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
                     ? "Drag posters to reorder. Tap − to remove."
                     : "Touch and hold a poster to rearrange. Changes save automatically.")
            }

            Section {
                ForEach(Array(store.carousels.enumerated()), id: \.offset) { _, carousel in
                    pickCarousel(carousel)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                }
            } header: {
                PhoneSettingsSectionHeader("All Collections")
            } footer: {
                Text("Tap a collection to add it to Home or remove it. Up to \(HomeCollectionsStore.maxPicks) can be chosen.")
            }

            Section {
                Button("Reset to Automatic") { store.resetToAutomatic() }
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("Automatic shows the \(HomeCollectionsStore.maxPicks) collections with the most titles.")
            }
        }
    }

    // MARK: Preview with wiggle mode

    /// Five posters a row, wrapping onto new rows as more are picked, so
    /// every poster stays on screen and can be dragged to any slot.
    @ViewBuilder
    private var preview: some View {
        if displayedPicks.isEmpty {
            Text("Choose collections below to show them on Home.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            previewGrid
        }
    }

    private var previewGrid: some View {
        let spacing: CGFloat = 8
        let columns = Self.previewColumns
        let width = max(0, (previewWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: spacing), count: columns),
                         alignment: .leading, spacing: spacing) {
            // One grid keyed by collection, so a poster keeps its gesture
            // while the draft order moves it between slots.
            ForEach(displayedPicks, id: \.self) { id in
                if let entry = store.collection(id) {
                    slot(entry, width: width)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.picks)
        .coordinateSpace(name: Self.previewSpace)
        .onPreferenceChange(HomeCollectionTileFrames.self) { tileFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let movingID, let entry = store.collection(movingID) {
                PhoneHomeCollectionPoster(collection: entry.collection, width: dragStartFrame.width, cornerRadius: 6)
                    .scaleEffect(reduceMotion ? 1 : 1.08)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .position(x: dragStartFrame.midX + dragOffset.width,
                              y: dragStartFrame.midY + dragOffset.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: reorderGestureActive) { _, active in
            if !active { resetDrag() }
        }
        .onDisappear { resetDrag() }
    }

    private var displayedPicks: [String] {
        movingID == nil ? store.picks : draftOrder
    }

    private func slot(_ entry: HomeCollection, width: CGFloat) -> some View {
        let id = entry.id
        let name = entry.collection.name
        return PhoneHomeCollectionPoster(collection: entry.collection, width: width, cornerRadius: 6)
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
                    Color.clear.preference(key: HomeCollectionTileFrames.self,
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

    /// Hold to start wiggling, then keep dragging to move the poster. Once
    /// wiggling, a shorter hold picks a poster up so it can be dragged again.
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
                // Letting go away from the posters cancels.
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

    // MARK: Pick carousels

    /// Up to 20 small posters, A to Z, scrolling sideways. Posters only: the
    /// artwork says which collection it is, and VoiceOver reads the name.
    private func pickCarousel(_ carousel: [HomeCollection]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(carousel) { entry in
                    pickTile(entry)
                }
            }
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
    }

    private func pickTile(_ entry: HomeCollection) -> some View {
        let picked = store.isPicked(entry.id)
        let unavailable = !picked && store.picks.count >= HomeCollectionsStore.maxPicks
        let name = entry.collection.name
        return Button { withAnimation { store.toggle(entry.id) } } label: {
            PhoneHomeCollectionPoster(collection: entry.collection, width: Self.pickWidth, cornerRadius: 6)
                .overlay(alignment: .topTrailing) {
                    if picked { WatchedCheckPill().scaleEffect(0.8).padding(3) }
                }
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .accessibilityLabel(picked ? Text("\(name), chosen") : Text(name))
    }
}

private struct HomeCollectionTileFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#endif
