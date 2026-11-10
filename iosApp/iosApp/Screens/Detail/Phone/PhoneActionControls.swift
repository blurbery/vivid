import SwiftUI

#if !os(tvOS)
extension EnvironmentValues {
    /// True for the actions beside Play when they share its row, as on the
    /// Duo's inner screen.
    @Entry var phoneDetailActionsShareRow = false
    /// True inside the iPad full-screen hero, whose controls copy Apple TV.
    @Entry var phoneDetailUsesTVStyle = false
    /// True for playback selectors placed beside Play rather than under the
    /// overview.
    @Entry var mobileSelectorsInActionRow = false
}

/// Sizes of a named action: 52-point circles everywhere, captioned except
/// in the iPad hero, where they're bare circles.
struct PhoneLabeledActionMetrics {
    let sharesRow: Bool
    var tvStyle: Bool = false

    static let rowSpacing: CGFloat = 12
    /// The gap between actions in the row under Play, which sits centred
    /// rather than spread across the width.
    static let stackedRowSpacing: CGFloat = 14

    /// Every labelled action's circle, wherever the row sits.
    static let circleSize: CGFloat = 52

    var circle: CGFloat { Self.circleSize }
    var iconSize: CGFloat { 21 }
    /// Sharing Play's row (the Duo's inner screen) and in the iPad hero, a
    /// fixed slot the circle's width. Under Play, nil: at least the circle's
    /// width, and wider for a long caption (`MobileActionRowLayout`).
    var slotWidth: CGFloat? { sharesRow || tvStyle ? circle : nil }
    var showsCaption: Bool { !tvStyle }
    var minHeight: CGFloat { tvStyle ? circle : 58 }
}

/// The Play button: Liquid Glass on detail pages, a white capsule in the
/// iPad hero.
struct PhonePrimaryPillButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    var fullWidth: Bool = false
    var resumeProgress: ResumePresentation? = nil
    /// Long-press menu items: Start Over when there's something to resume,
    /// Shuffle on a series. No menu when both are nil.
    var startOver: (() -> Void)? = nil
    var shuffle: (() -> Void)? = nil

    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle

    init(
        icon: String,
        title: String,
        action: @escaping () -> Void,
        fullWidth: Bool = false,
        resumeProgress: ResumePresentation? = nil,
        startOver: (() -> Void)? = nil,
        shuffle: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.action = action
        self.fullWidth = fullWidth
        self.resumeProgress = resumeProgress
        self.startOver = startOver
        self.shuffle = shuffle
    }

    /// The menu is always attached, so the button keeps its identity when
    /// Start Over comes and goes. With no rows, a long press shows nothing.
    var body: some View {
        button.contextMenu {
            if let startOver {
                Button(action: startOver) {
                    Label("Start Over", systemImage: "backward.end.fill")
                }
            }
            if let shuffle {
                MobileShuffleMenuButton(action: shuffle)
            }
        }
    }

    @ViewBuilder
    private var button: some View {
        if usesTVStyle {
            Button(action: action) {
                label
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26)
                    .frame(height: 52)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            Button(action: action) {
                label
                    .foregroundStyle(.white)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
                    .padding(.horizontal, 24)
                    .frame(height: 52)
                    .vividGlass(in: shape, tint: .black.opacity(0.26), interactive: true)
                    .overlay {
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.65), .white.opacity(0.14), .white.opacity(0.38)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                    }
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
            if let resumeProgress {
                ResumeButtonProgressLabel(progress: resumeProgress)
                    .font(.system(size: 17, weight: .semibold))
            } else {
                Text(verbatim: title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
            }
        }
    }
}

