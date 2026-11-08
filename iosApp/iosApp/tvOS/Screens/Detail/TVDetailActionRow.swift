#if os(tvOS)
import SwiftUI

/// The hero controls that can hold focus.
enum TVDetailHeroFocus: Hashable {
    case play
    case audio
    case subtitles
    case watchlist
    case more
    case synopsis

    var isActionRow: Bool { self != .synopsis }
}

/// What the Play button shows and does.
struct TVDetailPlayAction {
    /// Nil leaves Play disabled, reading "Play".
    var title: String?
    var subtitle: String?
    var progress: ResumePresentation?
    /// Adds Start Over to Play's long-press menu.
    var offersStartOver: Bool
    var play: () -> Void
    var startOver: () -> Void
}

/// Identifies the page for the one focus claim the row makes.
struct TVDetailFocusClaimKey: Equatable {
    var pageKey: String
    /// The selected season's id; only the season page waits for it. The
    /// first known id counts, and another season replacing it cancels the
    /// claim.
    var seasonKey: String?
    var requiresSeasonKey = false
}

/// Play, the audio and subtitle selectors, Watchlist and More.
struct TVDetailActionRow<MoreMenu: View>: View {
    let play: TVDetailPlayAction
    let selectors: TVDetailSelectorInputs
    let inWatchlist: Bool
    let onToggleWatchlist: () -> Void
    var focus: FocusState<TVDetailHeroFocus?>.Binding
    let scope: Namespace.ID
    let claimKey: TVDetailFocusClaimKey
    @ViewBuilder let moreMenu: () -> MoreMenu

    @Environment(\.resetFocus) private var resetFocus
    @State private var claim = FocusClaim()
    @State private var playSize: CGSize = .zero
    @State private var watchlistPressed = false

    private struct FocusClaim {
        var pageKey: String?
        var firstSeasonKey: String?
        var isMade = false
        var isAbandoned = false
    }

    /// The control last focused in the row stays wide while focus is away
    /// (in an open menu, the synopsis or the shelves), so opening a menu or
    /// coming back from one never swaps it for Play.
    @State private var expanded: TVDetailHeroFocus = .play

    var body: some View {
        HStack(spacing: 18) {
            TVDetailPlayButton(action: play, focus: focus, scope: scope)
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    let wasEmpty = playSize == .zero
                    playSize = size
                    if wasEmpty, size != .zero { attemptClaim() }
                }

            TVDetailSelectorCircles(inputs: selectors, focus: focus)

            TVDetailCircleButton(
                title: "Watchlist",
                systemImage: inWatchlist ? "bookmark.fill" : "bookmark",
                isExpanded: expanded == .watchlist,
                isFocused: focus.wrappedValue == .watchlist,
                isPressed: watchlistPressed
            ) {
                Button(action: onToggleWatchlist) {
                    TVDetailCircleHitArea()
                }
                .buttonStyle(TVDetailInvisibleControlStyle { watchlistPressed = $0 })
                .focusEffectDisabled()
                .focused(focus, equals: .watchlist)
                .accessibilityLabel(inWatchlist ? Text("Remove from watchlist") : Text("Add to watchlist"))
            }

            TVDetailCircleButton(
                title: "More",
                systemImage: "ellipsis",
                isExpanded: expanded == .more,
                isFocused: focus.wrappedValue == .more,
                isPressed: false,
                labelNudge: 4
            ) {
                Menu {
                    moreMenu()
                } label: {
                    TVDetailCircleHitArea()
                }
                .menuStyle(.button)
                .buttonStyle(TVDetailInvisibleControlStyle())
                .focusEffectDisabled()
                .focused(focus, equals: .more)
                .accessibilityLabel(Text("More options"))
            }
        }
        .environment(\.tvDetailExpandedAction, expanded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onChange(of: focus.wrappedValue, initial: true) { _, focused in
            if let focused, focused.isActionRow { expanded = focused }
        }
        // Up at the top of the page must never act as Back.
        .onMoveCommand { _ in }
        .onChange(of: claimKey.pageKey, initial: true) { _, key in
            // The same page coming back (from playback or a pushed page)
            // keeps its claim, so Play never takes focus a second time.
            guard key != claim.pageKey else { return }
            if claim.pageKey != nil { expanded = .play }
            claim = FocusClaim(pageKey: key, firstSeasonKey: claimKey.seasonKey)
            attemptClaim()
        }
        .onChange(of: claimKey.seasonKey) { _, key in
            guard claimKey.requiresSeasonKey, !claim.isMade, let key else { return }
            if claim.firstSeasonKey == nil {
                // The season arrived after the page opened, so it is the
                // first one the row has seen.
                claim.firstSeasonKey = key
                attemptClaim()
            } else if key != claim.firstSeasonKey {
                claim.isAbandoned = true
            }
        }
        .onChange(of: play.title) { _, title in
            if title != nil { attemptClaim() }
        }
    }

