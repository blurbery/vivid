#if os(tvOS)
import SwiftUI

/// A catalogue poster with the system card lift and Home's caption choice.
/// `overlayData` and `leadingCaption` are accepted for callers' sake; overlays
/// are not drawn and the caption is always leading.
struct TVMediaCard: View {
    let title: String
    let posterUrl: String
    let posterThumbhash: String?
    let year: Int?
    let userState: MediaItemUserState?
    let action: () -> Void
    let playAction: (() -> Void)?
    let cardWidth: CGFloat
    let posterSize: CardPosterSize?
    let loadsArtwork: Bool
    let prefersDefaultFocus: Bool
    let defaultFocusNamespace: Namespace.ID?
    let focusBinding: FocusState<String?>.Binding?
    let focusContentId: String?
    let contentId: String?

    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?
    @FocusState private var isFocused: Bool

    init(
        title: String,
        posterUrl: String,
        posterThumbhash: String? = nil,
        year: Int? = nil,
        userState: MediaItemUserState? = nil,
        overlayData: OverlayData? = nil,
        action: @escaping () -> Void,
        playAction: (() -> Void)? = nil,
        cardWidth: CGFloat = VividTheme.posterCardWidth,
        posterSize: CardPosterSize? = nil,
        loadsArtwork: Bool = true,
        prefersDefaultFocus: Bool = false,
        defaultFocusNamespace: Namespace.ID? = nil,
        leadingCaption: Bool = true,
        focusBinding: FocusState<String?>.Binding? = nil,
        focusContentId: String? = nil,
        contentId: String? = nil
    ) {
        self.title = title
        self.posterUrl = posterUrl
        self.posterThumbhash = posterThumbhash
        self.year = year
        self.userState = userState
        self.action = action
        self.playAction = playAction
        self.cardWidth = cardWidth
        self.posterSize = posterSize
        self.loadsArtwork = loadsArtwork
        self.prefersDefaultFocus = prefersDefaultFocus
        self.defaultFocusNamespace = defaultFocusNamespace
        self.focusBinding = focusBinding
        self.focusContentId = focusContentId
        self.contentId = contentId
    }

    private var posterFrame: CGSize {
        let scale = (posterSize ?? UICustomizationPreferences.shared.cardPresentation.posterSize).scale
        let width = cardWidth * scale
        return CGSize(width: width, height: width * 1.5)
    }

    private var isPlayed: Bool { userState?.played ?? false }
    private var isFavorite: Bool { favoriteOverride ?? userState?.isFavorite ?? false }
    private var isOnWatchlist: Bool { watchlistOverride ?? userState?.inWatchlist ?? false }

    private var accessibilityText: String {
        var parts = [title]
        if let year { parts.append(String(year)) }
        if isPlayed { parts.append(String(localized: "Watched")) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var personalListItems: PersonalListMenuItems? {
        guard contentId != nil, userState != nil else { return nil }
        return PersonalListMenuItems(
            isFavorite: isFavorite,
            inWatchlist: isOnWatchlist,
            onToggleFavorite: toggleFavorite,
            onToggleWatchlist: toggleWatchlist
        )
    }

    var body: some View {
        let size = posterFrame
        let caption = TVHomeCardPreferences.shared.presentation.caption
        VStack(alignment: .leading, spacing: 16) {
            posterButton(size)
            if caption.showsTitle {
                captionView(width: size.width, showsYear: caption.showsMetadata)
            }
        }
        .frame(width: size.width)
        .background(
            TVCardDetailPreload(
                contentId: contentId ?? focusContentId,
                focusedItemId: focusContentId == nil ? nil : focusBinding,
                standaloneFocused: $isFocused,
                focusId: focusContentId
            )
        )
        .onChange(of: userState) {
            favoriteOverride = nil
            watchlistOverride = nil
        }
    }

    private func posterButton(_ size: CGSize) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(
                    url: posterUrl,
                    targetSize: size,
                    thumbhash: loadsArtwork ? posterThumbhash : nil,
                    contentMode: .fill,
                    isArtworkResident: loadsArtwork
                )
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: VividTheme.cornerRadius))
                if isPlayed {
                    WatchedCheckPill()
                        .padding(10)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .buttonStyle(.card)
        .focused($isFocused)
        .modifier(CallerFocus(binding: focusBinding, id: focusContentId))
        .applyDefaultFocusIfNeeded(prefersDefaultFocus, namespace: defaultFocusNamespace)
        .onPlayPauseCommand(perform: playAction)
        .personalListContextMenu(personalListItems)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func captionView(width: CGFloat, showsYear: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.vividPosterTitle)
                .foregroundStyle(isFocused ? Color.vividOnSurface : Color.vividOnSurface.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
                .clipped()
            if showsYear, let year {
                Text(verbatim: String(year))
                    .font(.vividPosterMetadata)
                    .foregroundStyle(Color.vividSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, alignment: .leading)
                    .clipped()
            }
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: Personal lists

    private func toggleFavorite() {
        guard let contentId else { return }
        let previous = isFavorite
        let onWatchlist = isOnWatchlist
        favoriteOverride = !previous
        Task {
            let saved = await PersonalListSync.setFavorite(
                contentId: contentId, isFavorite: !previous, inWatchlist: onWatchlist
            )
            if !saved { favoriteOverride = previous }
        }
    }

    private func toggleWatchlist() {
        guard let contentId else { return }
        let previous = isOnWatchlist
        let favorite = isFavorite
        watchlistOverride = !previous
        Task {
            let saved = await PersonalListSync.setWatchlist(
                contentId: contentId, isFavorite: favorite, inWatchlist: !previous
            )
            if !saved { watchlistOverride = previous }
        }
    }
}

/// Ties the card's button to the caller's focus state under the given id.
private struct CallerFocus: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let id: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let binding, let id {
            content.focused(binding, equals: id)
        } else {
            content
        }
    }
}
#endif
