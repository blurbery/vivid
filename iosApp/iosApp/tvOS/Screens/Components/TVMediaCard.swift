#if os(tvOS)
import SwiftUI

/// tvOS-only poster card. Uses the cached Nuke renderer so scrolling through
/// a large grid doesn't re-download posters as cells are reused.
///
/// `.buttonStyle(.card)` gives us native focus lift + parallax + shadow, so
/// we do not roll our own scale animation. A title caption lives below the
/// card and brightens on focus.
struct TVMediaCard: View {
    let title: String
    let posterUrl: String
    var posterThumbhash: String? = nil
    var year: Int? = nil
    /// Optional second caption line rendered in place of the year.
    var subtitle: String? = nil
    var userState: MediaItemUserState? = nil
    /// Data for optional overlay badges. `nil` skips overlay rendering;
    /// callers without per-item OverlaySummary should leave it off.
    var overlayData: OverlayData? = nil
    var mediaTypeLabel: String? = nil
    let action: () -> Void
    /// Remote Play/Pause shortcut. When nil, the card does not intercept the
    /// command (used for non-playable containers such as series).
    var playAction: (() -> Void)? = nil
    /// Width of the poster. Defaults to the theme's standard poster size.
    /// Override with a smaller value in space-constrained grids (e.g. the
    /// Library tab where the alphabet rail forces cards to shrink).
    var cardWidth: CGFloat = VividTheme.posterCardWidth
    /// An optional size preference for rails that follow Home settings.
    var posterSize: CardPosterSize? = nil
    var loadsArtwork: Bool = true
    var prefersDefaultFocus: Bool = false
    var defaultFocusNamespace: Namespace.ID? = nil
    var leadingCaption = true
    /// Optional external focus hook so a parent rail can make this card a
    /// `.defaultFocus` target on d-pad entry. The focusable element is the
    /// inner Button, so the binding is applied there — a `.focused` on the
    /// card's outer VStack silently no-ops. Mirrors `MediaCard.focusedItemId`.
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusContentId: String? = nil
    /// Catalog identity for the long-press favorite/watchlist menu.
    /// `nil` (or a nil `userState`) leaves the card without a menu.
    var contentId: String? = nil
    @FocusState private var isFocused: Bool
    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var cardCaptions = TVHomeCardPreferences.shared
    @EnvironmentObject private var overlayStore: OverlayPrefsStore

    private var resolvedCardWidth: CGFloat {
        cardWidth * (posterSize ?? uiCustomization.cardPresentation.posterSize).scale
    }

