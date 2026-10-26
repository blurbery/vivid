#if os(tvOS)
import SwiftUI

/// A collection's poster, or a gradient with a stack glyph when the server
/// has none. Shared by the settings preview and the pick carousels.
private struct TVHomeCollectionPoster: View {
    let collection: LibraryCollection
    let width: CGFloat
    var loadsArtwork = true

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        Group {
            if !loadsArtwork {
                Color.white.opacity(0.06)
            } else if let url = collection.posterUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: width, height: height),
                    thumbhash: collection.posterThumbhash,
                    contentMode: .fill
                )
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(hue: hue, saturation: 0.5, brightness: 0.42),
                                 Color(hue: hue, saturation: 0.32, brightness: 0.22)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "square.stack.fill")
                        .font(.system(size: width * 0.24, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(10), style: .continuous))
    }

    /// Stable hue, as on For You's collection cards.
    private var hue: Double {
        var hasher = Hasher()
        hasher.combine(collection.id)
        return Double(UInt(bitPattern: hasher.finalize()) % 360) / 360
    }
}

// MARK: - Home row

/// Always the last row on Home, below the server's own rows. Cards match
/// the other Home rows and open the collection's page.
struct TVHomeCollectionsRow: View {
    /// Increments when Home returns focus here from a collection's page.
    let enterRequest: Int
    let onFocused: () -> Void
    /// Called just before a card opens its page, so Home can return focus here.
    let onOpen: () -> Void

    @State private var store = HomeCollectionsStore.shared
    @FocusState private var focusedCard: String?
    @State private var lastCard: String?
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: TVHomeRowGeometry.headingSpacing) {
            Text("Collections")
                .font(.system(size: 36, weight: .semibold))
                .lineLimit(1)
                .frame(height: TVHomeRowGeometry.headingHeight)
                .padding(.horizontal, VividTheme.safePadding)

            // Every card is built up front, so focus can return to one
            // scrolled out of view and the focus engine scrolls to it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(store.rowCollections) { entry in
                        MediaCard(
                            title: entry.collection.name,
                            posterUrl: entry.collection.posterUrl ?? "",
                            thumbhash: entry.collection.posterThumbhash,
                            subtitle: entry.collection.itemCount.map { String(localized: "\($0) titles") },
                            action: {
                                lastCard = entry.id
                                onOpen()
                                router.navigate(to: .libraryCollection(
                                    libraryId: entry.libraryID, collectionId: entry.id,
                                    title: entry.collection.name, kind: .regular
                                ))
                            },
                            focusedItemId: $focusedCard,
                            contentId: entry.id,
                            cardWidthOverride: VividTheme.Skyline.densePosterCardWidth
                        )
                    }
                }
                .padding(.vertical, TVHomeRowGeometry.cardPadding)
            }
            .contentMargins(.horizontal, VividTheme.safePadding, for: .scrollContent)
            // Keeps the focused card's lift from being cut off.
            .scrollClipDisabled()
        }
        // Up and Down are native, like moving between the other Home rows.
        .focusSection()
        .onChange(of: focusedCard) { _, card in
            guard let card else { return }
            lastCard = card
            onFocused()
        }
        .onChange(of: enterRequest) { _, _ in
            let ids = store.rowCollections.map(\.id)
            focusedCard = lastCard.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        }
    }
}

// MARK: - Settings

struct TVHomeCollectionsSettingsView: View {
    @State private var store = HomeCollectionsStore.shared
    @State private var movingID: String?
    /// The carousel holding focus, so only nearby carousels load artwork.
    @State private var focusedCarousel = 0
    @FocusState private var focus: Target?
    @Environment(\.dismiss) private var dismiss

    private enum Target: Hashable { case done, slot(String), pick(String), reset }

    private let previewSpacing: CGFloat = TVSettingsLayout.scaled(24)
    private let pickSpacing: CGFloat = TVSettingsLayout.scaled(20)
    /// Room around the clipped strips for a focused poster's lift.
    private let gutter: CGFloat = TVSettingsLayout.scaled(24)
    private var previewWidth: CGFloat {
        (TVSettingsLayout.contentWidth - previewSpacing * 6) / 7
    }
    private var pickWidth: CGFloat {
        (TVSettingsLayout.contentWidth - pickSpacing * 7) / 8
    }