/// Play above the named actions. The Duo's inner screen puts them in one
/// row with a rule under it, and the iPad hero puts Play, the selectors and
/// the actions in one Apple TV-style row.
struct PhoneDetailPrimaryActions<Play: View, Selectors: View, Actions: View>: View {
    var stackedSpacing: CGFloat = 14
    @ViewBuilder let play: () -> Play
    @ViewBuilder let selectors: () -> Selectors
    @ViewBuilder let actions: () -> Actions

    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        stackedSpacing: CGFloat = 14,
        @ViewBuilder play: @escaping () -> Play,
        @ViewBuilder selectors: @escaping () -> Selectors,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.stackedSpacing = stackedSpacing
        self.play = play
        self.selectors = selectors
        self.actions = actions
    }

    var body: some View {
        if usesTVStyle {
            HStack(alignment: .center, spacing: 14) {
                play()
                selectors()
                    .environment(\.mobileSelectorsInActionRow, true)
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // One layout that switches, so a Duo fold or unfold moves Play and
            // the actions rather than rebuilding them (an open menu stays open).
            let sharesRow = PhoneDuo.usesWideDetailLayout(horizontalSizeClass)
            let layout = sharesRow
                ? AnyLayout(HStackLayout(alignment: .top, spacing: PhoneLabeledActionMetrics.rowSpacing))
                : AnyLayout(VStackLayout(alignment: .center, spacing: stackedSpacing))
            VStack(spacing: PhoneLabeledActionMetrics.rowSpacing) {
                layout {
                    play()
                    actions()
                        .environment(\.phoneDetailActionsShareRow, sharesRow)
                }
                if sharesRow {
                    MobileActionRule()
                }
            }
        }
    }
}

extension PhoneDetailPrimaryActions where Selectors == EmptyView {
    init(
        stackedSpacing: CGFloat = 14,
        @ViewBuilder play: @escaping () -> Play,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(stackedSpacing: stackedSpacing, play: play, selectors: { EmptyView() }, actions: actions)
    }
}

/// Favourite, Watchlist, Watched and the rest, centred under Play with a
/// rule under them, or side by side when they share Play's row.
struct PhoneLabeledActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle
    @Environment(\.phoneDetailActionsShareRow) private var sharesRow

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if usesTVStyle {
            HStack(spacing: 14) {
                content()
            }
        } else {
            VStack(spacing: 12) {
                if sharesRow {
                    HStack(alignment: .top, spacing: PhoneLabeledActionMetrics.rowSpacing) {
                        content()
                    }
                } else {
                    MobileActionRowLayout(spacing: PhoneLabeledActionMetrics.stackedRowSpacing) {
                        content()
                    }
                    .frame(maxWidth: .infinity)
                    MobileActionRule()
                }
            }
        }
    }
}

/// The actions under Play, centred with even gaps. When they don't fit (a
/// narrow window, long translated captions) the gaps close to `minSpacing`
/// first, then each action gets an equal share, never narrower than its
/// circle, and its caption scales down or truncates.
struct MobileActionRowLayout: Layout {
    var spacing: CGFloat
    var minSpacing: CGFloat = 4
    var minItemWidth: CGFloat = PhoneLabeledActionMetrics.circleSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        let ideal = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? ideal, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = Self.placement(widths: subviews.map { $0.sizeThatFits(.unspecified).width },
                                       available: bounds.width, spacing: spacing, minSpacing: minSpacing,
                                       minItemWidth: minItemWidth)
        var x = bounds.minX + placement.leading
        for (subview, width) in zip(subviews, placement.widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + placement.gap
        }
    }

    /// Each action's width, the gap between them and the leading inset that
    /// centres the row.
    static func placement(widths ideal: [CGFloat], available: CGFloat, spacing: CGFloat,
                          minSpacing: CGFloat, minItemWidth: CGFloat = PhoneLabeledActionMetrics.circleSize) -> (widths: [CGFloat], gap: CGFloat, leading: CGFloat) {
        guard !ideal.isEmpty else { return ([], 0, 0) }
        let gaps = CGFloat(ideal.count - 1)
        let content = ideal.reduce(0, +)
        var widths = ideal
        var gap = spacing
        if content + gap * gaps > available {
            gap = gaps > 0 ? max(minSpacing, min(spacing, (available - content) / gaps)) : 0
        }
        if content + gap * gaps > available {
            let share = max(0, (available - gap * gaps) / CGFloat(ideal.count))
            widths = ideal.map { max(min($0, share), min($0, minItemWidth)) }
        }
        let total = widths.reduce(0, +) + gap * gaps
        return (widths, gap, max(0, (available - total) / 2))
    }
}

/// The hairline under the action row.
struct MobileActionRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}

