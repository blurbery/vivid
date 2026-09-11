#if os(tvOS)
import SwiftUI
import UIKit
import os

enum TVTopMenuLayout {
    /// Vertical clearance needed when a root tvOS page does not render a
    /// full-bleed hero behind the custom top menu.
    static let contentTopInset: CGFloat = 188
}

/// Publishes the on-screen bounds of each panel-bearing bar element so the
/// shell can anchor the cascade / profile panel under it (§5.3 "centered
/// under the tab", §5.8 "under the avatar"). One `Anchor` per element; the
/// shell resolves the open panel's anchor in its own coordinate space.
struct TVTopMenuAnchorKey: PreferenceKey {
    static let defaultValue: [TVTopMenuPanel: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [TVTopMenuPanel: Anchor<CGRect>],
        nextValue: () -> [TVTopMenuPanel: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A library content type that can surface as a root tab (Skyline §3.1).
/// Tabs represent types, not server libraries — a type's tab appears only
/// if the profile can see at least one library of that type.
enum TVLibraryTabType: String, CaseIterable, Hashable {
    case movies
    case series
    case music

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .series: return "Series"
        case .music: return "Music"
        }
    }

    /// SF Symbol for a library row of this type in the cascade level-1
    /// panel (§5.3). Per-library art isn't fetched there — the icon is a
    /// quiet type cue, mirroring the empty-state glyphs elsewhere.
    var systemImage: String {
        switch self {
        case .movies: return "film.stack"
        case .series: return "tv"
        case .music: return "music.note"
        }
    }

    /// Mono section header for the cascade level-1 panel (§5.3), e.g.
    /// `MOVIE LIBRARIES`.
    var librariesHeader: String {
        switch self {
        case .movies: return "MOVIE LIBRARIES"
        case .series: return "SERIES LIBRARIES"
        case .music: return "MUSIC LIBRARIES"
        }
    }

    /// Whether a server library belongs under this tab. A mixed library
    /// (movies + series in one folder) belongs to both video tabs — it stays
    /// one browsable library, reachable from either dropdown.
    func matches(_ library: Library) -> Bool {
        switch self {
        case .movies:
            return library.type == "movies" || library.isMixedLibrary
                || (MediaServerProvider.active == .emby && library.type == "movie")
        case .series: return library.isSeriesLibrary || library.isMixedLibrary
        case .music: return library.type == "music"
        }
    }
}

enum TVRootDestination: Hashable {
    case home
    case recommendations
    case libraryType(TVLibraryTabType)
    case libraryShortcut(libraryId: Int, label: String)

    static func == (lhs: TVRootDestination, rhs: TVRootDestination) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home), (.recommendations, .recommendations):
            return true
        case (.libraryType(let lhsType), .libraryType(let rhsType)):
            return lhsType == rhsType
        case (.libraryShortcut(let lhsId, _), .libraryShortcut(let rhsId, _)):
            return lhsId == rhsId
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .home:
            hasher.combine(0)
        case .recommendations:
            hasher.combine(1)
        case .libraryType(let type):
            hasher.combine(2)
            hasher.combine(type)
        case .libraryShortcut(let libraryId, _):
            hasher.combine(3)
            hasher.combine(libraryId)
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .recommendations: return "For You"
        case .libraryType(let type): return type.title
        case .libraryShortcut(_, let label): return label
        }
    }
}

