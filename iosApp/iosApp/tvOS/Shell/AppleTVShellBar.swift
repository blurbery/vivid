#if os(tvOS)
import SwiftUI
import UIKit

/// Room the top bar takes above page content.
enum TVTopMenuLayout {
    static let contentTopInset: CGFloat = 188
}

/// The top bar's glass capsule, also used by other capsule rows.
struct TVTopMenuGlassChrome: ViewModifier {
    init() {}

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

/// A tab hanging from the top of the screen, like a notch: the sides flare
/// out where they meet the top edge and the bottom corners are rounded.
struct TVTopMenuNotchShape: Shape {
    static let flare: CGFloat = 8
    /// Without the top edge, for the outline.
    var open = false

    func path(in rect: CGRect) -> Path {
        let flare = Self.flare
        let radius = min(26, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
                          control: CGPoint(x: rect.minX + flare, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + flare + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - flare - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - radius),
                          control: CGPoint(x: rect.maxX - flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - flare, y: rect.minY))
        if !open { path.closeSubpath() }
        return path
    }
}

/// The top bar's notch: dark glass with an outline on its sides and bottom
/// that fades into the top edge.
struct TVTopMenuNotchChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, TVTopMenuNotchShape.flare + 16)
            .padding(.top, 3)
            .padding(.bottom, 5)
            .background(.ultraThinMaterial, in: TVTopMenuNotchShape())
            .background(TVTopMenuNotchShape().fill(Color.black.opacity(0.45)))
            // The outline fades out as it reaches the top edge, so the notch
            // grows out of the edge instead of stopping against it.
            .overlay(TVTopMenuNotchShape(open: true).stroke(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0), location: 0),
                        .init(color: Color.white.opacity(0.28), location: 0.4),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1.5
            ))
    }
}

/// The one highlight the notch's tabs and Search share. Drawn by whichever
/// item holds it, so it leaves one and arrives on the next as a single
/// moving shape. Outlined rather than filled, like the notch itself.
struct TVTopMenuHighlightPill: View {
    let namespace: Namespace.ID

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.1))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.92), lineWidth: 2.5))
            .matchedGeometryEffect(id: "highlight", in: namespace)
    }
}

/// The hairline between the notch's utilities and its tabs.
struct TVTopMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.22))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}

/// How the notch's tabs, highlight and lift move, shared with the Tab Bar
/// settings preview so the two stay in step.
enum TVTopMenuMotion {
    /// One animation for every tab's width, the highlight and the lift,
    /// so tabs that open and close on the same focus move stay in step.
    static func tabs(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)
    }

    /// The bar closing around a chosen tab. A timed curve rather than a
    /// spring: it has fully stopped before the page starts being built,
    /// where a spring's tail was still settling.
    static let close: Animation = .easeOut(duration: 0.16)

    static func tabTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.5))
    }
}

/// One tab in the notch: its symbol, or its name while it is focused or
/// while it is the selected tab of a bar without focus.
struct TVTopMenuTabLabel: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    let isFocused: Bool
    /// True while anything in the bar is drawn as focused.
    let barHasFocus: Bool
    let highlight: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let inverted = isFocused || (isSelected && !barHasFocus)
        let textColour: Color = inverted || isSelected ? .white : Color.white.opacity(0.62)
        let fill: Color = !inverted && isSelected ? Color.white.opacity(0.14) : .clear
        let border: Color = !isFocused && isSelected ? .vividChromeSelectedBorder : .clear
        let scale: CGFloat = isFocused && !reduceMotion ? 1.1 : 1
        // The name shows for the focused tab, or for the selected one
        // while the bar doesn't have focus; the rest show their symbol.
        let showsName = inverted
        // Both stay in the tree and crossfade, so the pill's width is the
        // only thing that moves. The cluster's animation moves it together
        // with the other tabs.
        ZStack {
            // Whichever is leaving fades out before the other fades in,
            // so they never show on top of each other.
            Image(systemName: symbol)
                .animation(fade(in: !showsName)) { $0.opacity(showsName ? 0 : 1) }
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: showsName ? nil : 0)
                .animation(fade(in: showsName)) { $0.opacity(showsName ? 1 : 0) }
        }
        .font(.system(size: 24, weight: .semibold))
        .padding(.horizontal, showsName ? 22 : 16)
        .padding(.vertical, 6)
        .foregroundStyle(textColour)
        .clipShape(Capsule())
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .background {
            if inverted { TVTopMenuHighlightPill(namespace: highlight) }
        }
        .scaleEffect(scale)
    }

    /// The symbol or name fading in late, or out early.
    private func fade(in appearing: Bool) -> Animation? {
        if reduceMotion { return nil }
        return appearing ? .easeIn(duration: 0.16).delay(0.14) : .easeOut(duration: 0.1)
    }
}

