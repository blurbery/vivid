import SwiftUI

extension EnvironmentValues {
    /// Set by Home rows so their cards use Home's card size instead of the
    /// profile's interface preference.
    @Entry var homeCardPresentation: CardPresentationPreference? = nil
}

extension View {
    /// The source of the zoom transition into item detail, when there is a
    /// namespace to zoom within.
    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}

/// A poster with its title and year below. On iPhone and iPad a card with a
/// content id opens item detail itself; on Apple TV selecting it calls
/// `action`.
struct MediaCard: View {
    let title: String
    let posterUrl: String
    let thumbhash: String?
    let year: Int?
    let subtitle: String?
    let userState: MediaItemUserState?
    let titleFont: Font
    let usesHomeCaption: Bool
    let action: () -> Void
    let playAction: (() -> Void)?
    let focusedItemId: FocusState<String?>.Binding?
    let contentId: String?
    let onSetWatched: ((Bool) async -> Bool)?
    let cardWidthOverride: CGFloat?
    let episodeAccessibilityLabel: String?
    let onUserStateChanged: ((MediaItemUserState) -> Void)?

    @State private var watchedOverride: Bool?
    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?
    @Environment(\.homeCardPresentation) private var homeCardPresentation

    #if os(iOS)
    /// One per card, so the same title in two rows zooms from the right one.
    @State private var zoomSourceID = UUID().uuidString
    @Environment(AppRouter.self) private var router
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.itemDetailBrowseSource) private var browseSource
    #else
    @FocusState private var isStandaloneFocused: Bool
    @Environment(\.tvHomeStableRows) private var inHomeRows
    #endif

    /// `overlayData` is accepted for callers' sake and not drawn.
    init(
        title: String,
        posterUrl: String,
        thumbhash: String? = nil,
        year: Int? = nil,
        subtitle: String? = nil,
        userState: MediaItemUserState? = nil,
        overlayData: OverlayData? = nil,
        titleFont: Font = .vividSubheadline,
        usesHomeCaption: Bool = false,
        action: @escaping () -> Void,
        playAction: (() -> Void)? = nil,
        focusedItemId: FocusState<String?>.Binding? = nil,
        contentId: String? = nil,
        onSetWatched: ((Bool) async -> Bool)? = nil,
        cardWidthOverride: CGFloat? = nil,
        episodeAccessibilityLabel: String? = nil,
        onUserStateChanged: ((MediaItemUserState) -> Void)? = nil
    ) {
        self.title = title
        self.posterUrl = posterUrl
        self.thumbhash = thumbhash
        self.year = year
        self.subtitle = subtitle
        self.userState = userState
        self.titleFont = titleFont
        self.usesHomeCaption = usesHomeCaption
        self.action = action
        self.playAction = playAction
        self.focusedItemId = focusedItemId
        self.contentId = contentId
        self.onSetWatched = onSetWatched
        self.cardWidthOverride = cardWidthOverride
        self.episodeAccessibilityLabel = episodeAccessibilityLabel
        self.onUserStateChanged = onUserStateChanged
    }

    // MARK: State

    private var isWatched: Bool { watchedOverride ?? userState?.played ?? false }
    private var isFavorite: Bool { favoriteOverride ?? userState?.isFavorite ?? false }
    private var isOnWatchlist: Bool { watchlistOverride ?? userState?.inWatchlist ?? false }
    private var hasPersonalActions: Bool { contentId != nil && userState != nil }

    /// Size from Home or the profile; captions always follow Home's choice.
    private var presentation: CardPresentationPreference {
        var value = homeCardPresentation ?? UICustomizationPreferences.shared.cardPresentation
        value.caption = TVHomeCardPreferences.shared.presentation.caption
        return value
    }

    private var cardSize: CGSize {
        let width = (cardWidthOverride ?? VividTheme.posterCardWidth) * presentation.posterSize.scale
        return CGSize(width: width, height: width * VividTheme.posterCardHeight / VividTheme.posterCardWidth)
    }

    private var secondLine: String? {
        subtitle ?? year.map { String($0) }
    }

    private var accessibilityText: String {
        mediaCardAccessibilityLabel(
            title: title,
            episodeLabel: episodeAccessibilityLabel,
            year: year,
            isWatched: isWatched
        )
    }

    private var personalListItems: PersonalListMenuItems? {
        guard hasPersonalActions else { return nil }
        return PersonalListMenuItems(
            isFavorite: isFavorite,
            inWatchlist: isOnWatchlist,
            onToggleFavorite: toggleFavorite,
            onToggleWatchlist: toggleWatchlist
        )
    }

    var body: some View {
        card
            .onChange(of: userState) {
                watchedOverride = nil
                favoriteOverride = nil
                watchlistOverride = nil
            }
    }

    // MARK: Personal lists

    private func toggleFavorite() {
        guard let contentId else { return }
        let previous = isFavorite
        let newValue = !previous
        let onWatchlist = isOnWatchlist
        favoriteOverride = newValue
        Task {
            let saved = await PersonalListSync.setFavorite(
                contentId: contentId, isFavorite: newValue, inWatchlist: onWatchlist
            )
            if saved {
                onUserStateChanged?(MediaItemUserState(played: isWatched, isFavorite: newValue, inWatchlist: onWatchlist))
            } else {
                favoriteOverride = previous
            }
        }
    }

    private func toggleWatchlist() {
        guard let contentId else { return }
        let previous = isOnWatchlist
        let newValue = !previous
        let favorite = isFavorite
        watchlistOverride = newValue
        Task {
            let saved = await PersonalListSync.setWatchlist(
                contentId: contentId, isFavorite: favorite, inWatchlist: newValue
            )
            if saved {
                onUserStateChanged?(MediaItemUserState(played: isWatched, isFavorite: favorite, inWatchlist: newValue))
            } else {
                watchlistOverride = previous
            }
        }
    }

    // MARK: Artwork

    private func artwork(_ size: CGSize, pillPadding: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            AsyncImageView(url: posterUrl, thumbhash: thumbhash, targetSize: size, contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
            if isWatched {
                WatchedCheckPill()
                    .padding(pillPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
            #if os(iOS)
            DownloadedBadgeOverlay(contentId: contentId, padding: 6)
            #endif
        }
        .frame(width: size.width, height: size.height)
    }

    #if os(iOS)
    // MARK: iPhone and iPad

    private var card: some View {
        let size = cardSize
        let caption = presentation.caption
        return Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                artwork(size, pillPadding: 6)
                if caption.showsTitle {
                    titleText(width: size.width)
                }
                if caption.showsMetadata, let secondLine {
                    secondLineText(secondLine, width: size.width)
                }
            }
            .zoomTransitionSource(id: zoomSourceID, in: contentId == nil ? nil : zoomNamespace)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .personalListContextMenu(personalListItems)
        .frame(width: size.width)
    }

    @ViewBuilder
    private func titleText(width: CGFloat) -> some View {
        if usesHomeCaption {
            Text(verbatim: title)
                .homePosterTitleStyle()
                .frame(width: width, alignment: .leading)
        } else {
            Text(verbatim: title)
                .font(titleFont)
                .foregroundStyle(Color.vividOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
        }
    }

    @ViewBuilder
    private func secondLineText(_ text: String, width: CGFloat) -> some View {
        if usesHomeCaption {
            Text(verbatim: text)
                .homePosterSecondLineStyle()
                .frame(width: width, alignment: .leading)
        } else {
            Text(verbatim: text)
                .font(.vividCaption)
                .foregroundStyle(Color.vividSecondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
        }
    }

    private func open() {
        guard let contentId else {
            action()
            return
        }
        router.pendingZoomSourceID = zoomSourceID
        router.presentItemDetail(contentId: contentId, browseSource: browseSource)
    }

    #else
    // MARK: Apple TV

    private var isManaged: Bool { focusedItemId != nil && contentId != nil }

    private var isCardFocused: Bool {
        if let focusedItemId, let contentId { return focusedItemId.wrappedValue == contentId }
        return isStandaloneFocused
    }

    private var hasContextMenu: Bool { onSetWatched != nil || hasPersonalActions }

    private var card: some View {
        let size = cardSize
        let caption = presentation.caption
        return VStack(alignment: .leading, spacing: 22) {
            artworkButton(size)
            if caption.showsTitle {
                tvCaption(width: size.width, caption: caption)
            }
        }
        .frame(width: size.width)
        .background(
            TVCardDetailPreload(
                contentId: contentId,
                focusedItemId: isManaged ? focusedItemId : nil,
                standaloneFocused: isManaged ? nil : $isStandaloneFocused
            )
        )
    }

    private func artworkButton(_ size: CGSize) -> some View {
        focusBound(
            Button(action: action) {
                artwork(size, pillPadding: 10)
            }
            .buttonStyle(.card)
        )
        .onPlayPauseCommand(perform: playAction)
        .modifier(CardContextMenu(isEnabled: hasContextMenu) { contextMenuItems })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func focusBound(_ button: some View) -> some View {
        if let focusedItemId, let contentId {
            button.focused(focusedItemId, equals: contentId)
        } else {
            button.focused($isStandaloneFocused)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if onSetWatched != nil {
            Button(action: toggleWatched) {
                if isWatched {
                    Label("Mark as Unwatched", systemImage: "circle")
                } else {
                    Label("Mark as Watched", systemImage: "checkmark.circle")
                }
            }
        }
        if let personalListItems {
            personalListItems
        }
    }

    private func toggleWatched() {
        guard let onSetWatched else { return }
        let newValue = !isWatched
        watchedOverride = newValue
        Task {
            if !(await onSetWatched(newValue)) {
                watchedOverride = nil
            }
        }
    }

    private func tvCaption(width: CGFloat, caption: CardCaptionStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.vividPosterTitle)
                .foregroundStyle(isCardFocused ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
                .clipped()
            if caption.showsMetadata, let secondLine {
                Text(verbatim: secondLine)
                    .font(.vividPosterMetadata)
                    .foregroundStyle(Color.vividSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, alignment: .leading)
                    .clipped()
            }
        }
        .frame(
            width: width,
            height: inHomeRows ? TVHomeRowGeometry.captionHeight(caption.showsMetadata ? .titleMetadata : .title) : nil,
            alignment: .topLeading
        )
    }
    #endif
}

#if os(tvOS)
/// A context menu only when there is something to put in it.
private struct CardContextMenu<MenuItems: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let items: () -> MenuItems

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.contextMenu { items() }
        } else {
            content
        }
    }
}
#endif