/// Skyline top bar: wordmark left, search + type-derived tabs centered
/// (search sits just left of Home; the tabs stay screen-centered), profile
/// avatar right (§5.1). The bar is custom on purpose — the system
/// `TabView` sidebar steals leftward focus — and draws no background band;
/// it floats over each page's own scrim and dims to 70% while focus is
/// down in the content zone.
struct TVTopMenuBar: View {
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities")) private var utilitiesSwapped = false
    let roots: [TVRootDestination]
    let selectedRoot: TVRootDestination
    let currentProfile: UserProfile?
    @Binding var isMenuFocused: Bool
    let isFocusSuppressed: Bool
    let focusRequest: Int
    /// Bumped when the shell has determined the bar's `@FocusState` is stale —
    /// the engine dropped focus without the bar observing it, so no suppression
    /// transition will clear it. Drops the bar's focus state without asking for
    /// focus back.
    var focusResetRequest: Int = 0
    /// Bar element to focus on the next `focusRequest` bump, overriding the
    /// default of the selected tab. The shell sets this so Menu-ing out of a
    /// panel returns focus to the *panel's* tab/avatar (§7), not whatever
    /// root happens to be selected.
    var focusRequestTarget: TVTopMenuPanel? = nil
    /// Which bar element currently has an anchored panel open (the host
    /// owns the panel; the bar only drives the dwell + hand-off). When set
    /// to the focused element, its capsule drops from inverted to
    /// `chrome.selected` once focus descends into the panel.
    let openPanel: TVTopMenuPanel?
    /// True once focus has descended from the bar into the open panel —
    /// the tab/avatar then reads as selected, not focused (§5.1).
    let panelHasFocus: Bool
    /// True while the panel is in focus-owning (entered) mode, as opposed to a
    /// passive dwell preview. Unlike `panelHasFocus` — which flips false for a
    /// frame whenever the panel's row focus is momentarily perturbed and lags
    /// behind the engine by a render pass — this is set once when the host
    /// hands focus in and stays true until the panel closes. The bar uses it
    /// to stay passive: in entered mode a `focusedItem` drop to nil means the
    /// panel claimed focus, so the bar must NOT re-pin to the tab. Re-pinning
    /// there starts a tug-of-war with the panel's own `@FocusState` (the entry
    /// oscillation that made d-pad navigation into the flyout flaky).
    let panelEntersFocus: Bool
    let onSelectRoot: (TVRootDestination) -> Void
    let onSearch: () -> Void
    /// A bar element rested under focus for the dwell interval, or focus
    /// left every dwellable element (`nil` → close any open panel). §5.3.
    let onDwell: (TVTopMenuPanel?) -> Void
    /// D-pad down on a panel-bearing element (library tab or avatar): the
    /// host opens its panel if needed and hands focus in (§5.3). Takes the
    /// element so the host routes to the right panel.
    let onEnterPanel: (TVTopMenuPanel) -> Void
    let onProfilePressed: () -> Void
    /// Focus left the bar through normal focus movement into page content.
    /// The shell uses this to disable the bar again so later content-row
    /// Up presses can't geometrically jump back to the menu.
    let onContentFocusHandoff: () -> Void
    var onExit: (() -> Void)? = nil

