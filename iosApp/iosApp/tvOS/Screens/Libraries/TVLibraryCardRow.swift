#if os(tvOS)
import SwiftUI

extension TVMainTabView {
    /// The Library tab's row of libraries: landscape cards the size of
    /// Home's Continue Watching cards, each with its library's name below.
    ///
    /// Holding a card opens the arrange grid over the page, where every
    /// library shows at once and one can be picked up and moved in any
    /// direction. The row itself never rearranges in place: on a row longer
    /// than the screen, following a moving card meant scrolling the whole
    /// row, which read as everything sliding the wrong way.
    struct LibraryCardRow: View {
        /// In the order shown.
        let libraries: [Library]
        let focusedLibraryId: FocusState<Int?>.Binding
        /// The card focus lands on when it enters the row from elsewhere.
        let defaultLibraryId: Int?
        @Binding var isArranging: Bool
        let onOpen: (Library) -> Void
        /// Moves a library by a number of places in the order.
        let onMove: (Library, Int) -> Void
        let onMoveUp: () -> Void

        /// The library whose card opened the arrange grid.
        @State private var arrangeStartId: Int?
        @State private var homeCards = TVHomeCardPreferences.shared

        private var cardSize: CGSize {
            let width = VividTheme.thumbnailCardWidth * homeCards.presentation.posterSize.scale
            return CGSize(width: width, height: width * VividTheme.thumbnailCardHeight / VividTheme.thumbnailCardWidth)
        }

        var body: some View {
            let size = cardSize
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(libraries) { library in
                        card(library, size: size).id(library.id)
                    }
                }
                .padding(.horizontal, VividTheme.safePadding)
                .padding(.vertical, TVHomeRowGeometry.cardPadding)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .focusSection()
            .defaultFocus(focusedLibraryId, defaultLibraryId, priority: .userInitiated)
            .animation(.easeInOut(duration: 0.2), value: libraries.map(\.id))
            // Back closes the grid, as it closes any full-screen cover.
            .fullScreenCover(isPresented: $isArranging) {
                LibraryArrangeGrid(libraries: libraries, startId: arrangeStartId, onMove: onMove)
            }
        }

        private func card(_ library: Library, size: CGSize) -> some View {
            let isFocused = focusedLibraryId.wrappedValue == library.id
            return VStack(alignment: .leading, spacing: 14) {
                Button { onOpen(library) } label: {
                    LibraryCardArtwork(library: library, size: size, namesPlainTile: false)
                }
                .buttonStyle(LibraryCardButtonStyle(isArranging: false, isPickedUp: false, rocksLeftFirst: false))
                .focused(focusedLibraryId, equals: library.id)
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    arrange(from: library)
                })
                // The card's own handler is the one the remote reaches, so
                // it hands Up to the top menu.
                .onMoveCommand { direction in
                    if direction == .up { onMoveUp() }
                }
                .accessibilityLabel(Text(verbatim: library.name))
                .accessibilityHint(Text("Open library"))
                .accessibilityAction(named: "Rearrange") { arrange(from: library) }
                Text(verbatim: library.name)
                    .font(.vividPosterTitle)
                    .foregroundStyle(isFocused ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: size.width, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .frame(width: size.width)
        }

        private func arrange(from library: Library) {
            arrangeStartId = library.id
            isArranging = true
        }
    }
}

/// Every library at once, in rows of five, all rocking. Select picks a card
/// up, any direction moves it, Select drops it, and Back closes the grid.
/// Nothing scrolls sideways, so a card always visibly travels the way it was
/// pushed, and Up and Down cross a long list in a few moves.
private struct LibraryArrangeGrid: View {
    /// In the order shown.
    let libraries: [Library]
    /// The library focus starts on.
    let startId: Int?
    /// Moves a library by a number of places in the order.
    let onMove: (Library, Int) -> Void

    @FocusState private var focusedId: Int?
    /// The picked-up library, by id.
    @State private var movingId: Int?