/// Search in the notch.
struct TVTopMenuSearchLabel: View {
    let isFocused: Bool
    let highlight: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.62))
            .frame(width: 44, height: 42)
            .background {
                // The tabs' highlight, so it glides here too.
                if isFocused { TVTopMenuHighlightPill(namespace: highlight) }
            }
            .scaleEffect(isFocused && !reduceMotion ? 1.1 : 1)
    }
}

/// The profile avatar in the notch.
struct TVTopMenuProfileLabel: View {
    let profile: UserProfile?
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ProfileAvatarView(
            avatar: profile?.avatarEmoji,
            imageUrl: profile?.avatarImageUrl,
            name: profile?.name ?? "",
            size: 40,
            backgroundColor: Color.white.opacity(0.18),
            textColor: .white
        )
        .overlay(Circle().strokeBorder(Color.white, lineWidth: isFocused ? 3 : 0))
        .scaleEffect(isFocused && !reduceMotion ? 1.05 : 1)
        .animation(reduceMotion ? nil : VividTheme.springAnimation, value: isFocused)
        .frame(width: 44, height: 42)
    }
}

extension TVMainTabView {
    /// Search, the root tabs and the profile avatar in a notch hanging from
    /// the top edge. Off focus it closes to Search, the selected tab and
    /// the avatar; with focus the other tabs come back as symbols. It only
    /// takes focus when the shell hands it over, or while Home's
    /// spotlight leaves it reachable.
    struct TopBar: View {
        let roots: [Root]
        let profile: UserProfile?
        let swapsUtilities: Bool
        /// The shell's live state; read again after delays.
        @Binding var selectedRoot: Root
        @Binding var isFocused: Bool
        @Binding var isSuppressed: Bool
        @Binding var homeAllowsFocus: Bool
        let focusRequest: Int
        let focusResetRequest: Int
        let onSelect: (Root) -> Void
        let onSearch: () -> Void
        let onProfile: () -> Void
        let onContentHandOff: () -> Void
        /// Present only away from Home: returns to Home in the bar.
        let onExit: (() -> Void)?
        /// True while a page is pushed or the player is open. A chosen tab
        /// whose page hasn't opened yet is dropped when this turns on, so
        /// navigation from outside the bar, such as a Siri search, wins.
        var isCovered = false

        @FocusState private var focus: Item?
        /// Lets the white highlight glide from one tab to the next.
        @Namespace private var highlight
        /// The item the tabs draw as focused. It follows `focus` inside an
        /// explicit animation: drawn straight from the focus state, the tab
        /// gaining focus opened without one while the tab losing it closed
        /// with one, so the bar jumped.
        @State private var shownFocus: Item?
        /// A tab that was just chosen and whose page hasn't opened yet. The
        /// bar closes around it first and the page follows, because closing
        /// while the page was being built made the close stutter.
        @State private var pendingRoot: Root?
        /// Opens `pendingRoot`. Cancelled if anything else happens first.
        @State private var pendingOpen: DispatchWorkItem?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        enum Item: Hashable {
            case root(Root)
            case search
            case profile
        }

        private var effectivelySuppressed: Bool {
            isSuppressed && !(selectedRoot == .home && homeAllowsFocus)
        }

        private var leadingUtility: Item { swapsUtilities ? .profile : .search }

        var body: some View {
            ViewThatFits(in: .horizontal) {
                centredCluster
                scrollingCluster
            }
            .frame(height: VividTheme.Skyline.barHeight, alignment: .top)
            .padding(.horizontal, VividTheme.Skyline.safeAreaX)
            .frame(maxWidth: .infinity, alignment: .top)
            .ignoresSafeArea(edges: [.top, .horizontal])
            .focusSection()
            .defaultFocus($focus, .root(selectedRoot), priority: .userInitiated)
            .disabled(effectivelySuppressed)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isFocused)
            .background(
                MenuPressBridge(isActive: menuPressIsActive, onPress: handleMenuPress)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            )
            .onChange(of: isCovered) {
                if isCovered { cancelPendingOpen() }
            }
            .onChange(of: effectivelySuppressed) {
                if effectivelySuppressed { cancelPendingOpen() }
                if effectivelySuppressed { focus = nil }
            }
            .onChange(of: focusResetRequest) { focus = nil }
            .onChange(of: isFocused) {
                if !isFocused { focus = nil }
            }
            .onChange(of: focus) {
                // Moving off the chosen tab before its page opens drops it.
                if let pendingRoot, focus != .root(pendingRoot) { cancelPendingOpen() }
                followFocus()
                isFocused = focus != nil
                if focus == nil { onContentHandOff() }
            }
            .onChange(of: focusRequest) { claimFocus(retriesLeft: 2) }
        }