    @FocusState private var focusedItem: TVTopMenuFocus?
    /// Dwell timer keyed on the focused element; cancelled on every focus
    /// move so bar sweeps never open a panel (§5.3, Open-Q5/Q7).
    @State private var dwellTask: Task<Void, Never>?
    /// The last bar element focus actually settled on. Used to restore focus
    /// when opening/closing the dropdown overlay transiently drops it.
    @State private var lastBarFocus: TVTopMenuFocus?
    /// Set when a sideways move closes the open panel: the overlay removal
    /// perturbs focus, so the next nil-drop is spurious and must be re-pinned.
    @State private var refocusAfterClose = false
    /// The element whose panel the user just explicitly closed (Menu/Back).
    /// Focus returns to it, but the dwell timer must NOT auto-reopen the panel
    /// they just dismissed — that's the "closes then immediately reopens"
    /// awkwardness. Cleared the instant focus moves to a *different* element,
    /// so resting here again later still opens it normally.
    @State private var dwellSuppressedElement: TVTopMenuFocus?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "TVFocus"
    )

    var body: some View {
        tabCluster
        .frame(height: VividTheme.Skyline.barHeight)
        .padding(.horizontal, VividTheme.Skyline.safeAreaX)
        .padding(.top, VividTheme.Skyline.barTopInset)
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(edges: [.top, .horizontal])
        // The bar dims only while focus is down in the content zone (§5.1).
        // An open panel keeps it fully lit — focus has merely descended into
        // the dropdown, and dimming the bar there greys out the panel's own
        // anchor tab and reads as a heavy "everything went dark" state.
        // Reduce Motion snaps the bar dim/restore as focus enters/leaves
        // the content zone (§5.1; §4.2 acceptance: no drift animations).
        .animation(reduceMotion ? nil : .easeInOut(duration: VividTheme.normalDuration), value: isMenuFocused)
        .focusSection()
        .disabled(isFocusSuppressed || panelEntersFocus)
        // Menu handling must not be conditionally wrapped around the focused
        // tab buttons. Toggling an `onExitCommand` ancestor when `openPanel`
        // changes invalidates tvOS focus and produces the preview-open flash.
        .background(
            TVTopMenuExitPressCatcher(
                isActive: shouldCaptureExitPress,
                onExit: handleExitPress
            )
            .frame(width: 0, height: 0)
        )
        .onChange(of: isFocusSuppressed) { _, newValue in
            if newValue {
                focusedItem = nil
                // Focus left the bar for content; a later return to any tab
                // should dwell-open normally, so drop any close-suppression.
                dwellSuppressedElement = nil
            }
        }
        .onChange(of: focusResetRequest) { _, _ in
            // Clear the re-pin flags first: the bar has no focus to defend
            // here, and letting the nil write below take the re-pin branch
            // would have the bar grab focus the shell is handing elsewhere.
            refocusAfterClose = false
            dwellSuppressedElement = nil
            dwellTask?.cancel()
            focusedItem = nil
        }
        .onChange(of: focusRequest) { _, _ in
            let target = focusRequestTarget.map { String(describing: $0) } ?? "nil"
            Self.logger.debug("topMenu.focusRequest request=\(focusRequest, privacy: .public) suppressed=\(isFocusSuppressed, privacy: .public) target=\(target, privacy: .public)")
            requestMenuFocus()
        }
        .onChange(of: isMenuFocused) { _, newValue in
            // Don't release the bar's own focus when the *panel* is what's
            // taking it (panelHasFocus): the panel claims focus through its
            // own @FocusState and the system clears ours. Nulling here first
            // leaves a frame with nothing focused, which tvOS repairs to the
            // Home tab — the flash / focus reset. Content hand-off still nulls
            // via the isFocusSuppressed handler above.
            if !newValue && !panelHasFocus {
                focusedItem = nil
            }
        }
        .onChange(of: panelHasFocus) { _, newValue in
            isMenuFocused = focusedItem != nil && !newValue
        }
        .onChange(of: focusedItem) { _, newValue in
            let item = newValue.map { String(describing: $0) } ?? "nil"
            Self.logger.debug("topMenu.focus item=\(item, privacy: .public) panelHasFocus=\(panelHasFocus, privacy: .public) panelEntersFocus=\(panelEntersFocus, privacy: .public)")
            if let newValue {
                lastBarFocus = newValue
                refocusAfterClose = false
                isMenuFocused = !panelHasFocus
                scheduleDwell(for: newValue)
                return
            }
            // Focus dropped to nil while the panel is in entered (focus-owning)
            // mode: the panel claimed focus through its own @FocusState, so the
            // bar must stay passive. Re-pinning to the tab here fights the panel
            // for focus — and because `panelHasFocus` lags a render pass and a
            // stale `refocusAfterClose` can still be set from earlier bar
            // navigation, the re-pin fires exactly when it shouldn't, producing
            // the entry oscillation (focus yo-yos tab↔row until the flags
            // converge, dropping any d-pad press made in between). The host
            // closes the panel on a genuine exit via `onPanelFocusChanged`, so
            // nothing is stranded by staying out of it.
            if panelEntersFocus {
                isMenuFocused = false
                dwellTask?.cancel()
                return
            }
            // Opening OR closing the dropdown overlay perturbs the focus graph
            // and makes tvOS drop the bar's @FocusState, repairing to the Home
            // tab (the flash). When that's why we lost focus — a preview panel
            // is open, or a sideways move just closed one — re-pin to the tab
            // the user is actually on in the same transaction. Deferring this by
            // one main-queue turn leaves a visible frame where tvOS repairs
            // focus back to Home. A legit leave (down into the page, Menu out)
            // has neither flag, so it falls through and focus is allowed to go.
            // A suppressed bar must never take focus back. The shell suppresses
            // before handing focus down, and the watchdog's reset arrives while
            // suppression is already true with a passive preview still open —
            // exactly the `spuriousFromOpenPreview` shape — so an ungated re-pin
            // would undo the repair and re-strand the remote. Drop the re-pin
            // flag with it so it can't fire on a later legitimate nil write.
            if isFocusSuppressed {
                isMenuFocused = false
                refocusAfterClose = false
                dwellTask?.cancel()
                return
            }
            let spuriousFromOpenPreview = openPanel != nil && !panelHasFocus
            if (spuriousFromOpenPreview || refocusAfterClose), let target = lastBarFocus {
                refocusAfterClose = false
                focusedItem = target
                return
            }
            isMenuFocused = false
            scheduleDwell(for: nil)
            if !panelHasFocus {
                onContentFocusHandoff()
            }
        }
        .onDisappear { dwellTask?.cancel() }
    }

    // MARK: - Clusters

    private var tabCluster: some View {
        ViewThatFits(in: .horizontal) {
            centeredTabCluster
            scrollingTabCluster
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: VividTheme.Skyline.barHeight)
    }

    /// Keep the ordinary menu as one native focus row. Besides preserving the
    /// Skyline screen-centered composition, this gives Search and Home direct
    /// focus adjacency instead of separating them with a scroll container.
    private var centeredTabCluster: some View {
        HStack(spacing: VividTheme.Skyline.tabSpacing) {
            leadingUtility
            searchDivider

            ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                rootButton(root, index: index, count: roots.count)
            }

            searchDivider
            trailingUtility
        }
        // `ViewThatFits` must measure the row's intrinsic width so it can
        // select the scrolling fallback only when customization overflows.
        .fixedSize(horizontal: true, vertical: false)
        .modifier(TVTopMenuGlassChrome())
    }

    /// Long customized menus keep Search fixed and scroll only the roots.
    private var scrollingTabCluster: some View {
        HStack(spacing: VividTheme.Skyline.tabSpacing) {
            leadingUtility
            searchDivider

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VividTheme.Skyline.tabSpacing) {
                        ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                            rootButton(root, index: index, count: roots.count)
                                .id(TVTopMenuFocus.root(root))
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollClipDisabled()
                .onChange(of: focusedItem) { _, item in
                    guard let item, case .root = item else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: VividTheme.fastDuration)) {
                        proxy.scrollTo(item, anchor: .center)
                    }
                }
                .onChange(of: selectedRoot) { _, root in
                    proxy.scrollTo(TVTopMenuFocus.root(root), anchor: .center)
                }
            }

            searchDivider
            trailingUtility
        }
        // Search and Profile stay fixed while only the customizable roots
        // scroll through the center lane.
        .modifier(TVTopMenuGlassChrome())
        .padding(.horizontal, 150)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var leadingUtility: some View {
        if utilitiesSwapped { profileButton } else { searchButton }
    }

    @ViewBuilder private var trailingUtility: some View {
        if utilitiesSwapped { searchButton } else { profileButton }
    }

    private var searchDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.22))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }

    // MARK: - Tabs

    private func rootButton(_ root: TVRootDestination, index: Int, count: Int) -> some View {
        // While its panel owns focus the tab reads as selected, not focused
        // (§5.1) — the inverted look transfers to the panel row.
        let panelOwnsFocus = panelHasFocus && openPanel == .root(root)
        let hasFocus = focusedItem == .root(root) && !panelHasFocus
        let isFocused = hasFocus && !panelOwnsFocus
        let isSelected = selectedRoot == root || panelOwnsFocus

        return Button {
            selectRootFromMenu(root)
        } label: {
            Text(root.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tabForeground(isSelected: isSelected, isFocused: isFocused))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
                .padding(.horizontal, 24)
                .padding(.vertical, 9)
                .modifier(TVTopMenuCapsuleChrome(isSelected: isSelected, isFocused: isFocused, highlightsSelection: focusedItem == nil))
        }
        .buttonStyle(.vividFlat)
        .focused($focusedItem, equals: .root(root))
        // A ScrollView is its own focus region on tvOS. At its leading edge,
        // explicitly hand Left back to the fixed Search anchor.
        .modifier(TVTopMenuLeadingBoundaryHandler(isLeading: index == 0) {
            focusedItem = utilitiesSwapped ? .profile : .search
        })
        // Down opens this tab's cascade panel (if a dwell hasn't already)
        // and hands focus straight into it, so the move never escapes to the
        // page content behind the bar. Fires only when the engine can't move
        // focus within the bar — i.e. the bar is a single row, so down
        // always reaches here.
        // `canOpenPanel` is keyed on the tab *kind* (library and For You tabs
        // can; Home/Calendar never can) — invariant, so opening a panel never
        // restructures this focused button (which dropped focus).
        .modifier(TVTopMenuDownHandler(canOpenPanel: true) {
            if let panel = rootPanel(root) {
                onEnterPanel(panel)
            } else {
                selectRootFromMenu(root)
            }
        })
        // Panel-bearing tabs publish their bounds so the shell can center the
        // anchored dropdown under them (§5.3); other tabs have no panel.
        .modifier(TVTopMenuAnchorPublisher(panel: rootPanel(root)))
        // Debug-overlay hint: SwiftUI's content→menu section hop lands on
        // the selected tab, but that rule is invisible to the focus
        // engine — the selected tab publishes its frame so the overlay
        // can mark it as the Up destination. Renders nothing when the
        // overlay setting is off; debug builds only.
        #if DEBUG
        .background(TVFocusDebugTabFramePublisher(isSelected: selectedRoot == root))
        #endif
        .accessibilityLabel("\(root.title), tab, \(index + 1) of \(count)")
        .accessibilityHint(rootPanelHint(for: root))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rootPanel(_ root: TVRootDestination) -> TVTopMenuPanel? {
        switch root {
        case .libraryType(.movies), .libraryType(.series):
            return nil
        case .libraryType:
            return TVLibraryMenuRootKind.category.hasSectionCascade ? .root(root) : nil
        case .libraryShortcut:
            return TVLibraryMenuRootKind.directShortcut.hasSectionCascade ? .root(root) : nil
        case .recommendations:
            return nil
        case .home:
            return nil
        }
    }

    private func rootPanelHint(for root: TVRootDestination) -> String {
        switch root {
        case .libraryType(.movies), .libraryType(.series):
            return "Open libraries"
        case .libraryType:
            return "Rest to choose a library"
        case .libraryShortcut:
            return "Rest to choose a section"
        case .recommendations:
            return "Open Watchlist, Favourites, or Collections"
        case .home:
            return ""
        }
    }

    private func tabForeground(isSelected: Bool, isFocused: Bool) -> Color {
        if isFocused || (isSelected && focusedItem == nil) { return .black }
        if isSelected { return .white }
        return .white.opacity(0.62)
    }

    private func selectRootFromMenu(_ root: TVRootDestination) {
        onSelectRoot(root)
        DispatchQueue.main.async {
            focusedItem = nil
        }
    }

    private func requestMenuFocus(attempt: Int = 0) {
        guard !isFocusSuppressed else {
            Self.logger.debug("topMenu.requestMenuFocus blocked suppressed=true")
            return
        }
        switch focusRequestTarget {
        // A non-nil target means focus is returning from an explicit panel
        // close (focusTopMenuIfVisible(focusing:) is only called that way).
        // Mark it so the dwell timer doesn't immediately reopen what the
        // user just dismissed. A target-less request (Up/Menu from content)
        // leaves dwell enabled — resting on a tab there should preview it.
        case .root(let root):
            dwellSuppressedElement = .root(root)
            focusedItem = .root(root)
        case .profile:
            dwellSuppressedElement = .profile
            focusedItem = .profile
        case .none:
            focusedItem = .root(selectedRoot)
        }
        let item = focusedItem.map { String(describing: $0) } ?? "nil"
        Self.logger.debug("topMenu.requestMenuFocus focusedItem=\(item, privacy: .public)")

        // A quick Siri Remote swipe can make the focus engine finish its row
        // repair after this write. Re-assert only if the bar still owns the
        // handoff and the claim was actually dropped; once focus lands—or the
        // user moves away—the retry cancels itself and never fights navigation.
        guard attempt < 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !isFocusSuppressed,
                  isMenuFocused,
                  focusedItem == nil else { return }
            requestMenuFocus(attempt: attempt + 1)
        }
    }

    // MARK: - Search

    private var searchButton: some View {
        let isFocused = focusedItem == .search && !panelHasFocus

        return Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isFocused ? Color.vividBackground : .white.opacity(0.62))
                .frame(
                    width: 48,
                    height: 48
                )
                .modifier(TVTopMenuCapsuleChrome(isSelected: false, isFocused: isFocused))
        }
        .buttonStyle(.vividFlat)
        .focused($focusedItem, equals: .search)
        // The inverse boundary keeps Search usable in the scrolling fallback;
        // in the centered layout the native focus graph resolves this first.
        .onMoveCommand { direction in
            guard direction == (utilitiesSwapped ? .left : .right),
                  let adjacentRoot = utilitiesSwapped ? roots.last : roots.first else { return }
            focusedItem = .root(adjacentRoot)
        }
        .accessibilityLabel("Search")
    }

    // MARK: - Profile

    private var profileButton: some View {
        let isFocused = focusedItem == .profile && !panelHasFocus

        return Button {
            onProfilePressed()
        } label: {
            ProfileAvatarView(
                avatar: currentProfile?.avatarEmoji,
                imageUrl: currentProfile?.avatarImageUrl,
                name: currentProfile?.name ?? "",
                size: 44,
                backgroundColor: Color.white.opacity(0.18),
                textColor: .white
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.white, lineWidth: isFocused ? 3 : 0)
            }
            // Reduce Motion drops the focus scale so the avatar snaps (§4.2).
            .scaleEffect(isFocused && !reduceMotion ? 1.05 : 1.0)
            .focusEffectDisabled()
            .animation(reduceMotion ? nil : VividTheme.springAnimation, value: isFocused)
        }
        .buttonStyle(.vividFlat)
        .frame(width: 48, height: 48)
        .focused($focusedItem, equals: .profile)
        .onMoveCommand { direction in
            guard direction == (utilitiesSwapped ? .right : .left),
                  let adjacentRoot = utilitiesSwapped ? roots.first : roots.last else { return }
            focusedItem = .root(adjacentRoot)
        }
        .accessibilityLabel("Settings")
        .accessibilityHint("Press to open settings")
    }

    /// Menu handler for the bar: closes a dwell-open panel first (§5.3
    /// "Menu closes"), otherwise runs the page-level bar exit. This is captured
    /// by `TVTopMenuExitPressCatcher` instead of `.onExitCommand` so changing
    /// `openPanel` never rewrites the focused tab's SwiftUI ancestor chain.
    private var shouldCaptureExitPress: Bool {
        !isFocusSuppressed
            && focusedItem != nil
            && !panelHasFocus
            && (openPanel != nil || isFocusedAwayFromHome || onExit != nil)
    }

    private func handleExitPress() {
        let item = focusedItem.map { String(describing: $0) } ?? "nil"
        Self.logger.debug("topMenu.exitPress focusedItem=\(item, privacy: .public) openPanel=\(openPanel != nil, privacy: .public) selectedRoot=\(String(describing: selectedRoot), privacy: .public)")
        if openPanel != nil {
            onDwell(nil)
            return
        }
        if isFocusedAwayFromHome {
            if selectedRoot == .home {
                focusedItem = .root(.home)
                isMenuFocused = true
            } else {
                onExit?()
            }
            return
        }
        onExit?()
    }

    private var isFocusedAwayFromHome: Bool {
        focusedItem != nil && focusedItem != .root(.home)
    }

    // MARK: - Dwell (§5.3, §5.8)

    /// Restart the dwell timer whenever focus settles on a new bar
    /// element. A library tab or the profile avatar opens its panel after
    /// the dwell interval; any other element (or losing focus) closes any
    /// open panel immediately. Cancelled on every focus move so a sweep
    /// across the bar never opens a panel (Open-Q5/Q7).
    private func scheduleDwell(for item: TVTopMenuFocus?) {
        dwellTask?.cancel()

        // Moving focus to a *different bar element* — another tab, or the
        // search button — closes the open panel right away (§5.3: "moving
        // sideways to another tab closes it"), so it doesn't linger during
        // the new element's dwell. Once the panel is expected to own focus,
        // ignore top-bar repairs: tvOS may briefly re-home to Home while
        // the panel row focus claim is being applied.
        if let openPanel, !panelHasFocus, let item, !item.matches(panel: openPanel) {
            onDwell(nil)
            // Closing the panel removes its overlay, which perturbs focus and
            // drops the tab we just moved to; flag it so the nil-drop re-pins.
            refocusAfterClose = true
        }

        // Don't auto-reopen a panel the user just explicitly closed: Menu/Back
        // returns focus to its tab, and resting there would otherwise re-trip
        // the dwell. Once focus has moved on to a *different* element, drop the
        // suppression so normal dwell resumes.
        if let suppressed = dwellSuppressedElement {
            if suppressed == item { return }
            dwellSuppressedElement = nil
        }

        guard let target = dwellTarget(for: item) else { return }

        dwellTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: VividTheme.Skyline.cascadeDwellMilliseconds * 1_000_000
            )
            guard !Task.isCancelled else { return }
            // Confirm focus is still on the same element before opening —
            // a late move that didn't cancel in time must not fire.
            guard focusedItem == item else { return }
            onDwell(target)
        }
    }

    /// Maps a focused bar element to the panel it should dwell-open, or
    /// `nil` for elements with no panel (wordmark/search/non-library tabs).
    private func dwellTarget(for item: TVTopMenuFocus?) -> TVTopMenuPanel? {
        switch item {
        case .root(let root):
            return rootPanel(root)
        case .profile, .search, .none:
            return nil
        }
    }
}

