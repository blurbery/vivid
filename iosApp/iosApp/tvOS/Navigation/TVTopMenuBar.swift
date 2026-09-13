#if os(tvOS)
import SwiftUI
import UIKit
import os

enum TVTopMenuLayout {
    /// Vertical clearance needed when a root tvOS page does not render a
    /// full-bleed hero behind the custom top menu.
    static let contentTopInset: CGFloat = 188
}

/// A library content type that can surface as a root tab (Skyline §3.1).
/// Tabs represent types, not server libraries — a type's tab appears only
/// if the profile can see at least one library of that type.
enum TVLibraryTabType: String, CaseIterable, Hashable {
    case movies
    case series

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .series: return "Series"
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
        }
    }
}

enum TVRootDestination: Hashable {
    case home
    case recommendations
    case libraryType(TVLibraryTabType)

    var title: String {
        switch self {
        case .home: return "Home"
        case .recommendations: return "For You"
        case .libraryType(let type): return type.title
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
    let onSelectRoot: (TVRootDestination) -> Void
    let onSearch: () -> Void
    let onProfilePressed: () -> Void
    /// Focus left the bar through normal focus movement into page content.
    /// The shell uses this to disable the bar again so later content-row
    /// Up presses can't geometrically jump back to the menu.
    let onContentFocusHandoff: () -> Void
    var onExit: (() -> Void)? = nil

    @FocusState private var focusedItem: TVTopMenuFocus?
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
        .animation(reduceMotion ? nil : .easeInOut(duration: VividTheme.normalDuration), value: isMenuFocused)
        .focusSection()
        .defaultFocus($focusedItem, .root(selectedRoot), priority: .userInitiated)
        .disabled(isFocusSuppressed)
        .background(
            TVTopMenuExitPressCatcher(isActive: shouldCaptureExitPress, onExit: handleExitPress)
                .frame(width: 0, height: 0)
        )
        .onChange(of: isFocusSuppressed) { _, suppressed in
            if suppressed { focusedItem = nil }
        }
        .onChange(of: focusResetRequest) { _, _ in focusedItem = nil }
        .onChange(of: focusRequest) { _, _ in requestMenuFocus() }
        .onChange(of: isMenuFocused) { _, focused in
            if !focused { focusedItem = nil }
        }
        .onChange(of: focusedItem) { _, item in
            isMenuFocused = item != nil
            if item == nil { onContentFocusHandoff() }
        }
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
        let isFocused = focusedItem == .root(root)
        let isSelected = selectedRoot == root

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
        // Publish the active tab's frame for the optional debug overlay.
        // This does not select the tab or redirect native focus.
        #if DEBUG
        .background(TVFocusDebugTabFramePublisher(isSelected: selectedRoot == root))
        #endif
        .accessibilityLabel("\(root.title), tab, \(index + 1) of \(count)")
        .accessibilityHint(root == .recommendations ? "Open Watchlist, Favourites, or Collections" : "Open page")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        focusedItem = .root(selectedRoot)
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
        let isFocused = focusedItem == .search

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
        let isFocused = focusedItem == .profile

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

    /// Keep Back handling attached without changing the focused view hierarchy.
    private var shouldCaptureExitPress: Bool {
        !isFocusSuppressed && focusedItem != nil && (isFocusedAwayFromHome || onExit != nil)
    }

    private func handleExitPress() {
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

}

private enum TVTopMenuFocus: Hashable {
    case root(TVRootDestination)
    case search
    case profile
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

/// Return from the leading tab to the adjacent utility button.
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
/// Window-level Menu capture for the top bar. A SwiftUI `.onExitCommand`
/// modifier can alter the ancestor chain around the focused tab. This recognizer stays
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