        // MARK: Layouts

        private var centredCluster: some View {
            HStack(spacing: VividTheme.Skyline.tabSpacing) {
                utility(leadingUtility)
                divider
                ForEach(roots, id: \.self) { root in
                    if showsTab(root) {
                        rootTab(root).transition(tabTransition)
                    }
                }
                divider
                utility(swapsUtilities ? .search : .profile)
            }
            .fixedSize()
            .modifier(TVTopMenuNotchChrome())
            .frame(maxWidth: .infinity)
            .frame(height: VividTheme.Skyline.barHeight, alignment: .top)
            .animation(tabAnimation, value: selectedRoot)
        }

        private var scrollingCluster: some View {
            HStack(spacing: VividTheme.Skyline.tabSpacing) {
                utility(leadingUtility)
                divider
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VividTheme.Skyline.tabSpacing) {
                            ForEach(roots, id: \.self) { root in
                                if showsTab(root) {
                                    rootTab(root).id(root).transition(tabTransition)
                                }
                            }
                        }
                    }
                    .scrollClipDisabled()
                    .onChange(of: focus) {
                        guard case .root(let root) = focus else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                            proxy.scrollTo(root, anchor: .center)
                        }
                    }
                    .onChange(of: selectedRoot) {
                        proxy.scrollTo(selectedRoot, anchor: .center)
                    }
                }
                divider
                utility(swapsUtilities ? .search : .profile)
            }
            .modifier(TVTopMenuNotchChrome())
            .padding(.horizontal, 150)
            .frame(maxWidth: .infinity)
            .frame(height: VividTheme.Skyline.barHeight, alignment: .top)
            .animation(tabAnimation, value: selectedRoot)
        }

        private var tabAnimation: Animation? {
            TVTopMenuMotion.tabs(reduceMotion: reduceMotion)
        }

        /// While focus is below the bar it closes to Search, the selected
        /// tab and the avatar; the other tabs come back once it has focus.
        private func showsTab(_ root: Root) -> Bool {
            shownFocus != nil || root == displayedRoot
        }

        private var tabTransition: AnyTransition {
            TVTopMenuMotion.tabTransition(reduceMotion: reduceMotion)
        }

        private var divider: some View { TVTopMenuDivider() }

        // MARK: Items

        private func rootTab(_ root: Root) -> some View {
            let isSelected = root == displayedRoot
            let position = (roots.firstIndex(of: root) ?? 0) + 1
            return Button { select(root) } label: {
                TVTopMenuTabLabel(symbol: root.symbol, title: root.title,
                                  isSelected: isSelected,
                                  isFocused: shownFocus == .root(root),
                                  barHasFocus: shownFocus != nil,
                                  highlight: highlight)
            }
            .buttonStyle(.vividFlat)
            .focusEffectDisabled()
            .focused($focus, equals: .root(root))
            .onMoveCommand { direction in
                if direction == .left, root == roots.first { focus = leadingUtility }
            }
            .accessibilityLabel(Text("\(root.title), tab, \(position) of \(roots.count)"))
            .accessibilityHint(root.accessibilityHint)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        @ViewBuilder
        private func utility(_ item: Item) -> some View {
            if item == .search {
                searchButton
            } else {
                profileButton
            }
        }

        private var searchButton: some View {
            Button(action: onSearch) {
                TVTopMenuSearchLabel(isFocused: shownFocus == .search, highlight: highlight)
            }
            .buttonStyle(.vividFlat)
            .focusEffectDisabled()
            .focused($focus, equals: .search)
            .onMoveCommand { direction in
                if swapsUtilities {
                    if direction == .left, let last = roots.last { focus = .root(last) }
                } else {
                    if direction == .right, let first = roots.first { focus = .root(first) }
                }
            }
            .accessibilityLabel(Text("Search"))
        }

        private var profileButton: some View {
            Button(action: onProfile) {
                TVTopMenuProfileLabel(profile: profile, isFocused: focus == .profile)
            }
            .buttonStyle(.vividFlat)
            .focusEffectDisabled()
            .focused($focus, equals: .profile)
            .onMoveCommand { direction in
                if swapsUtilities {
                    if direction == .right, let first = roots.first { focus = .root(first) }
                } else {
                    if direction == .left, let last = roots.last { focus = .root(last) }
                }
            }
            .accessibilityLabel(Text("Settings"))
            .accessibilityHint(Text("Press to open settings"))
        }

        // MARK: Actions

        /// The tab the bar draws as selected.
        private var displayedRoot: Root { pendingRoot ?? selectedRoot }

        private func followFocus() {
            withAnimation(tabAnimation) { shownFocus = focus }
        }

        private func select(_ root: Root) {
            guard root != selectedRoot, !reduceMotion else {
                open(root)
                return
            }
            guard pendingRoot == nil else { return }
            pendingRoot = root
            withAnimation(TVTopMenuMotion.close) { shownFocus = nil }
            let work = DispatchWorkItem {
                guard pendingRoot == root else { return }
                open(root)
            }
            pendingOpen = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.19, execute: work)
        }

        private func open(_ root: Root) {
            pendingOpen = nil
            pendingRoot = nil
            onSelect(root)
            DispatchQueue.main.async { focus = nil }
        }

        /// Drops a chosen tab whose page hasn't opened yet, so a Menu press,
        /// Search or the avatar in that gap isn't overridden by it.
        private func cancelPendingOpen() {
            guard pendingRoot != nil || pendingOpen != nil else { return }
            pendingOpen?.cancel()
            pendingOpen = nil
            pendingRoot = nil
            followFocus()
        }

        /// Focuses the selected tab, retrying shortly while the bar should
        /// hold focus and nothing in it does.
        private func claimFocus(retriesLeft: Int) {
            guard !effectivelySuppressed else { return }
            focus = .root(selectedRoot)
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard !isSuppressed || (selectedRoot == .home && homeAllowsFocus) else { return }
                guard isFocused, focus == nil else { return }
                claimFocus(retriesLeft: retriesLeft - 1)
            }
        }

        private var menuPressIsActive: Bool {
            guard !effectivelySuppressed, let focus else { return false }
            return focus != .root(.home) || onExit != nil
        }

        private func handleMenuPress() {
            cancelPendingOpen()
            if focus != .root(.home) {
                if selectedRoot == .home {
                    focus = .root(.home)
                    isFocused = true
                } else {
                    onExit?()
                }
            } else {
                onExit?()
            }
        }
    }

    /// Catches the remote's Menu press on the bar's window while the bar can
    /// use it; otherwise the press passes through.
    private struct MenuPressBridge: UIViewRepresentable {
        let isActive: Bool
        let onPress: () -> Void

        func makeUIView(context: Context) -> InstallerView {
            InstallerView(recogniser: context.coordinator.makeRecogniser())
        }

        func updateUIView(_ view: InstallerView, context: Context) {
            context.coordinator.isActive = isActive
            context.coordinator.onPress = onPress
        }

        static func dismantleUIView(_ view: InstallerView, coordinator: Coordinator) {
            view.detach()
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var isActive = false
            var onPress: () -> Void = {}

            /// Menu presses only; no touches, so clickpad touches stay with
            /// the focused button.
            func makeRecogniser() -> UITapGestureRecognizer {
                let recogniser = UITapGestureRecognizer(target: self, action: #selector(pressed(_:)))
                recogniser.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
                recogniser.allowedTouchTypes = []
                recogniser.cancelsTouchesInView = true
                recogniser.delegate = self
                return recogniser
            }

            @objc func pressed(_ recogniser: UITapGestureRecognizer) {
                guard recogniser.state == .ended else { return }
                onPress()
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                isActive
            }
        }

        /// Moves the recogniser to whichever window shows the bar.
        final class InstallerView: UIView {
            private let recogniser: UITapGestureRecognizer
            private weak var installedWindow: UIWindow?

            init(recogniser: UITapGestureRecognizer) {
                self.recogniser = recogniser
                super.init(frame: .zero)
                isUserInteractionEnabled = false
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { nil }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard installedWindow !== window else { return }
                detach()
                guard let window else { return }
                window.addGestureRecognizer(recogniser)
                installedWindow = window
            }

            func detach() {
                installedWindow?.removeGestureRecognizer(recogniser)
                installedWindow = nil
            }
        }
    }
}
#endif
