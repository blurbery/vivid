#if os(tvOS)
import Observation
import SwiftUI

extension TVMainTabView {
    /// The Library tab's row of libraries: landscape cards the size of
    /// Home's Continue Watching cards, each with its library's name below.
    ///
    /// Holding a card starts arranging: every card rocks, Select picks one
    /// up, Left and Right move it and Select drops it. Arranging lasts until
    /// Menu, which the page handles because focus may have left the row.
    struct LibraryCardRow: View {
        /// In the order shown.
        let libraries: [Library]
        let focusedLibraryId: FocusState<Int?>.Binding
        /// The card focus lands on when it enters the row from elsewhere.
        let defaultLibraryId: Int?
        @Binding var isArranging: Bool
        let onOpen: (Library) -> Void
        let onMove: (Library, Int) -> Void
        let onMoveUp: () -> Void

        /// The picked-up library, by id.
        @State private var movingId: Int?
        @State private var homeCards = TVHomeCardPreferences.shared

        private var cardSize: CGSize {
            let width = VividTheme.thumbnailCardWidth * homeCards.presentation.posterSize.scale
            return CGSize(width: width, height: width * VividTheme.thumbnailCardHeight / VividTheme.thumbnailCardWidth)
        }

        var body: some View {
            let size = cardSize
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 40) {
                        // Keyed by library so a picked-up card keeps its
                        // identity, and its focus, as it changes place.
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
                // Moving a picked-up card doesn't move focus, so the focus
                // engine won't scroll; keep the card in view as it travels.
                .onChange(of: libraries.map(\.id)) {
                    guard let movingId else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(movingId) }
                }
            }
            .onChange(of: isArranging) {
                if !isArranging { movingId = nil }
            }
            .onChange(of: focusedLibraryId.wrappedValue) { _, focused in
                // Focus left the picked-up card: it stays where it is.
                if let movingId, focused != movingId { self.movingId = nil }
            }
        }

        private func card(_ library: Library, size: CGSize) -> some View {
            let isFocused = focusedLibraryId.wrappedValue == library.id
            let isMoving = movingId == library.id
            return VStack(alignment: .leading, spacing: 14) {
                // One button for every state: swapping it for another view
                // when a card is picked up would tear down the focused view.
                Button { select(library) } label: {
                    artwork(library, size: size)
                }
                .buttonStyle(LibraryCardButtonStyle(
                    isArranging: isArranging,
                    isPickedUp: isMoving,
                    rocksLeftFirst: (libraries.firstIndex(of: library) ?? 0).isMultiple(of: 2)
                ))
                .focused(focusedLibraryId, equals: library.id)
                .disabled(movingId != nil && !isMoving)
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    isArranging = true
                })
                // The card's own handler is the one the remote reaches, so
                // it also hands Up to the top menu. A picked-up card stays in
                // the row until it's dropped.
                .onMoveCommand { direction in
                    switch (direction, isMoving) {
                    case (.left, true): onMove(library, -1)
                    case (.right, true): onMove(library, 1)
                    case (.up, false): onMoveUp()
                    default: break
                    }
                }
                .accessibilityLabel(accessibilityLabel(library, isMoving: isMoving))
                .accessibilityHint(isArranging ? Text("Rearrange") : Text("Open library"))
                .accessibilityAction(named: "Rearrange") {
                    isArranging = true
                    movingId = library.id
                }
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

        /// Opens the library, or while arranging picks it up or drops it.
        private func select(_ library: Library) {
            guard isArranging else {
                onOpen(library)
                return
            }
            movingId = movingId == library.id ? nil : library.id
        }

        private func accessibilityLabel(_ library: Library, isMoving: Bool) -> Text {
            isMoving
                ? Text("Move \(library.name). Move left or right, then press centre to drop.")
                : Text(verbatim: library.name)
        }

        /// The library's own image, or its symbol on a plain tile when the
        /// server has none.
        @ViewBuilder
        private func artwork(_ library: Library, size: CGSize) -> some View {
            let url = library.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: Self.symbol(for: library))
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))
                if !url.isEmpty {
                    AsyncImageView(url: url, thumbhash: nil, targetSize: size, contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        private static func symbol(for library: Library) -> String {
            if library.isMixedLibrary { return library.navigationIcon }
            return library.isSeriesLibrary ? PrimaryMenuBuiltin.series.navigationIcon
                : PrimaryMenuBuiltin.movies.navigationIcon
        }
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

/// A gentle rocking while the Library row is being arranged. The angle is
/// read from the clock on every frame rather than run as a repeating
/// animation, which stopped whenever the row animated a card to a new place.
/// The view's structure never changes, so the card it rocks keeps its
/// identity and its focus when arranging starts and ends. Neighbours rock in
/// opposite directions.
private struct LibraryCardWobble: ViewModifier {
    let active: Bool
    let rocksLeftFirst: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let degrees = 1.2
    /// Seconds for one rock there and back.
    private static let period = 0.26

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

/// The order each server and profile arranged its Library row in, kept on
/// this Apple TV. Libraries it hasn't placed follow in the server's order.
@Observable @MainActor
final class TVLibraryOrderStore {
    static let shared = TVLibraryOrderStore()

    private static let defaultsKey = "vivid.tv.libraryRowOrder"

    /// Library ids by server and profile.
    private var orders: [String: [Int]]

    private init() {
        orders = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [Int]] ?? [:]
    }

    private var scope: String? {
        guard let profile = ServerRegistry.shared.activeProfileId, !profile.isEmpty else { return nil }
        return "\(ServerRegistry.shared.activeServerId ?? "default").\(profile)"
    }

    func ordered(_ libraries: [Library]) -> [Library] {
        guard let scope, let saved = orders[scope], !saved.isEmpty else { return libraries }
        let placed = saved.compactMap { id in libraries.first { $0.id == id } }
        return placed + libraries.filter { !saved.contains($0.id) }
    }

    /// Moves a library one place within the row as shown.
    func move(_ library: Library, by offset: Int, in shown: [Library]) {
        guard let scope, let index = shown.firstIndex(of: library) else { return }
        let target = index + offset
        guard shown.indices.contains(target) else { return }
        var ids = shown.map(\.id)
        ids.swapAt(index, target)
        orders[scope] = ids
        UserDefaults.standard.set(orders, forKey: Self.defaultsKey)
    }
}
#endif
