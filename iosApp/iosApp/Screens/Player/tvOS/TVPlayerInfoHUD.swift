#if os(tvOS)
import SwiftUI

/// The Apple TV player HUD: a floating panel at the top of the picture with
/// a row of pill tabs (Info, Stats, Video, then Audio and Chapters when the
/// stream has them) above the selected pane. There's no dimming, so playback
/// stays visible. The Subtitles shortcut opens a subtitle-only menu instead.
///
/// Focus model (see docs/apple-tv-focus.md): every interactive row is a real
/// `Button` and the tvOS focus engine owns all movement. Columns are focus
/// sections and the tab row routes entry to the active pill with
/// `defaultFocus(priority: .userInitiated)`. `@FocusState` only seeds focus
/// (HUD or dialog opening) and restores it (dialog closing), never per
/// press. The read-only Info and Stats panes are single composite focus
/// targets that page their content, which is the documented exception.
///
/// The panes and shared rows live in the `TVPlayerHUD*.swift` files beside
/// this one.
struct TVPlayerInfoHUD: View {
    let viewModel: PlayerViewModel
    @Binding var activeTab: Tab
    @State private var readOnlyPaneIsAtTop = true
    /// The pill focus binding, owned by `TVPlayerControls` so it can seed a
    /// pill when the HUD opens. Without a focused pill, Menu has nothing to
    /// bubble `onExitCommand` from and the user can get stuck.
    @FocusState.Binding var focusedTab: Tab?
    var subtitleOnly = false
    let onDismiss: () -> Void

    enum Tab: Hashable, CaseIterable {
        case info, stats, video, audio, subtitles, chapters

        var title: String {
            switch self {
            case .info:      return String(localized: "Info", comment: "Player HUD tab")
            case .stats:     return String(localized: "Stats", comment: "Player HUD tab")
            case .video:     return String(localized: "Video", comment: "Player HUD tab")
            case .audio:     return String(localized: "Audio", comment: "Player HUD tab")
            case .subtitles: return String(localized: "Subtitles", comment: "Player HUD tab")
            case .chapters:  return String(localized: "Chapters", comment: "Player HUD tab")
            }
        }
    }

    /// Subtitles have their own shortcut, so the options HUD shows the other
    /// tabs. Audio and Chapters only appear when the session has them.
    private var availableTabs: [Tab] {
        if subtitleOnly { return [.subtitles] }
        var tabs: [Tab] = [.info, .stats, .video]
        if !viewModel.audioTracks.isEmpty { tabs.append(.audio) }
        if !viewModel.chapters.isEmpty { tabs.append(.chapters) }
        return tabs
    }

    var body: some View {
        Group {
            if subtitleOnly {
                TVPlayerSubtitleMenu(viewModel: viewModel, onDismiss: onDismiss)
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 12) {
                        tabBar
                            .padding(.top, 32)
                        panel(height: panelHeight(available: geometry.size.height))
                            .padding(.horizontal, 80)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            repairActiveTabIfUnavailable()
            // In case the parent didn't seed focus, land on the active tab
            // so Menu has a handler to bubble to.
            if !subtitleOnly && focusedTab == nil {
                focusedTab = activeTab
            }
        }
        .onChange(of: availableTabs) { _, _ in
            repairActiveTabIfUnavailable()
        }
        .onChange(of: activeTab) { _, _ in
            readOnlyPaneIsAtTop = true
        }
        .onExitCommand(perform: onDismiss)
    }

    /// At most 300 points, or just enough for a short chapter list, and never
    /// more than the screen leaves room for (but at least 180).
    private func panelHeight(available: CGFloat) -> CGFloat {
        let preferred = activeTab == .chapters ? min(300, CGFloat(viewModel.chapters.count) * 54 + 76) : 300
        return min(preferred, max(180, available - 180))
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(availableTabs, id: \.self) { tab in
                TabPill(
                    title: tab.title,
                    isSelected: activeTab == tab,
                    focusedTab: $focusedTab,
                    tab: tab,
                    onSelect: { activeTab = tab }
                )
            }
        }
        .modifier(TVTopMenuGlassChrome())
        .focusSection()
        // Info and Stats are single composite focus owners. Once either pages
        // below its top, the tab row leaves the focus graph so one Up press
        // can't both page the pane and escape to the tabs. The pane brings
        // the row back when it reaches the top again.
        .disabled(isReadOnlyPaneScrolled)
        // Up from the panel lands on the active pill, not the nearest one:
        // tabs select on focus, so landing on the nearest would switch panes.
        .defaultFocus($focusedTab, activeTab, priority: .userInitiated)
    }