    /// Moves focus to Play once per page, so the page opens on it even when
    /// the system would pick another control.
    private func attemptClaim() {
        guard play.title != nil, !claim.isMade, !claim.isAbandoned,
              claim.pageKey == claimKey.pageKey else { return }
        if claimKey.requiresSeasonKey {
            guard let season = claimKey.seasonKey, season == claim.firstSeasonKey else { return }
        }
        claim.isMade = true
        guard focus.wrappedValue != .play else { return }
        resetFocus(in: scope)
        focus.wrappedValue = .play
    }
}

/// Sizes for the action row. One control is wide with its label and the
/// rest stay circles, so the row's width never changes and nothing beside
/// or above it moves. The wide control is the one last focused in the row
/// (Play when the page opens).
enum TVDetailActionRowLayout {
    static let controlHeight: CGFloat = 76
    static let expandedWidth: CGFloat = 280
    static let iconSize: CGFloat = 38
    static let iconInset: CGFloat = (controlHeight - iconSize) / 2
    static let labelSpacing: CGFloat = 12
    /// The widest a label can be: the pill less the icon, the gap and the
    /// same inset on both ends.
    static let labelWidth: CGFloat = expandedWidth - iconInset * 2 - iconSize - labelSpacing
    /// How far the label sits left of true centre, which reads as centred.
    static let labelNudge: CGFloat = 5
    static let resize: Animation = .smooth(duration: 0.32, extraBounce: 0)

    /// Where a symbol's drawn glyph ends, measured from the pill's leading
    /// edge. Symbols differ in width inside their fixed frame (a bookmark is
    /// much narrower than a speech bubble), so the label centres against
    /// the glyph rather than the frame.
    @MainActor
    static func visibleIconEdge(_ systemImage: String) -> CGFloat {
        if let known = glyphWidths[systemImage] {
            return iconInset + (iconSize + known) / 2
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: 31, weight: .semibold)
        let width = UIImage(systemName: systemImage, withConfiguration: configuration)?.size.width ?? iconSize
        let glyph = min(width, iconSize)
        glyphWidths[systemImage] = glyph
        return iconInset + (iconSize + glyph) / 2
    }

    @MainActor private static var glyphWidths: [String: CGFloat] = [:]

}

private struct TVDetailExpandedActionKey: EnvironmentKey {
    static let defaultValue: TVDetailHeroFocus = .play
}

extension EnvironmentValues {
    /// The action row control currently shown wide.
    var tvDetailExpandedAction: TVDetailHeroFocus {
        get { self[TVDetailExpandedActionKey.self] }
        set { self[TVDetailExpandedActionKey.self] = newValue }
    }
}

/// Play or Resume: wide with its label while it's the row's last-focused
/// control (as it is when the page opens), otherwise a circle.
private struct TVDetailPlayButton: View {
    let action: TVDetailPlayAction
    var focus: FocusState<TVDetailHeroFocus?>.Binding
    let scope: Namespace.ID

    @State private var isPressed = false
    @Environment(\.tvDetailExpandedAction) private var expanded

    private var isFocused: Bool { focus.wrappedValue == .play }