/// Which bar element an anchored panel is attached to (§5.3/§5.8).
enum TVTopMenuPanel: Hashable {
    case root(TVRootDestination)
    case profile
}

private enum TVTopMenuFocus: Hashable {
    case root(TVRootDestination)
    case search
    case profile

    /// Whether this focused element is the anchor of the given open panel —
    /// i.e. focus is still "on" that panel's tab/avatar, not a sibling.
    func matches(panel: TVTopMenuPanel) -> Bool {
        switch (self, panel) {
        case let (.root(a), .root(b)): return a == b
        case (.profile, .profile): return true
        default: return false
        }
    }
}

/// Capsule chrome for top-bar tabs and the search button (§5.1):
/// resting = bare label, selected = `chrome.selected` capsule, focused =
/// inverted white capsule. Focus inversion is the platform grammar — no
/// outline ring, no system halo.
struct TVTopMenuGlassChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct TVTopMenuCapsuleChrome: ViewModifier {
    let isSelected: Bool
    let isFocused: Bool
    var highlightsSelection = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(fillColor))
            .overlay {
                Capsule().strokeBorder(borderColor, lineWidth: 1)
            }
            .scaleEffect(isFocused && !reduceMotion ? 1.1 : 1)
            .focusEffectDisabled()
            // Reduce Motion snaps the tab/search capsule inversion (§4.2).
            .animation(reduceMotion ? nil : VividTheme.springAnimation, value: isFocused)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
    }

    private var fillColor: Color {
        if isFocused || (isSelected && highlightsSelection) { return .white }
        if isSelected { return .white.opacity(0.14) }
        return .clear
    }

    private var borderColor: Color {
        if isFocused { return .clear }
        if isSelected { return .vividChromeSelectedBorder }
        return .clear
    }
}

