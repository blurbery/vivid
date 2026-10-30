import SwiftUI

#if os(tvOS)
/// A landscape still for Home rows (Continue Watching, Next Up and episode
/// rows), with resume progress or runtime status over the artwork.
struct EpisodeThumbCard: View {
    let item: SectionItem
    let showProgress: Bool
    let action: () -> Void
    let showsEpisodeDetails: Bool
    let playAction: (() -> Void)?
    let focusedItemId: FocusState<String?>.Binding?
    let contextPlayTitle: String?
    let onRemoveFromContinueWatching: (() -> Void)?
    let onSetWatched: ((Bool) async -> Bool)?
    let usesRuntimeStatus: Bool
    let usesSeriesBackdrop: Bool

    @State private var watchedOverride: Bool?
    @FocusState private var isStandaloneFocused: Bool
    @Environment(\.homeCardPresentation) private var homeCardPresentation
    @Environment(\.tvHomeStableRows) private var inHomeRows

    /// `initialIsFavorite` is accepted for callers' sake and not used.
    init(
        item: SectionItem,
        showProgress: Bool = false,
        action: @escaping () -> Void,
        showsEpisodeDetails: Bool = false,
        playAction: (() -> Void)? = nil,
        focusedItemId: FocusState<String?>.Binding? = nil,
        contextPlayTitle: String? = nil,
        onRemoveFromContinueWatching: (() -> Void)? = nil,
        onSetWatched: ((Bool) async -> Bool)? = nil,
        initialIsFavorite: Bool = false,
        usesRuntimeStatus: Bool = false,
        usesSeriesBackdrop: Bool = false
    ) {
        self.item = item
        self.showProgress = showProgress
        self.action = action
        self.showsEpisodeDetails = showsEpisodeDetails
        self.playAction = playAction
        self.focusedItemId = focusedItemId
        self.contextPlayTitle = contextPlayTitle
        self.onRemoveFromContinueWatching = onRemoveFromContinueWatching
        self.onSetWatched = onSetWatched
        self.usesRuntimeStatus = usesRuntimeStatus
        self.usesSeriesBackdrop = usesSeriesBackdrop
    }

    // MARK: Values

    private var isWatched: Bool { watchedOverride ?? (item.userState?.played == true) }

    private var progressFraction: Double? {
        guard watchedOverride == nil,
              let position = item.positionSeconds, let duration = item.durationSeconds,
              position > 0, duration > 0 else { return nil }
        return position / duration
    }

    private var cardSize: CGSize {
        let presentation = homeCardPresentation ?? UICustomizationPreferences.shared.cardPresentation
        let width = VividTheme.thumbnailCardWidth * presentation.posterSize.scale
        return CGSize(width: width, height: width * VividTheme.thumbnailCardHeight / VividTheme.thumbnailCardWidth)
    }

    private var caption: CardCaptionStyle { TVHomeCardPreferences.shared.presentation.caption }

    private var title: String { item.seriesTitle ?? item.title }

    private var secondLine: String? {
        let isResumeCard = onRemoveFromContinueWatching != nil
        if (isResumeCard || showsEpisodeDetails) && EpisodeCardCaption.isEpisode(item) {
            var codeParts: [String] = []
            if let season = item.seasonNumber {
                let number = String(season)
                codeParts.append(String(localized: "S\(number)", comment: "Season number in an episode code, e.g. S1"))
            }
            if let episode = item.episodeNumber {
                let number = String(episode)
                codeParts.append(String(localized: "E\(number)", comment: "Episode number in an episode code, e.g. E2"))
            }
            let code = codeParts.joined(separator: " ")
            var parts: [String] = []
            if !code.isEmpty { parts.append(code) }
            if let episodeTitle = EpisodeCardCaption.episodeTitle(for: item) { parts.append(episodeTitle) }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{2013} ")
        }
        if let line = EpisodeCardCaption.line(for: item) { return line }
        if item.seriesTitle != nil { return item.title }
        return item.year.map { String($0) }
    }

    private var art: (url: String, thumbhash: String?) {
        if usesSeriesBackdrop { return HomeSeriesBackdrops.shared.art(for: item) }
        let thumbhash = item.backdropThumbhash ?? item.posterThumbhash
        if let backdrop = item.backdropUrl, !backdrop.isEmpty { return (backdrop, thumbhash) }
        return (item.posterUrl ?? "", thumbhash)
    }

    private var accessibilityText: String {
        var parts = [title]
        if let spoken = EpisodeCardCaption.accessibilityLabel(for: item) {
            parts.append(spoken)
        } else if let secondLine {
            parts.append(secondLine)
        }
        if isWatched { parts.append(String(localized: "Watched", comment: "Spoken status of a watched title")) }
        if usesRuntimeStatus,
           let runtime = MediaRuntimeStatusOverlay.displayedRuntime(minutes: item.runtime, duration: item.durationSeconds) {
            parts.append(String(localized: "\(runtime) minutes", comment: "Spoken runtime"))
        }
        return parts.joined(separator: ", ")
    }