    private static let columns = 5
    private static let spacing: CGFloat = 40
    private static let inset: CGFloat = 80
    private static let cardSize: CGSize = {
        let width = ((1920 - inset * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        return CGSize(width: width, height: (width * 9 / 16).rounded())
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .firstTextBaseline) {
                Text("Arrange Libraries")
                    .font(.system(size: 44, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 40)
                Text(movingId == nil ? "Press Select to pick a library up. Press Back when you're done."
                    : "Move it anywhere, then press Select to drop it.")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Self.cardSize.width), spacing: Self.spacing), count: Self.columns),
                    alignment: .leading,
                    spacing: 50
                ) {
                    // Keyed by library so a picked-up card keeps its
                    // identity, and its focus, as it changes place.
                    ForEach(libraries) { library in
                        card(library)
                    }
                }
                .padding(.vertical, 36)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .presentationBackground(.regularMaterial)
        .defaultFocus($focusedId, startId ?? libraries.first?.id, priority: .userInitiated)
        .animation(.easeInOut(duration: 0.2), value: libraries.map(\.id))
        .onChange(of: focusedId) { _, focused in
            // Focus left the picked-up card: it stays where it is.
            if let movingId, focused != movingId { self.movingId = nil }
        }
    }

    private func card(_ library: Library) -> some View {
        let isMoving = movingId == library.id
        return VStack(alignment: .leading, spacing: 12) {
            // One button for every state: swapping it for another view when
            // a card is picked up would tear down the focused view.
            Button {
                movingId = isMoving ? nil : library.id
            } label: {
                LibraryCardArtwork(library: library, size: Self.cardSize, namesPlainTile: true)
            }
            .buttonStyle(LibraryCardButtonStyle(
                isArranging: true,
                isPickedUp: isMoving,
                rocksLeftFirst: (libraries.firstIndex(of: library) ?? 0).isMultiple(of: 2)
            ))
            .focused($focusedId, equals: library.id)
            .disabled(movingId != nil && !isMoving)
            // A picked-up card stays put until it's dropped: every other
            // card is disabled, so a direction moves the card, not focus.
            .onMoveCommand { direction in
                if isMoving { move(library, direction) }
            }
            .accessibilityLabel(isMoving
                ? Text("Move \(library.name). Move it in any direction, then press centre to drop.")
                : Text(verbatim: library.name))
            .accessibilityHint(Text("Rearrange"))
            Text(verbatim: library.name)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.vividOnSurface.opacity(focusedId == library.id ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.cardSize.width, alignment: .leading)
                .accessibilityHidden(true)
        }
        .frame(width: Self.cardSize.width)
    }

    /// Left and Right step one place, running on to the next or previous
    /// row at a row's end. Up and Down step a whole row; Down from the row
    /// above a short last row goes to the end.
    private func move(_ library: Library, _ direction: MoveCommandDirection) {
        guard let index = libraries.firstIndex(of: library) else { return }
        let last = libraries.count - 1
        let target: Int
        switch direction {
        case .left: target = index - 1
        case .right: target = index + 1
        case .up: target = index - Self.columns
        case .down:
            let below = index + Self.columns
            if below <= last {
                target = below
            } else if index / Self.columns < last / Self.columns {
                target = last
            } else {
                return
            }
        @unknown default: return
        }
        guard libraries.indices.contains(target), target != index else { return }
        onMove(library, target - index)
    }
}

/// The library's own image. A library without one shows a collage of its
/// own posters, and until those arrive (or when it has none) its symbol on
/// a plain tile. In the arrange grid a plain tile carries the library's
/// name too, so libraries without artwork can be told apart at a glance.
private struct LibraryCardArtwork: View {
    let library: Library
    let size: CGSize
    let namesPlainTile: Bool

    @State private var collages = LibraryCollageStore.shared