    private var subtitle: String {
        switch store.status {
        case .needsAccount: String(localized: "Sign in to a server and choose a profile to use Collections.")
        case .loading, .idle: String(localized: "Loading your server’s collections…")
        case .failed: String(localized: "Couldn’t load your server’s collections. Check your connection and try again.")
        case .ready where store.collections.isEmpty: String(localized: "This server has no collections yet.")
        case .ready: String(localized: "The last row on Home. \(store.picks.count) of \(HomeCollectionsStore.maxPicks) chosen.")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(28)) {
                TVSettingsPageHeader(title: Text("Collections"), subtitle: Text(subtitle)) {
                    Button("Done") { dismiss() }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($focus, equals: .done)
                }

                switch store.status {
                case .ready:
                    readyContent
                case .loading, .idle:
                    TVSettingsGroup {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, TVSettingsLayout.scaled(28))
                    }
                case .failed:
                    Button("Try Again") { Task { await store.loadIfNeeded(force: true) } }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                case .needsAccount:
                    EmptyView()
                }
            }
            .frame(maxWidth: TVSettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, TVSettingsLayout.scaled(72))
            .padding(.vertical, TVSettingsLayout.scaled(36))
        }
        .tvSettingsPageSurface()
        .defaultFocus($focus, .done)
        .task { await store.loadIfNeeded(force: true) }
        .onExitCommand {
            if movingID != nil { movingID = nil } else { dismiss() }
        }
        .onChange(of: focus) { _, target in
            guard case .pick(let id)? = target,
                  let index = store.carousels.firstIndex(where: { $0.contains { $0.id == id } }) else { return }
            focusedCarousel = index
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        TVSettingsGroup {
            TVSettingsToggleRow(title: "Show on Home", isOn: store.isEnabled) {
                store.setEnabled(!store.isEnabled)
            }
        }

        if !store.collections.isEmpty {
            TVSettingsSectionHeader("PREVIEW")
            preview
            TVSettingsFooter(movingID == nil
                ? "Press and hold a poster to rearrange. Changes save automatically."
                : "Move left or right, then press centre to drop. Press Play/Pause to remove.")

            TVSettingsSectionHeader("ALL COLLECTIONS")
            // Not lazy: carousels below the screen must exist for Down to
            // land on them, otherwise focus could skip to Reset.
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(32)) {
                ForEach(Array(store.carousels.enumerated()), id: \.offset) { index, carousel in
                    pickCarousel(carousel, loadsArtwork: abs(index - focusedCarousel) <= 2)
                }
            }
            .disabled(movingID != nil)
            TVSettingsFooter("Select a collection to add it to Home or remove it. Up to \(HomeCollectionsStore.maxPicks) can be chosen. Automatic shows the \(HomeCollectionsStore.maxPicks) collections with the most titles.")

            Button("Reset to Automatic") { store.resetToAutomatic() }
                .buttonStyle(TVHomeSectionsControlButtonStyle())
                .focused($focus, equals: .reset)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Preview with arrange mode

    /// Seven posters across, scrolling sideways to the rest. It stays
    /// clipped, so posters scrolled to the left never cover the settings
    /// categories.
    @ViewBuilder
    private var preview: some View {
        if store.picks.isEmpty {
            RoundedRectangle(cornerRadius: TVSettingsLayout.scaled(12), style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .frame(height: previewWidth * 1.5)
                .overlay(
                    Text("Choose collections below to show them on Home.")
                        .font(.tvSettings(24))
                        .opacity(0.6)
                )
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: previewSpacing) {
                        // Keyed by collection so the picked-up poster keeps
                        // its identity, and its focus, as it moves.
                        ForEach(store.picks, id: \.self) { id in
                            if let entry = store.collection(id) {
                                slot(entry).id(id)
                            }
                        }
                    }
                }
                .contentMargins(gutter, for: .scrollContent)
                .padding(-gutter)
                .focusSection()
                .animation(.easeInOut(duration: 0.2), value: store.picks)
                // Moving a picked-up poster doesn't move focus, so the focus
                // engine won't scroll; keep the poster in view as it travels.
                .onChange(of: store.picks) { _, _ in
                    guard let movingID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(movingID) }
                }
            }
        }
    }

    @ViewBuilder
    private func slot(_ entry: HomeCollection) -> some View {
        let id = entry.id
        let name = entry.collection.name
        let isMoving = movingID == id
        // One button for both states. Swapping it for another view when the
        // poster is picked up tears down the focused view, and focus falls
        // back to Done before the poster can move.
        Button { if isMoving { movingID = nil } } label: {
            TVHomeCollectionPoster(collection: entry.collection, width: previewWidth)
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
        .accessibilityLabel(isMoving ? Text("Move \(name). Move left or right, then press centre to drop.") : Text(name))
        .accessibilityAction(named: "Rearrange") { movingID = id }
    }

    // MARK: Pick carousels

    /// Up to 20 small posters, A to Z, scrolling sideways.
    private func pickCarousel(_ carousel: [HomeCollection], loadsArtwork: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: pickSpacing) {
                ForEach(carousel) { entry in
                    pickTile(entry, loadsArtwork: loadsArtwork)
                }
            }
        }
        .contentMargins(gutter, for: .scrollContent)
        .padding(-gutter)
        .focusSection()
    }

    private func pickTile(_ entry: HomeCollection, loadsArtwork: Bool) -> some View {
        let picked = store.isPicked(entry.id)
        let unavailable = !picked && store.picks.count >= HomeCollectionsStore.maxPicks
        let name = entry.collection.name
        var label = name
        if picked { label = String(localized: "\(label), chosen") }
        if unavailable { label = String(localized: "\(label), unavailable") }
        return VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(10)) {
            // Unavailable posters stay focusable but do nothing, so every
            // carousel can still be reached and scrolled.
            Button { if !unavailable { store.toggle(entry.id) } } label: {
                TVHomeCollectionPoster(collection: entry.collection, width: pickWidth, loadsArtwork: loadsArtwork)
                    .overlay(alignment: .topTrailing) {
                        if picked { WatchedCheckPill().padding(TVSettingsLayout.scaled(8)) }
                    }
            }
            .buttonStyle(.card)
            .focused($focus, equals: .pick(entry.id))
            .opacity(unavailable ? 0.4 : 1)
            .accessibilityLabel(label)

            Text(name)
                .font(.tvSettings(18, weight: .semibold))
                .lineLimit(1)
        }
        .frame(width: pickWidth, alignment: .leading)
    }
}
#endif