    private var isCardFocused: Bool {
        if let focusedItemId { return focusedItemId.wrappedValue == item.contentId }
        return isStandaloneFocused
    }

    private var canRemove: Bool {
        onRemoveFromContinueWatching != nil && MediaServerProvider.active.supportsContinueWatchingRemoval
    }

    private var hasContextMenu: Bool {
        (contextPlayTitle != nil && playAction != nil) || onSetWatched != nil || canRemove
    }

    // MARK: Body

    var body: some View {
        let size = cardSize
        let style = caption
        VStack(alignment: .leading, spacing: 14) {
            artworkButton(size)
            if style.showsTitle {
                captionBlock(width: size.width, caption: style)
            }
        }
        .frame(width: size.width)
        .focusSection()
        .onChange(of: item.userState?.played) { watchedOverride = nil }
        .onChange(of: item.positionSeconds) { watchedOverride = nil }
    }

    private func artworkButton(_ size: CGSize) -> some View {
        focusBound(
            Button(action: action) {
                artwork(size)
                    .overlay(alignment: .bottom) { progressOverlay(size) }
            }
            .buttonStyle(.card)
        )
        .onPlayPauseCommand(perform: playAction)
        .modifier(EpisodeCardContextMenu(isEnabled: hasContextMenu) { contextMenuItems })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func focusBound(_ button: some View) -> some View {
        if let focusedItemId {
            button.focused(focusedItemId, equals: item.contentId)
        } else {
            button.focused($isStandaloneFocused)
        }
    }

    @ViewBuilder
    private func progressOverlay(_ size: CGSize) -> some View {
        if !usesRuntimeStatus, showProgress, let fraction = progressFraction, fraction > 0 {
            ResumeProgressBar(value: fraction, duration: item.durationSeconds)
                .frame(width: size.width, height: size.height, alignment: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func artwork(_ size: CGSize) -> some View {
        let source = art
        return ZStack(alignment: .bottomLeading) {
            AsyncImageView(url: source.url, thumbhash: source.thumbhash, targetSize: size, contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if usesRuntimeStatus {
                MediaRuntimeStatusOverlay(
                    isPlayed: isWatched,
                    duration: item.durationSeconds,
                    progress: showProgress ? progressFraction : nil,
                    runtimeMinutes: item.runtime
                )
            }
            if isWatched && !usesRuntimeStatus {
                HStack {
                    Spacer()
                    TVWatchedBadge()
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let contextPlayTitle, let playAction {
            Button(action: playAction) {
                Label(contextPlayTitle, systemImage: "play.fill")
            }
        }
        if onSetWatched != nil {
            Button(action: toggleWatched) {
                if isWatched {
                    Label("Mark as Unwatched", systemImage: "circle")
                } else {
                    Label("Mark as Watched", systemImage: "checkmark.circle")
                }
            }
        }
        if canRemove, let onRemoveFromContinueWatching {
            Button(role: .destructive, action: onRemoveFromContinueWatching) {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
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

    private func captionBlock(width: CGFloat, caption: CardCaptionStyle) -> some View {
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
        .frame(width: width, height: inHomeRows ? TVHomeRowGeometry.captionHeight(caption) : nil, alignment: .topLeading)
    }
}

/// A context menu only when there is something to put in it.
private struct EpisodeCardContextMenu<MenuItems: View>: ViewModifier {
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

/// Warms a card's item detail while it has focus, outside Home's rows.
/// Draws nothing.
struct TVCardDetailPreload: View {
    let contentId: String?
    let focusedItemId: FocusState<String?>.Binding?
    let standaloneFocused: FocusState<Bool>.Binding?
    let focusId: String?

    @Environment(\.tvHomeStableRows) private var inHomeRows

    init(
        contentId: String?,
        focusedItemId: FocusState<String?>.Binding?,
        standaloneFocused: FocusState<Bool>.Binding?,
        focusId: String? = nil
    ) {
        self.contentId = contentId
        self.focusedItemId = focusedItemId
        self.standaloneFocused = standaloneFocused
        self.focusId = focusId
    }

    private var isActive: Bool {
        guard let contentId else { return false }
        if let focusedItemId, focusedItemId.wrappedValue == (focusId ?? contentId) { return true }
        return standaloneFocused?.wrappedValue == true
    }

    var body: some View {
        let active = isActive
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: active) {
                guard active, !inHomeRows, let contentId else { return }
                await ItemDetailCache.shared.prepareFocusedDetail(contentId: contentId)
            }
    }
}
#endif