    var body: some View {
        TVDetailExpandingButton(
            systemImage: "play.fill",
            isExpanded: expanded == .play,
            isFocused: isFocused,
            isPressed: isPressed,
            isEnabled: action.title != nil
        ) {
            label
        } control: {
            // Play stays focusable while the title loads (a disabled control
            // can't hold focus, which sent it to another button and then
            // jumped back), and does nothing until it knows what to play.
            Button {
                if action.title != nil { action.play() }
            } label: {
                TVDetailCircleHitArea()
            }
            .buttonStyle(TVDetailInvisibleControlStyle { isPressed = $0 })
            .focusEffectDisabled()
            .focused(focus, equals: .play)
            .prefersDefaultFocus(true, in: scope)
            .accessibilityLabel(titleText)
            .contextMenu {
                if action.offersStartOver {
                    Button(action: action.startOver) {
                        Label("Start Over", systemImage: "backward.end.fill")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if let progress = action.progress {
            ResumeButtonProgressLabel(progress: progress)
        } else {
            VStack(alignment: .center, spacing: 0) {
                titleText
                if let subtitle = action.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var titleText: Text {
        if let title = action.title {
            return Text(verbatim: title)
        }
        return Text("Play")
    }
}

/// An icon control that widens to show its title while it's the row's
/// expanded control and is a circle otherwise. The visible surface follows
/// the focus of an invisible control laid over it, which takes the presses
/// and speaks for it.
struct TVDetailCircleButton<Control: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isExpanded = false
    let isFocused: Bool
    let isPressed: Bool
    /// Extra leftward shift for this control's label only.
    var labelNudge: CGFloat = 0
    @ViewBuilder let control: () -> Control

    var body: some View {
        TVDetailExpandingButton(
            systemImage: systemImage,
            isExpanded: isExpanded,
            isFocused: isFocused,
            isPressed: isPressed,
            labelNudge: labelNudge
        ) {
            Text(title)
        } control: {
            control()
        }
    }
}

/// The shared surface of the action row's controls. The icon stays fixed
/// where it sits in the circle; the label is centred between the icon and
/// the pill's end, and is clipped as the pill narrows.
struct TVDetailExpandingButton<Label: View, Control: View>: View {
    let systemImage: String
    let isExpanded: Bool
    let isFocused: Bool
    let isPressed: Bool
    var isEnabled = true
    var labelNudge: CGFloat = 0
    @ViewBuilder let label: () -> Label
    @ViewBuilder let control: () -> Control

    private typealias Layout = TVDetailActionRowLayout

    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: systemImage)
                .font(.system(size: 31, weight: .semibold))
                .frame(width: Layout.iconSize, height: Layout.iconSize)
                .contentTransition(.symbolEffect(.replace))
                .padding(.leading, Layout.iconInset)

            TVDetailPillLabelLayout(iconEdge: Layout.visibleIconEdge(systemImage), extraNudge: labelNudge) {
                label()
                    .font(.system(size: 29, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .opacity(isExpanded ? 1 : 0)
        }
        .opacity(isEnabled ? 1 : 0.55)
        .frame(
            width: isExpanded ? Layout.expandedWidth : Layout.controlHeight,
            height: Layout.controlHeight,
            alignment: .leading
        )
        .foregroundStyle(Color.white)
        // The tinted glass of the iOS Play button. Its bright rim, with the
        // pill widening, is what shows focus, so there is no fill.
        .clipShape(Capsule())
        .vividGlass(in: Capsule(), tint: .black.opacity(0.26))
        .overlay {
            Capsule()
                .strokeBorder(LinearGradient.vividPrimaryRim, lineWidth: 2.5)
                .opacity(isFocused ? 1 : 0)
        }
        .shadow(
            color: .black.opacity(isFocused ? 0.34 : 0),
            radius: isFocused ? 16 : 0,
            y: isFocused ? 6 : 0
        )
        .scaleEffect(isPressed ? 0.95 : 1)
        .animation(Layout.resize, value: isExpanded)
        .animation(.smooth(duration: 0.28, extraBounce: 0), value: isFocused)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isPressed)
        .accessibilityHidden(true)
        .overlay {
            control()
        }
    }
}

/// Lays a label across the expanded pill, centred between the visible
/// edge of the icon and the pill's end, and kept clear of both.
private struct TVDetailPillLabelLayout: Layout {
    private typealias Metrics = TVDetailActionRowLayout
    /// Where the drawn symbol ends.
    let iconEdge: CGFloat
    var extraNudge: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: Metrics.expandedWidth, height: Metrics.controlHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let earliest = iconEdge + Metrics.labelSpacing
        let latest = Metrics.expandedWidth - Metrics.iconInset
        let size = subview.sizeThatFits(ProposedViewSize(width: Metrics.labelWidth, height: bounds.height))
        let width = min(size.width, Metrics.labelWidth)
        let centre = (iconEdge + Metrics.expandedWidth) / 2
        let x = min(max(earliest, centre - width / 2), latest - width) - Metrics.labelNudge - extraNudge
        subview.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: width, height: size.height)
        )
    }
}

/// The transparent, capsule-shaped label of a circle's control.
struct TVDetailCircleHitArea: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
    }
}

/// Draws nothing of its own, and reports presses when asked.
struct TVDetailInvisibleControlStyle: ButtonStyle {
    var onPressChange: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .onChange(of: configuration.isPressed) { _, pressed in
                onPressChange?(pressed)
            }
    }
}
#endif
