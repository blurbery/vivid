#if !os(tvOS)
import SwiftUI

// MARK: - Labelled secondary action

extension EnvironmentValues {
    /// True while the named actions share Play's row on the iPhone Duo.
    @Entry var phoneDetailActionsShareRow = false
}

/// Circle and slot sizes for the named actions. Beside Play on the Duo the
/// circles match Play's 52-point height and sit in equal slots, so every gap
/// in the row is the same; captions may run a little wider than their slot.
struct PhoneLabeledActionMetrics {
    let sharesRow: Bool
    var circle: CGFloat { sharesRow ? 52 : 42 }
    var iconSize: CGFloat { sharesRow ? 21 : 19 }
    var slotWidth: CGFloat? { sharesRow ? circle : nil }
    static let rowSpacing: CGFloat = 12
}

/// One named secondary action — a filled circle with no outline, over a
/// caption. This mirrors the approved detail treatment: the icon remains a
/// generous touch target while the caption removes any guesswork.
///
/// The shipping page gives favourite, watchlist, watched, download, and the
/// overflow menu the same 44pt circular silhouette, centred under Play with
/// nothing tying them to it. Five identical circles is a guessing game; a
/// heart and a bookmark are not self-evidently different commitments. Naming
/// them costs one line of 10pt text each and removes the guess entirely.
struct PhoneLabeledAction: View {
    let icon: String
    var iconActive: String? = nil
    var isActive: Bool = false
    let label: String
    /// Spoken instead of `label` when set, so VoiceOver can say "Remove from
    /// Favorites" where the visual only changes tint and fill. A caption that
    /// reads the same in both states tells a VoiceOver user neither what is
    /// true now nor what activating will do.
    var accessibilityLabelOverride: String? = nil
    let action: () -> Void
    @Environment(\.phoneDetailActionsShareRow) private var sharesRow

    private var resolvedIcon: String {
        if isActive, let iconActive { return iconActive }
        return icon
    }

    var body: some View {
        let metrics = PhoneLabeledActionMetrics(sharesRow: sharesRow)
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: resolvedIcon)
                    .font(.system(size: metrics.iconSize, weight: .regular))
                    .foregroundStyle(Color.vividOnSurface)
                    .frame(width: metrics.circle, height: metrics.circle)
                    .background(
                        Circle().fill(Color.white.opacity(isActive ? 0.18 : 0.10))
                    )
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))

                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.vividOnSurface.opacity(isActive ? 0.92 : 0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: sharesRow, vertical: false)
            }
            .frame(width: metrics.slotWidth)
            .frame(maxWidth: metrics.slotWidth == nil ? .infinity : nil, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabelOverride ?? label)
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// Menu-backed peer of `PhoneLabeledAction`, for the overflow entry.
struct PhoneLabeledMenu<MenuContent: View>: View {
    var icon: String = "ellipsis"
    let label: String
    @ViewBuilder let menu: () -> MenuContent
    @Environment(\.phoneDetailActionsShareRow) private var sharesRow

    var body: some View {
        let metrics = PhoneLabeledActionMetrics(sharesRow: sharesRow)
        Menu {
            menu()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: metrics.iconSize, weight: .regular))
                    .foregroundStyle(Color.vividOnSurface)
                    .frame(width: metrics.circle, height: metrics.circle)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.vividOnSurface.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize(horizontal: sharesRow, vertical: false)
            }
            .frame(width: metrics.slotWidth)
            .frame(maxWidth: metrics.slotWidth == nil ? .infinity : nil, minHeight: 58)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Action row container

/// Evenly distributes the named actions across the content width and rules
/// them off from the overview below, so the cluster reads as one band of
/// controls rather than loose ornaments.
struct PhoneLabeledActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let sharesRow = PhoneDuo.usesWideDetailLayout(horizontalSizeClass)
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: sharesRow ? PhoneLabeledActionMetrics.rowSpacing : 0) {
                content()
            }
            .frame(maxWidth: sharesRow ? nil : .infinity)

            // Beside Play on the Duo, `PhoneDetailPrimaryActions` draws the
            // rule under the whole row instead.
            if !PhoneDuo.usesWideDetailLayout(horizontalSizeClass) {
                PhoneDetailActionRule()
            }
        }
    }
}

/// Play above the named actions. On the iPhone Duo's inner screen, which is
/// too wide for a full-width Play, they share one row instead.
struct PhoneDetailPrimaryActions<Play: View, Actions: View>: View {
    /// The gap between Play and the actions when they're stacked, as each
    /// detail page had it.
    var stackedSpacing: CGFloat = 14
    @ViewBuilder let play: () -> Play
    @ViewBuilder let actions: () -> Actions
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let sharesRow = PhoneDuo.usesWideDetailLayout(horizontalSizeClass)
        // Top alignment lines Play up with the circles; captions hang below.
        // Play takes the rest of the row, so the row spans the same width as
        // the playback selectors under it.
        let layout = sharesRow
            ? AnyLayout(HStackLayout(alignment: .top, spacing: PhoneLabeledActionMetrics.rowSpacing))
            : AnyLayout(VStackLayout(spacing: stackedSpacing))
        VStack(spacing: 12) {
            layout {
                play()
                actions()
                    .environment(\.phoneDetailActionsShareRow, sharesRow)
            }
            if sharesRow {
                PhoneDetailActionRule()
            }
        }
    }
}

private struct PhoneDetailActionRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
    }
}
#endif