/// One named action: an icon in a circle over a short caption, or just the
/// circle in the iPad hero.
struct MobileNamedAction: View {
    let icon: String
    var activeIcon: String? = nil
    var isActive = false
    let caption: LocalizedStringKey
    var spokenLabel: LocalizedStringKey? = nil
    let action: () -> Void

    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle
    @Environment(\.phoneDetailActionsShareRow) private var sharesRow

    private var shownIcon: String {
        isActive ? (activeIcon ?? icon) : icon
    }

    var body: some View {
        Button(action: action) {
            if usesTVStyle {
                MobileActionCircle(icon: shownIcon, isActive: isActive)
            } else {
                let metrics = PhoneLabeledActionMetrics(sharesRow: sharesRow)
                VStack(spacing: 6) {
                    Image(systemName: shownIcon)
                        .font(.system(size: metrics.iconSize, weight: .regular))
                        .foregroundStyle(Color.vividOnSurface)
                        .frame(width: metrics.circle, height: metrics.circle)
                        .background(Circle().fill(Color.white.opacity(isActive ? 0.18 : 0.10)))
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                    Text(caption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.vividOnSurface.opacity(isActive ? 0.92 : 0.60))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: sharesRow, vertical: false)
                }
                .mobileActionSlot(metrics)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(spokenLabel ?? caption))
        .accessibilityValue(isActive ? Text("On") : Text("Off"))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A named action that opens a menu. It never shows as active.
struct MobileNamedMenu<Items: View>: View {
    var icon = "ellipsis"
    let caption: LocalizedStringKey
    @ViewBuilder let items: () -> Items

    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle
    @Environment(\.phoneDetailActionsShareRow) private var sharesRow

    var body: some View {
        Menu {
            items()
        } label: {
            if usesTVStyle {
                MobileActionCircle(icon: icon, isActive: false)
            } else {
                let metrics = PhoneLabeledActionMetrics(sharesRow: sharesRow)
                VStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: metrics.iconSize, weight: .regular))
                        .foregroundStyle(Color.vividOnSurface)
                        .frame(width: metrics.circle, height: metrics.circle)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                    Text(caption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.vividOnSurface.opacity(0.60))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: sharesRow, vertical: false)
                }
                .mobileActionSlot(metrics)
            }
        }
        .accessibilityLabel(Text(caption))
    }
}

/// Shuffle as a menu row: in Play's long-press menu, and in the iPad hero's
/// More menu.
struct MobileShuffleMenuButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Shuffle", systemImage: "shuffle")
        }
    }
}

/// The More menu, which only the iPad hero shows. It collects the actions
/// that leave the hero's row.
struct MobileMoreMenu<Items: View>: View {
    @ViewBuilder let items: () -> Items

    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle

    var body: some View {
        if usesTVStyle {
            MobileNamedMenu(icon: "ellipsis", caption: "More options", items: items)
        }
    }
}

/// The bare circle the iPad hero uses for actions and selectors.
struct MobileActionCircle: View {
    let icon: String
    let isActive: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(Color.vividOnSurface)
            .frame(width: 52, height: 52)
            .background(Circle().fill(Color.white.opacity(isActive ? 0.18 : 0.10)))
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            .contentShape(Circle())
    }
}

/// Shows playback selectors either under the overview or beside Play, never
/// both: beside Play only in the iPad hero.
struct MobileSelectorsPlacement<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle
    @Environment(\.mobileSelectorsInActionRow) private var inActionRow

    var body: some View {
        if usesTVStyle == inActionRow {
            content()
        }
    }
}

private struct MobileMovesToMore: ViewModifier {
    @Environment(\.phoneDetailUsesTVStyle) private var usesTVStyle

    func body(content: Content) -> some View {
        if !usesTVStyle {
            content
        }
    }
}

extension View {
    /// Leaves the action row in the iPad hero, where the More menu offers it.
    func mobileMovesToMore() -> some View {
        modifier(MobileMovesToMore())
    }

    fileprivate func mobileActionSlot(_ metrics: PhoneLabeledActionMetrics) -> some View {
        frame(width: metrics.slotWidth)
            .frame(minWidth: metrics.slotWidth == nil ? metrics.circle : nil, minHeight: metrics.minHeight)
            .contentShape(Rectangle())
    }
}
#endif