/// Shared surface for every Skyline anchored menu (§5.3 cascade + flyout,
/// §5.8 profile) so they read as one family. A frosted material base under
/// a near-opaque vertical tint — lighter at the top, as if lit from above —
/// finished with a gradient hairline that brightens along the top lip and a
/// two-layer shadow (a tight contact shadow under a broad ambient one) so
/// the panel floats over the page on its own depth rather than needing a
/// page scrim to darken everything behind it.
struct TVSkylinePanelChrome: ViewModifier {
    var cornerRadius: CGFloat = VividTheme.Skyline.dropdownCornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(.regularMaterial))
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#23252C").opacity(0.92),
                            Color(hex: "#141519").opacity(0.95),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
    }
}

/// Hands d-pad **down** on a panel-bearing bar element (library tab or
/// avatar) to the host, which opens the element's panel if needed and moves
/// focus into it (§5.3). Attachment is keyed on the element's *kind*
/// (`canOpenPanel`, invariant) — never on whether its panel is currently
/// open. Toggling the attachment on a *focused* button rebuilds its subtree
/// and drops `@FocusState`, which bounced focus back to the Home tab; keeping
/// it invariant fixes that. The live open/enter decision is in the closure.
private struct TVTopMenuDownHandler: ViewModifier {
    let canOpenPanel: Bool
    let onDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canOpenPanel {
            content.onMoveCommand { direction in
                if direction == .down { onDown() }
            }
        } else {
            content
        }
    }
}