    var body: some View {
        let url = library.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let posters = url.isEmpty ? collages.posters(for: library) : []
        ZStack {
            Color.white.opacity(0.08)
            if !url.isEmpty {
                AsyncImageView(url: url, thumbhash: nil, targetSize: size, contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else if !posters.isEmpty {
                LibraryPosterCollage(posters: posters, size: size)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: namesPlainTile ? 48 : 64, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.55))
                    if namesPlainTile {
                        Text(verbatim: library.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: library.id) {
            if url.isEmpty { await collages.load(library) }
        }
    }

    private var symbol: String {
        if library.isMixedLibrary { return library.navigationIcon }
        return library.isSeriesLibrary ? PrimaryMenuBuiltin.series.navigationIcon
            : PrimaryMenuBuiltin.movies.navigationIcon
    }
}

/// Four of a library's posters as tall strips standing side by side, the
/// whole set leaning so the joins run diagonally across the card. The
/// strips are sized to cover the card's corners once turned.
private struct LibraryPosterCollage: View {
    let posters: [String]
    let size: CGSize

    private static let strips = 4
    private static let lean = 12.0
    private static let gap: CGFloat = 4

    /// One strip's size. The turned set has to reach every corner of the
    /// card, so it covers the card's bounding box at the lean, plus 5%.
    /// Worked out in typed steps: as one expression it was too much for
    /// the compiler on CI to type-check.
    private var stripSize: CGSize {
        let radians: CGFloat = CGFloat(Self.lean) * .pi / 180
        let cosine: CGFloat = cos(radians)
        let sine: CGFloat = sin(radians)
        let coverWidth: CGFloat = (size.width * cosine + size.height * sine) * 1.05
        let coverHeight: CGFloat = (size.width * sine + size.height * cosine) * 1.05
        let count = CGFloat(Self.strips)
        let gaps: CGFloat = Self.gap * (count - 1)
        let width: CGFloat = (coverWidth - gaps) / count
        return CGSize(width: width.rounded(.up), height: coverHeight.rounded(.up))
    }

    var body: some View {
        let strip = stripSize
        HStack(spacing: Self.gap) {
            ForEach(0..<Self.strips, id: \.self) { index in
                AsyncImageView(
                    url: posters[index % posters.count],
                    thumbhash: nil,
                    targetSize: strip,
                    contentMode: .fill
                )
                .frame(width: strip.width, height: strip.height)
                .clipped()
            }
        }
        .rotationEffect(.degrees(Self.lean))
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The posters a library's collage is made from: a random few of its most
/// recently added titles, picked once per library for the session so the
/// card doesn't change each time it's drawn.
@Observable @MainActor
private final class LibraryCollageStore {
    static let shared = LibraryCollageStore()

    private var chosen: [String: [String]] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    private static let sampled = 40
    private static let kept = 4

    private init() {}

    private func key(_ library: Library) -> String {
        "\(ServerRegistry.shared.activeServerId ?? "default")|\(AuthService.shared.profileId ?? "")|\(library.id)"
    }

    func posters(for library: Library) -> [String] {
        chosen[key(library)] ?? []
    }

    /// One small catalogue request per library per session. A failed
    /// request is tried again the next time the card appears; a library
    /// with no posters is remembered as empty.
    func load(_ library: Library) async {
        let key = key(library)
        guard chosen[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        var filter = CatalogFilterState()
        filter.sort = .addedAt
        let query = CatalogQueryBuilder.build(
            filter,
            libraryId: library.id,
            mediaType: BrowseMediaType.from(libraryType: library.type),
            offset: 0,
            limit: Self.sampled,
            includeTotal: false
        )
        guard let page = try? await VividAPI.shared.catalog(query: query) else { return }
        let posters = page.items.compactMap { item -> String? in
            guard let url = item.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
            return url
        }
        chosen[key] = Array(posters.shuffled().prefix(Self.kept))
    }
}

/// A library card's own focus look: it grows and lifts on a shadow, with
/// no system platter behind it, so nothing shows around a card while it
/// rocks. A picked-up card grows a little more, like an app being moved on
/// the Apple TV Home Screen.
private struct LibraryCardButtonStyle: ButtonStyle {
    let isArranging: Bool
    let isPickedUp: Bool
    let rocksLeftFirst: Bool

    func makeBody(configuration: Configuration) -> some View {
        Card(label: configuration.label, isPressed: configuration.isPressed,
             isArranging: isArranging, isPickedUp: isPickedUp, rocksLeftFirst: rocksLeftFirst)
    }

    private struct Card<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let isArranging: Bool
        let isPickedUp: Bool
        let rocksLeftFirst: Bool

        @Environment(\.isFocused) private var isFocused

        private var scale: CGFloat {
            guard isFocused else { return 1 }
            if isPickedUp { return 1.16 }
            return isPressed ? 1.06 : 1.1
        }

        var body: some View {
            label
                .modifier(LibraryCardWobble(active: isArranging, rocksLeftFirst: rocksLeftFirst))
                .scaleEffect(scale)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 26 : 0, y: isFocused ? 16 : 0)
                .animation(.easeOut(duration: 0.18), value: scale)
        }
    }
}

/// A gentle rocking while libraries are being arranged. The angle is read
/// from the clock on every frame rather than run as a repeating animation,
/// which stopped whenever a card animated to a new place. The view's
/// structure never changes, so the card it rocks keeps its identity and its
/// focus. Neighbours rock in opposite directions.
private struct LibraryCardWobble: ViewModifier {
    let active: Bool
    let rocksLeftFirst: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let degrees = 0.6
    /// Seconds for one rock there and back.
    private static let period = 0.32

    func body(content: Content) -> some View {
        let rocks = active && !reduceMotion
        TimelineView(.animation(paused: !rocks)) { timeline in
            content.rotationEffect(.degrees(rocks ? angle(at: timeline.date) : 0))
        }
    }

    private func angle(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate / Self.period * 2 * .pi
        return sin(phase) * Self.degrees * (rocksLeftFirst ? 1 : -1)
    }
}

#endif
