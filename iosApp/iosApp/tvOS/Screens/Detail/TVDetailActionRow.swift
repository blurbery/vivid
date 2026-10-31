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
                isFocused: focus.wrappedValue == .more,
                isPressed: false
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        // Up at the top of the page must never act as Back.
        .onMoveCommand { _ in }
        .onChange(of: claimKey.pageKey, initial: true) { _, key in
            // The same page coming back (from playback or a pushed page)
            // keeps its claim, so Play never takes focus a second time.
            guard key != claim.pageKey else { return }
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

/// The primary Play or Resume pill.
private struct TVDetailPlayButton: View {
    let action: TVDetailPlayAction
    var focus: FocusState<TVDetailHeroFocus?>.Binding
    let scope: Namespace.ID

    private var isFocused: Bool { focus.wrappedValue == .play }

    var body: some View {
        Button(action: action.play) {
            HStack(spacing: 16) {
                Image(systemName: "play.fill")
                    .font(.system(size: 31, weight: .bold))
                    .frame(width: 36, height: 36)
                if let progress = action.progress {
                    ResumeButtonProgressLabel(progress: progress)
                        .font(.system(size: 29, weight: .semibold))
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        titleText
                            .font(.system(size: 29, weight: .semibold))
                            .lineLimit(1)
                        if let subtitle = action.subtitle, !subtitle.isEmpty {
                            Text(verbatim: subtitle)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isFocused)
        }
        .buttonStyle(TVPillButtonStyle(
            kind: .primary,
            focusTreatment: .compact,
            stabilizesFocusMotion: true,
            fixedWidth: 280
        ))
        .disabled(action.title == nil)
        .focused(focus, equals: .play)
        .prefersDefaultFocus(action.title != nil, in: scope)
        .contextMenu {
            if action.offersStartOver {
                Button(action: action.startOver) {
                    Label("Start Over", systemImage: "backward.end.fill")
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

/// A round icon control. The visible surface follows the focus of an
/// invisible control laid over it, which takes the presses and speaks for
/// it.
struct TVDetailCircleButton<Control: View>: View {
    /// Never shown; keeps the circles' catalogue keys in use.
    let title: LocalizedStringKey
    let systemImage: String
    let isFocused: Bool
    let isPressed: Bool
    @ViewBuilder let control: () -> Control

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 31, weight: .semibold))
            .frame(width: 38, height: 38)
            .contentTransition(.symbolEffect(.replace))
            .frame(minWidth: 76, minHeight: 76)
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background(Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.10)))
            .clipShape(Capsule())
            .shadow(
                color: .black.opacity(isFocused ? 0.34 : 0),
                radius: isFocused ? 16 : 0,
                y: isFocused ? 6 : 0
            )
            .scaleEffect(isPressed ? 0.95 : 1)
            .animation(.smooth(duration: 0.28, extraBounce: 0), value: isFocused)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isPressed)
            .accessibilityHidden(true)
            .overlay {
                control()
            }
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