/// The scrolling overflow layout puts its roots in a separate focus region
/// from the fixed Search button. This boundary reconnects the two regions
/// without taking ownership of ordinary movement inside either one.
private struct TVTopMenuLeadingBoundaryHandler: ViewModifier {
    let isLeading: Bool
    let onMoveLeft: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLeading {
            content.onMoveCommand { direction in
                if direction == .left { onMoveLeft() }
            }
        } else {
            content
        }
    }
}

/// Publishes a bar element's bounds into `TVTopMenuAnchorKey` so the shell
/// can anchor its panel. A `nil` panel publishes nothing (elements with no
/// panel).
private struct TVTopMenuAnchorPublisher: ViewModifier {
    let panel: TVTopMenuPanel?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let panel {
            content.anchorPreference(key: TVTopMenuAnchorKey.self, value: .bounds) {
                [panel: $0]
            }
        } else {
            content
        }
    }
}

/// Window-level Menu capture for the top bar. A SwiftUI `.onExitCommand`
/// modifier would need to appear and disappear as a panel opens, which rebuilds
/// the ancestor chain around the currently focused tab. This recognizer stays
/// mounted and simply declines the press when the bar has nothing to handle, so
/// the system Menu behavior still passes through on Home.
private struct TVTopMenuExitPressCatcher: UIViewRepresentable {
    var isActive: Bool
    var onExit: () -> Void

    func makeUIView(context: Context) -> TVTopMenuExitPressUIView {
        let view = TVTopMenuExitPressUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TVTopMenuExitPressUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TVTopMenuExitPressUIView) {
        view.isActive = isActive
        view.onExit = onExit
    }
}

private final class TVTopMenuExitPressUIView: UIView, UIGestureRecognizerDelegate {
    var isActive = false
    var onExit: () -> Void = {}

    private weak var attachedWindow: UIWindow?
    private var recognizer: UITapGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachRecognizerIfNeeded()
    }

    deinit {
        detachRecognizer()
    }

    private func attachRecognizerIfNeeded() {
        guard attachedWindow !== window else { return }
        detachRecognizer()

        guard let window else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleMenuPress(_:)))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self

        window.addGestureRecognizer(recognizer)
        attachedWindow = window
        self.recognizer = recognizer
    }

    private func detachRecognizer() {
        if let recognizer, let attachedWindow {
            attachedWindow.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleMenuPress(_ recognizer: UITapGestureRecognizer) {
        guard isActive, recognizer.state == .ended else { return }
        onExit()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isActive
    }
}

#endif