    private var cardHeight: CGFloat {
        resolvedCardWidth * 1.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            posterButton
                .personalListContextMenu(hasPersonalActions ? personalMenuItems : nil)
            if cardCaptions.presentation.caption.showsTitle {
                caption
            }
        }
        .frame(width: resolvedCardWidth)
        .onChange(of: userState) { _, _ in
            favoriteOverride = nil
            watchlistOverride = nil
        }
    }

    // MARK: - Favorite / watchlist context actions

    private var hasPersonalActions: Bool {
        contentId != nil && userState != nil
    }

    private var isFavorite: Bool {
        favoriteOverride ?? (userState?.isFavorite == true)
    }

    private var isInWatchlist: Bool {
        watchlistOverride ?? (userState?.inWatchlist == true)
    }

    private var personalMenuItems: PersonalListMenuItems {
        PersonalListMenuItems(
            isFavorite: isFavorite,
            inWatchlist: isInWatchlist,
            onToggleFavorite: togglePersonalFavorite,
            onToggleWatchlist: togglePersonalWatchlist
        )
    }

    private func togglePersonalFavorite() {
        guard let contentId else { return }
        let newValue = !isFavorite
        let watchlist = isInWatchlist
        favoriteOverride = newValue
        Task {
            if await PersonalListSync.setFavorite(
                contentId: contentId, isFavorite: newValue, inWatchlist: watchlist
            ) == false {
                favoriteOverride = !newValue // Revert on failure
            }
        }
    }

    private func togglePersonalWatchlist() {
        guard let contentId else { return }
        let newValue = !isInWatchlist
        let favorite = isFavorite
        watchlistOverride = newValue
        Task {
            if await PersonalListSync.setWatchlist(
                contentId: contentId, isFavorite: favorite, inWatchlist: newValue
            ) == false {
                watchlistOverride = !newValue // Revert on failure
            }
        }
    }

    @ViewBuilder
    private var posterButton: some View {
        Button(action: action) { posterImage }
            .buttonStyle(.card)
            .focused($isFocused)
            .applyDefaultFocusIfNeeded(prefersDefaultFocus, namespace: defaultFocusNamespace)
            .applyRailFocus(focusBinding, contentId: focusContentId)
            .applyTVCardPlayPauseAction(playAction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Subviews

    private var posterImage: some View {
        ZStack(alignment: .topTrailing) {
            if loadsArtwork {
                CachedAsyncImage(
                    url: posterUrl,
                    targetSize: CGSize(width: resolvedCardWidth, height: cardHeight),
                    thumbhash: posterThumbhash,
                    contentMode: .fill
                )
                .frame(width: resolvedCardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
            } else {
                Color.vividSurface.frame(width: resolvedCardWidth, height: cardHeight)
            }

            if let overlayData, overlayStore.enabled {
                CardOverlays(data: overlayData, prefs: overlayStore.prefs, variant: .poster)
                    .frame(width: resolvedCardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
            }

            if let mediaTypeLabel {
                MediaTypePill(title: mediaTypeLabel)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if userState?.played == true {
                watchedBadge
                    .padding(10)
            }
        }
        .frame(width: resolvedCardWidth, height: cardHeight)

    }

    // Title with year directly underneath in a
    // lighter weight + dimmer color. Single-line truncation keeps the
    // caption a uniform two-row block across the whole grid.
    private var caption: some View {
        VStack(alignment: leadingCaption ? .leading : .center, spacing: 4) {
            Text(title)
                .font(.vividPosterTitle)
                .foregroundColor(isFocused ? .vividOnSurface : .vividOnSurface.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: resolvedCardWidth, alignment: leadingCaption ? .leading : .center)
                .clipped()


            if cardCaptions.presentation.caption.showsMetadata,
               let secondLine = subtitle ?? year.map(String.init) {
                Text(secondLine)
                    .font(.vividPosterMetadata)
                    .foregroundColor(.vividSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: resolvedCardWidth, alignment: leadingCaption ? .leading : .center)
                    .clipped()
            }
        }
        .multilineTextAlignment(leadingCaption ? .leading : .center)
        .frame(width: resolvedCardWidth, alignment: leadingCaption ? .leading : .center)
    }

    private var watchedBadge: some View {
        TVWatchedBadge()
    }

    private var accessibilityDescription: String {
        let secondLine = subtitle ?? year.map(String.init)
        var components = [title]
        if let mediaTypeLabel { components.append(mediaTypeLabel) }
        if let secondLine {
            components.append(secondLine)
        }
        if userState?.played == true {
            components.append("Watched")
        }
        return components.joined(separator: ", ")
    }
}

private extension View {
    @ViewBuilder
    func applyTVCardPlayPauseAction(_ action: (() -> Void)?) -> some View {
        if let action {
            self.onPlayPauseCommand(perform: action)
        } else {
            self
        }
    }

    /// Binds the inner button to a parent rail's `@FocusState` so the rail can
    /// route d-pad-entry default focus onto this specific card. No-op when the
    /// rail doesn't manage focus. Mirrors `MediaCard.applyRowFocus`.
    @ViewBuilder
    func applyRailFocus(_ binding: FocusState<String?>.Binding?, contentId: String?) -> some View {
        if let binding, let contentId {
            self.focused(binding, equals: contentId)
        } else {
            self
        }
    }
}

#endif
