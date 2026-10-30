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

extension TVMainTabView {
    /// Search, the root tabs and the profile avatar in one glass capsule.
    /// It only takes focus when the shell hands it over, or while Home's
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

        @FocusState private var focus: Item?
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
            .frame(height: VividTheme.Skyline.barHeight)
            .padding(.horizontal, VividTheme.Skyline.safeAreaX)
            .padding(.top, VividTheme.Skyline.barTopInset)
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
            .onChange(of: effectivelySuppressed) {
                if effectivelySuppressed { focus = nil }
            }
            .onChange(of: focusResetRequest) { focus = nil }
            .onChange(of: isFocused) {
                if !isFocused { focus = nil }
            }
            .onChange(of: focus) {
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
                    rootTab(root)
                }
                divider
                utility(swapsUtilities ? .search : .profile)
            }
            .fixedSize()
            .modifier(TVTopMenuGlassChrome())
            .frame(maxWidth: .infinity)
            .frame(height: VividTheme.Skyline.barHeight)
        }

        private var scrollingCluster: some View {
            HStack(spacing: VividTheme.Skyline.tabSpacing) {
                utility(leadingUtility)
                divider
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VividTheme.Skyline.tabSpacing) {
                            ForEach(roots, id: \.self) { root in
                                rootTab(root).id(root)
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
            .modifier(TVTopMenuGlassChrome())
            .padding(.horizontal, 150)
            .frame(maxWidth: .infinity)
        }

        private var divider: some View {
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 1, height: 26)
                .padding(.horizontal, 6)
                .accessibilityHidden(true)
        }

        // MARK: Items

        private func rootTab(_ root: Root) -> some View {
            let isSelected = root == selectedRoot
            let isItemFocused = focus == .root(root)
            let inverted = isItemFocused || (isSelected && focus == nil)
            let position = (roots.firstIndex(of: root) ?? 0) + 1
            let textColour: Color = inverted ? .black : (isSelected ? .white : Color.white.opacity(0.62))
            let fill: Color = inverted ? .white : (isSelected ? Color.white.opacity(0.14) : .clear)
            let border: Color = !isItemFocused && isSelected ? .vividChromeSelectedBorder : .clear
            let scale: CGFloat = isItemFocused && !reduceMotion ? 1.1 : 1
            let focusAnimation: Animation? = reduceMotion ? nil : VividTheme.springAnimation
            let selectionAnimation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.18)
            return Button { select(root) } label: {
                Text(verbatim: root.title)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                    .foregroundStyle(textColour)
                    .background(Capsule().fill(fill))
                    .overlay(Capsule().strokeBorder(border, lineWidth: 1))
                    .scaleEffect(scale)
                    .animation(focusAnimation, value: isItemFocused)
                    .animation(selectionAnimation, value: isSelected)
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
            let isItemFocused = focus == .search
            return Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isItemFocused ? Color.vividBackground : Color.white.opacity(0.62))
                    .frame(width: 48, height: 48)
                    .background(Capsule().fill(isItemFocused ? Color.white : Color.clear))
                    .scaleEffect(isItemFocused && !reduceMotion ? 1.1 : 1)
                    .animation(reduceMotion ? nil : VividTheme.springAnimation, value: isItemFocused)
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
            let isItemFocused = focus == .profile
            return Button(action: onProfile) {
                ProfileAvatarView(
                    avatar: profile?.avatarEmoji,
                    imageUrl: profile?.avatarImageUrl,
                    name: profile?.name ?? "",
                    size: 44,
                    backgroundColor: Color.white.opacity(0.18),
                    textColor: .white
                )
                .overlay(Circle().strokeBorder(Color.white, lineWidth: isItemFocused ? 3 : 0))
                .scaleEffect(isItemFocused && !reduceMotion ? 1.05 : 1)
                .animation(reduceMotion ? nil : VividTheme.springAnimation, value: isItemFocused)
                .frame(width: 48, height: 48)
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

        private func select(_ root: Root) {
            onSelect(root)
            DispatchQueue.main.async { focus = nil }
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