    // MARK: - Panel

    private func panel(height: CGFloat) -> some View {
        Group {
            switch activeTab {
            case .info:
                InfoPane(
                    viewModel: viewModel,
                    isAtTop: $readOnlyPaneIsAtTop,
                    onMoveToTabs: focusActiveTab
                )
            case .stats:
                StatsPane(
                    viewModel: viewModel,
                    isAtTop: $readOnlyPaneIsAtTop,
                    onMoveToTabs: focusActiveTab
                )
            case .video:     VideoPane(viewModel: viewModel)
            case .audio:     AudioPane(viewModel: viewModel)
            case .subtitles: SubtitlesPane(viewModel: viewModel)
            case .chapters:  ChaptersPane(viewModel: viewModel, onSelect: onDismiss)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        // Every pane gets the same size, with room for both columns.
        .frame(maxWidth: 1280, alignment: .top)
        .frame(height: height, alignment: .top)
        // The glass lifts the panel off the video without a dark tint; the
        // stroke and shadow still define its edge over a black frame.
        // Low-power TVs get a flat translucent fill (see vividPlayerGlass).
        .vividPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .focusSection()
    }

    private var isReadOnlyPaneScrolled: Bool {
        (activeTab == .info || activeTab == .stats) && !readOnlyPaneIsAtTop
    }

    /// Moves off a tab that isn't available, taking focus with it. Runs on
    /// appear (the remembered tab may not apply to this stream) and whenever
    /// the tab set changes.
    ///
    /// Focus moves as well as the selection: whatever had it, the vanished
    /// pill or a row in its pane, leaves the hierarchy in this update, and
    /// with nothing focused Menu has nothing to bubble `onExitCommand` from,
    /// which strands the user in the HUD. `.defaultFocus` only seeds when the
    /// focus scope first appears, so it can't cover this.
    ///
    /// `availableTabs` always has a first tab; the optional just keeps this
    /// honest if that ever changes.
    private func repairActiveTabIfUnavailable() {
        guard !availableTabs.contains(activeTab),
              let first = availableTabs.first else { return }
        activeTab = first
        focusedTab = first
    }

    /// Up at the top of the Info or Stats pane. Button panes don't need this:
    /// the tab row's `defaultFocus` routes native Up movement.
    private func focusActiveTab() {
        guard availableTabs.contains(activeTab) else {
            focusedTab = availableTabs.first
            return
        }
        focusedTab = activeTab
    }
}

// MARK: - Tab pill

private struct TabPill: View {
    let title: String
    let isSelected: Bool
    @FocusState.Binding var focusedTab: TVPlayerInfoHUD.Tab?
    let tab: TVPlayerInfoHUD.Tab
    let onSelect: () -> Void

    private var isFocused: Bool { focusedTab == tab }

    var body: some View {
        Button(action: onSelect) {
            Text(title)
        }
        .buttonStyle(HUDTabPillStyle(isSelected: isSelected))
        .focused($focusedTab, equals: tab)
        // Focus selects: moving across the tabs swaps the pane below without
        // a Select press, like a native Apple TV segmented control.
        .onChange(of: isFocused) { _, focused in
            if focused { onSelect() }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HUDTabPillStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HUDTabPillBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct HUDTabPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isSelected || isFocused ? Color.black : Color.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(background))
            .overlay(Capsule(style: .continuous).stroke(Color.clear, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isSelected)
    }

    private var background: Color {
        if isSelected { return .white }
        if isFocused { return .white.opacity(0.9) }
        return .clear
    }
}
#endif
