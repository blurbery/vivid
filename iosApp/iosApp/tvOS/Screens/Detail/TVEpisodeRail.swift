#if os(tvOS)
import SwiftUI

/// Horizontal rail of episode cards for the tvOS series/season/episode
/// detail screens. The caller owns Select semantics: legacy season/episode
/// pages can still navigate, while the Series overview launches playback
/// directly and uses focus changes to update its in-place episode state.
///
/// Pass `currentContentId` to highlight the episode currently represented
/// by the surrounding detail experience. Legacy rails center that card on
/// first appearance. Series uses Home's native thumbnail controls inside
/// the season pager.
struct TVEpisodeRail: View {
    let episodes: [EpisodeListItem]
    let onSelect: (String) -> Void
    /// Optional Play action surfaced by the long-press context menu. Series
    /// supplies this even though its normal Select action also plays, keeping
    /// the context menu explicit and useful alongside watched-state actions.
    var onPlay: ((String) -> Void)? = nil
    var onFocusedEpisodeChange: ((String?) -> Void)? = nil
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)? = nil
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)? = nil
    /// When non-nil, the matching card is visually highlighted and anchored
    /// at first appearance.
    var currentContentId: String? = nil
    var currentContentIsFavorite = false
    var favoriteStates: [String: Bool] = [:]
    var seriesId: String? = nil
    var seriesTitle: String? = nil
    var prefersCurrentContentFocus = false
    /// Series opts into a larger carousel card. The default keeps the
    /// approved 480-point geometry on existing season/episode pages.
    var baseCardWidth: CGFloat = 480
    /// Series can exactly reuse Home's 360×200 thumbnail aspect while legacy
    /// episode pages retain their existing 16:9 geometry.
    var cardHeightRatio: CGFloat = 9 / 16
    var cardSpacing: CGFloat = 54
    var anchorsFocusedCard = false
    /// Anchored Series rails hand vertical exits back to the parent while
    /// native focus owns movement between episode cards.
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    /// Non-zero changes restore focus to the current Series episode card.
    var focusRequest = 0

    @FocusState private var focusedCardId: String?
    @State private var uiCustomization = UICustomizationPreferences.shared

    @ViewBuilder
    var body: some View {
        if anchorsFocusedCard {
            homeStyleRail
        } else {
            legacyRail
        }
    }

    /// Series uses the same component and card path as Home's Continue
    /// Watching row. The season tabs and their page transition stay outside
    /// this view and are unchanged.
    private var homeStyleRail: some View {
        MediaRow(
            title: "Episodes",
            items: homeStyleItems,
            onItemTap: onSelect,
            showsHeader: false,
            usesLazyCardLayout: false,
            onItemPlay: homeStylePlayAction,
            showProgress: true,
            layout: .thumbnail,
            usesProvidedThumbnailTapAction: true,
            usesEpisodeCaption: true,
            defersOffscreenArtwork: true,
            prefersDefaultFocusOnFirstItem: true,
            focusRequest: focusRequest,
            defaultFocusItemId: currentContentId,
            focusRequestItemId: currentContentId,
            showsPlayInContextMenu: onPlay != nil,
            onSetWatched: homeStyleWatchedAction,
            onSetFavorite: homeStyleFavoriteAction,
            onMoveUp: onMoveUp,
            onItemFocus: { item in
                onFocusedEpisodeChange?(item.contentId)
            },
            cardVerticalPadding: 12,
            horizontalContentMargin: 0,
            trailingContentMargin: 32,
            onMoveDown: onMoveDown
        )
        // The enclosing season pager is deliberately scroll-disabled so its
        // tabs can change pages without the remote dragging that outer rail.
        // Re-enable scrolling for the nested Home carousel itself.
        .environment(\.isScrollEnabled, true)
        .frame(height: anchoredRailHeight, alignment: .topLeading)
        .onDisappear {
            onFocusedEpisodeChange?(nil)
        }
    }

    private var homeStyleItems: [SectionItem] {
        episodes.map { episode in
            SectionItem(
                episode: episode,
                seriesId: seriesId,
                seriesTitle: seriesTitle,
                isFavorite: favoriteStates[episode.contentId]
                    ?? (currentContentId == episode.contentId && currentContentIsFavorite)
            )
        }
    }

    private var homeStylePlayAction: ((SectionItem) -> Void)? {
        guard let onPlay else { return nil }
        return { item in onPlay(item.contentId) }
    }

    private var homeStyleWatchedAction: ((SectionItem, Bool) async -> Bool)? {
        guard let onSetWatched else { return nil }
        return { item, played in
            await onSetWatched(item.contentId, played)
        }
    }

    private var homeStyleFavoriteAction: ((SectionItem, Bool) async -> Bool)? {
        guard let onSetFavorite else { return nil }
        return { item, isFavorite in
            await onSetFavorite(item.contentId, isFavorite)
        }
    }

    private var legacyRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(episodes) { episode in
                        TVEpisodeCard(
                            episode: episode,
                            isCurrent: currentContentId == episode.contentId,
                            baseCardWidth: baseCardWidth,
                            posterSize: uiCustomization.cardPresentation.posterSize,
                            captionStyle: uiCustomization.cardPresentation.caption,
                            onSelect: { onSelect(episode.contentId) },
                            onPlay: onPlay,
                            onSetWatched: onSetWatched,
                            initialIsFavorite: currentContentId == episode.contentId
                                ? currentContentIsFavorite
                                : favoriteStates[episode.contentId] ?? false,
                            onSetFavorite: onSetFavorite
                        )
                        .id(episode.contentId)
                        .focused($focusedCardId, equals: episode.contentId)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 12)
            }
            .applyEpisodeScrollTargetBehavior(anchorsFocusedCard)
            .focusSection()
            .applyCurrentEpisodeDefaultFocus(
                prefersCurrentContentFocus ? currentContentId : nil,
                binding: $focusedCardId
            )
            .scrollClipDisabled()
            .onChange(of: focusedCardId) { _, contentId in
                onFocusedEpisodeChange?(contentId)
            }
            .onDisappear {
                onFocusedEpisodeChange?(nil)
            }
            .onAppear {
                guard let id = currentContentId else { return }
                // Run on next tick so the LazyHStack has instantiated the
                // target cell before we try to anchor on it.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: VividTheme.normalDuration)) {
                        proxy.scrollTo(id, anchor: anchorsFocusedCard ? .leading : .center)
                    }
                }
            }
        }
    }

    private var anchoredRailHeight: CGFloat {
        let width = baseCardWidth * uiCustomization.cardPresentation.posterSize.scale
        return width * cardHeightRatio
            + (uiCustomization.cardPresentation.caption.showsTitle ? 46 : 0)
            + 24
    }
}

private extension SectionItem {
    /// Adapts a season episode to the same model consumed by Home's
    /// Continue Watching carousel. This is data mapping only; the Home row
    /// remains the sole owner of horizontal scrolling and focus behavior.
    init(
        episode: EpisodeListItem,
        seriesId: String?,
        seriesTitle: String?,
        isFavorite: Bool
    ) {
        contentId = episode.contentId
        type = "episode"
        title = episode.title ?? "Episode \(episode.episodeNumber)"
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        seasonNumber = episode.seasonNumber
        episodeNumber = episode.episodeNumber
        year = nil
        genres = nil
        status = nil
        ratingImdb = nil
        ratingTmdb = nil
        ratingRtCritic = nil
        ratingRtAudience = nil
        contentRating = nil
        runtime = episode.runtime
        originalLanguage = nil
        studios = nil
        networks = nil
        showStatus = nil
        overview = episode.overview
        itemSource = nil
        positionSeconds = episode.userData?.positionSeconds
        durationSeconds = episode.userData?.durationSeconds
        progressUpdatedAt = nil
        posterUrl = episode.stillUrl
        posterThumbhash = episode.stillThumbhash
        backdropUrl = episode.stillUrl
        backdropThumbhash = episode.stillThumbhash
        logoUrl = nil
        userState = MediaItemUserState(
            played: episode.userData?.played ?? false,
            isFavorite: isFavorite
        )
        overlaySummary = nil
    }
}

private extension View {
    @ViewBuilder
    func applyEpisodeScrollTargetBehavior(_ enabled: Bool) -> some View {
        if enabled {
            scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }

    @ViewBuilder
    func applyCurrentEpisodeDefaultFocus(
        _ contentId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let contentId {
            defaultFocus(binding, contentId, priority: .userInitiated)
        } else {
            self
        }
    }
}

struct TVEpisodeCard: View {
    let episode: EpisodeListItem
    var isCurrent: Bool = false
    var usesNativeShelf = false
    var baseCardWidth: CGFloat = 480
    var posterSize: CardPosterSize = .standard
    var captionStyle: CardCaptionStyle = .titleMetadata
    let onSelect: () -> Void
    var onPlay: ((String) -> Void)? = nil
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)? = nil
    var initialIsFavorite = false
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)? = nil

    @FocusState private var isFocused: Bool
    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?

    private var cardWidth: CGFloat { baseCardWidth * posterSize.scale }
    private var stillHeight: CGFloat { cardWidth * 9 / 16 }
    private let stillCornerRadius: CGFloat = 18

    var body: some View {
        let button = cardButton
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)

        Group {
            if onPlay != nil || onSetWatched != nil || onSetFavorite != nil {
                button.contextMenu { contextActions }
            } else {
                button
            }
        }
        .onChange(of: episode.userData?.played) { _, refreshedValue in
            guard let playedOverride, refreshedValue == playedOverride else { return }
            self.playedOverride = nil
        }
        .onChange(of: initialIsFavorite) { _, refreshedValue in
            guard let favoriteOverride, refreshedValue == favoriteOverride else { return }
            self.favoriteOverride = nil
        }
    }

    @ViewBuilder
    private var cardButton: some View {
        if usesNativeShelf {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: onSelect) {
                    CachedAsyncImage(url: episode.stillUrl ?? "", targetSize: CGSize(width: cardWidth, height: stillHeight), contentMode: .fill)
                        .frame(width: cardWidth, height: stillHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(alignment: .bottomLeading) {
                                    HStack(spacing: 6) {
                                        if isPlayed { Image(systemName: "checkmark.circle.fill") }
                                        if let runtime = episode.runtime, runtime > 0 { Text("\(runtime)m") }
                                    }
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: true, vertical: true)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.black.opacity(0.45), in: Capsule())
                                    .padding(12)
                                    .opacity(nativeResumeProgress == nil ? 1 : 0)
                                }
                        .overlay(alignment: .bottomLeading) {
                            if let progress = nativeResumeProgress {
                                HStack(spacing: 12) {
                                    HStack(spacing: 6) {
                                        if isPlayed { Image(systemName: "checkmark.circle.fill") }
                                        if let runtime = episode.runtime, runtime > 0 { Text("\(runtime)m") }
                                    }
                                    .font(.system(size: 18)).foregroundStyle(.white)
                                    .fixedSize().padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.black.opacity(0.45), in: Capsule())
                                    ResumeProgressBar(value: progress.fraction,
                                                      duration: episode.userData?.durationSeconds, height: 8, inset: 0)
                                }
                                    .padding(.horizontal, 12).padding(.bottom, 12)
                                    .frame(width: cardWidth, height: stillHeight, alignment: .bottom)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .buttonStyle(.card)
                .focused($isFocused)
                VStack(alignment: .leading, spacing: 6) {
                    Text("EPISODE \(episode.episodeNumber)").font(.system(size: 18)).foregroundStyle(.secondary)
                    Text(episode.title ?? "Episode \(episode.episodeNumber)").font(.system(size: 24, weight: .semibold)).lineLimit(1)
                    Text(episode.overview ?? "").font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(2)
                        .frame(height: 52, alignment: .topLeading)
                    Text(DetailDateFormatting.abbreviatedDate(episode.airDate) ?? "")
                        .font(.system(size: 18)).foregroundStyle(.secondary)
                }.frame(width: cardWidth, alignment: .leading)
            }
        } else {
            Button(action: onSelect) {
                EpisodeCardLabel(episode: episode, isPlayed: isPlayed, isCurrent: isCurrent,
                                 cardWidth: cardWidth, stillHeight: stillHeight,
                                 stillCornerRadius: stillCornerRadius, captionStyle: captionStyle)
            }.buttonStyle(.card)
        }
    }

    private var nativeResumeProgress: ResumePresentation? {
        guard playedOverride == nil else { return nil }
        return ResumePresentation(position: episode.userData?.positionSeconds,
                           duration: episode.userData?.durationSeconds)
    }

    private var isPlayed: Bool {
        playedOverride ?? episode.userData?.played ?? false
    }

    private var isFavorite: Bool {
        favoriteOverride ?? initialIsFavorite
    }

    private var accessibilityDescription: String {
        episodeRailAccessibilityLabel(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title,
            metadata: episodeMetadataLine,
            isCurrent: isCurrent,
            isPlayed: isPlayed
        )
    }

    private var episodeMetadataLine: String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = episode.runtime, runtime > 0 {
            if runtime >= 60 {
                parts.append("\(runtime / 60)h \(runtime % 60)m")
            } else {
                parts.append("\(runtime)m")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var contextActions: some View {
        if let onPlay {
            Button {
                onPlay(episode.contentId)
            } label: {
                Label("Play S\(episode.seasonNumber):E\(episode.episodeNumber)", systemImage: "play.fill")
            }
        }

        if let onSetWatched {
            Button {
                let played = !isPlayed
                playedOverride = played
                Task {
                    if await onSetWatched(episode.contentId, played) == false {
                        playedOverride = nil
                    }
                }
            } label: {
                Label(
                    isPlayed ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: isPlayed ? "circle" : "checkmark.circle"
                )
            }
        }

        if let onSetFavorite {
            Button {
                let newValue = !isFavorite
                favoriteOverride = newValue
                Task {
                    if await onSetFavorite(episode.contentId, newValue) == false {
                        favoriteOverride = nil
                    }
                }
            } label: {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
        }
    }
}

private struct EpisodeCardLabel: View {
    let episode: EpisodeListItem
    let isPlayed: Bool
    let isCurrent: Bool
    let cardWidth: CGFloat
    let stillHeight: CGFloat
    let stillCornerRadius: CGFloat
    let captionStyle: CardCaptionStyle
    var focusOverride: Bool? = nil
    var hidesEpisodeTitle = false
    var showsCurrentOutline = true

    @Environment(\.isFocused) private var environmentIsFocused

    private var isFocused: Bool {
        focusOverride ?? environmentIsFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            still
            if captionStyle.showsTitle {
                VStack(alignment: .leading, spacing: 7) {
                    if hidesEpisodeTitle, let compactEpisodeTitle {
                        // Keep the compact Series caption inside the moving
                        // control without animating its layout independently.
                        Text(compactEpisodeTitle)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: cardWidth, height: 28, alignment: .topLeading)
                            .clipped()
                            .transaction { transaction in
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                    }

                    if !hidesEpisodeTitle {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(episode.title ?? "Episode \(episode.episodeNumber)")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(titleColor)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if captionStyle.showsMetadata,
                               let runtime = episode.runtime,
                               runtime > 0 {
                                Text(formatRuntime(runtime))
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Color.vividSecondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var titleColor: Color {
        if isCurrent { return .vividOnSurface }
        return isFocused ? .vividOnSurface : Color.vividOnSurface.opacity(0.92)
    }

    /// "S01E02 · Pilot" — the same code Home puts on episode cards, so the
    /// Series carousel makes each episode's position obvious at a glance.
    private var compactEpisodeTitle: String? {
        let code = EpisodeCardCaption.code(
            season: episode.seasonNumber,
            episode: episode.episodeNumber
        )
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return code }
        return "\(code) · \(title)"
    }

    private var episodeMetadataLine: String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append(formatRuntime(runtime))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var still: some View {
        ZStack(alignment: .bottom) {
            Color.vividSurfaceElevated
                .frame(width: cardWidth, height: stillHeight)

            if let url = episode.stillUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: cardWidth, height: stillHeight),
                    thumbhash: episode.stillThumbhash,
                    contentMode: .fill
                )
                .frame(width: cardWidth, height: stillHeight)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 48))
                    .foregroundColor(.vividSecondaryText)
                    .frame(width: cardWidth, height: stillHeight)
            }

            if isPlayed {
                Color.black.opacity(0.35)
                    .frame(width: cardWidth, height: stillHeight)
            }

            if isPlayed {
                VStack {
                    HStack {
                        Spacer()
                        watchedBadge.padding(10)
                    }
                    Spacer()
                }
                .frame(width: cardWidth, height: stillHeight)
            }

            if let progress = progressFraction {
                ResumeProgressBar(value: progress, duration: episode.userData?.durationSeconds)
            }
        }
        .frame(width: cardWidth, height: stillHeight)
        .clipShape(RoundedRectangle(cornerRadius: stillCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: stillCornerRadius)
                .stroke(
                    Color.white.opacity(showsCurrentOutline && isCurrent && !isFocused ? 0.7 : 0),
                    lineWidth: showsCurrentOutline && isCurrent && !isFocused ? 2 : 0
                )
        )

    }

    private var watchedBadge: some View {
        TVWatchedBadge()
    }



    private var progressFraction: Double? {
        guard let userData = episode.userData,
              let pos = userData.positionSeconds,
              let dur = userData.durationSeconds,
              dur > 0, pos > 0, pos < dur
        else { return nil }
        return pos / dur
    }

    private func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

/// Reserves the approved 480-point episode-card geometry while an uncached
/// season loads. Keeping artwork and caption blocks in the tree prevents the
/// lower detail sections from jumping when real episodes arrive.
struct TVEpisodeRailPlaceholder: View {
    var cardWidth: CGFloat = 480
    var cardHeightRatio: CGFloat = 9 / 16
    var cardSpacing: CGFloat = 54
    var hidesEpisodeTitle = false
    private var stillHeight: CGFloat { cardWidth * cardHeightRatio }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: cardSpacing) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 18) {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.vividSurfaceElevated)
                            .frame(width: cardWidth, height: stillHeight)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 112, height: 15)
                        if !hidesEpisodeTitle {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.28))
                                .frame(width: 310, height: 22)
                        }
                    }
                    .frame(width: cardWidth, alignment: .leading)
                }
            }
            .padding(.vertical, 12)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityHidden(true)
    }
}


/// One native shelf across seasons. Season buttons jump inside the same scroll view.
struct TVContinuousEpisodeShelf: View {
    let seasons: [Season]
    let pages: [Int: [EpisodeListItem]]
    let selectedSeason: Season?
    let currentContentId: String?
    var heroEntryEpisode: EpisodeListItem? = nil
    let favorites: [String: Bool]
    let onSeason: (Season) -> Void
    let onFocus: (EpisodeListItem) -> Void
    let onPlay: (EpisodeListItem) -> Void
    let onWatched: (String, Bool) async -> Bool
    let onFavorite: (String, Bool) async -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedEpisode: String?
    @FocusState private var focusedSeason: String?
    @Namespace private var seasonFocusNamespace
    @State private var highlightedSeason: String?
    @State private var scrollHighlightedSeason: String?
    @State private var pendingJump: String?
    @State private var pendingEpisodeJump: String?
    @State private var seeded = false

    private func items(_ season: Season) -> [EpisodeListItem]? { pages[season.seasonNumber] }
    private var contentKey: [String] { seasons.flatMap { items($0)?.map(\.contentId) ?? [] } }

    private var visibleSeasonID: String? {
        focusedSeason ?? scrollHighlightedSeason ?? highlightedSeason ?? selectedSeason?.id
    }

    private func seasonAtVisiblePosition(_ visibleRect: CGRect) -> String? {
        var firstIndex = 0
        var visibleSeason: String?
        let leadingCardCentre = max(0, visibleRect.minX) + 200
        for season in seasons {
            let episodes = items(season)
            let count = episodes?.count ?? 1
            if let focusedEpisode,
               let index = episodes?.firstIndex(where: { $0.contentId == focusedEpisode }) {
                let centre = CGFloat(firstIndex + index) * 440 + 200
                if centre >= visibleRect.minX && centre <= visibleRect.maxX {
                    return season.id
                }
            }
            if count > 0, leadingCardCentre >= CGFloat(firstIndex) * 440 {
                visibleSeason = season.id
            }
            firstIndex += count
        }
        return visibleSeason
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 24) {
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(seasons) { season in
                            Button {
                                selectSeason(season, using: proxy)
                            } label: {
                                Text(season.seasonNumber == 0 ? "Specials" : "Season \(season.seasonNumber)")
                                    .font(.system(size: 22, weight: .semibold))
                                    .fixedSize()
                            }
                            .buttonStyle(TVContinuousSeasonButtonStyle(
                                isFocused: focusedSeason == season.id,
                                isSelected: visibleSeasonID == season.id))
                            .focusEffectDisabled()
                            .focused($focusedSeason, equals: season.id)
                            .modifier(SeasonWatchedContextMenu(season: season))
                        }
                    }
                }.scrollClipDisabled().focusSection()
                .focusScope(seasonFocusNamespace)
                .defaultFocus($focusedSeason, highlightedSeason ?? selectedSeason?.id,
                              priority: focusedSeason == nil ? .userInitiated : .automatic)
                .onChange(of: focusedSeason) { _, id in
                    scrollHighlightedSeason = nil
                    if let id, id != (highlightedSeason ?? selectedSeason?.id) {
                        pendingJump = nil
                    }
                }
                .task(id: focusedSeason) { @MainActor in
                    guard let id = focusedSeason,
                          id != (highlightedSeason ?? selectedSeason?.id) else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(120))
                    } catch { return }
                    guard !Task.isCancelled, focusedSeason == id,
                          id != (highlightedSeason ?? selectedSeason?.id),
                          let season = seasons.first(where: { $0.id == id }) else { return }
                    selectSeason(season, using: proxy)
                }

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(seasons) { season in
                            if let episodes = items(season) {
                                ForEach(episodes) { episode in
                                    TVEpisodeCard(episode: episode, isCurrent: currentContentId == episode.contentId,
                                        usesNativeShelf: true, baseCardWidth: 400,
                                        onSelect: { onPlay(episode) }, onPlay: { _ in onPlay(episode) },
                                        onSetWatched: onWatched, initialIsFavorite: favorites[episode.contentId] ?? false,
                                        onSetFavorite: onFavorite)
                                        .id(episode.contentId)
                                        .focused($focusedEpisode, equals: episode.contentId)

                                }
                            } else {
                                Button("Load Season \(season.seasonNumber)") {
                                    pendingJump = season.id
                                    onSeason(season)
                                }.frame(width: 400, height: 225)
                            }
                        }
                    }.padding(.vertical, 20)
                }
                .scrollClipDisabled().focusSection()
                .onScrollGeometryChange(for: String?.self) { geometry in
                    seasonAtVisiblePosition(geometry.visibleRect)
                } action: { _, seasonID in
                    // Accelerated remote scrolling can move the rail before
                    // native episode focus catches up. This only paints selection.
                    guard heroEntryEpisode == nil, focusedSeason == nil, let seasonID else { return }
                    scrollHighlightedSeason = seasonID
                }
                .onChange(of: focusedEpisode) { _, id in
                    guard let id,
                          let season = seasons.first(where: { items($0)?.contains { $0.contentId == id } == true }),
                          let episode = items(season)?.first(where: { $0.contentId == id }) else { return }
                    pendingJump = nil
                    scrollHighlightedSeason = nil
                    highlightedSeason = season.id
                    if selectedSeason?.id != season.id { onSeason(season) }
                    onFocus(episode)
                }
            }
            .onPlayPauseCommand {
                guard let id = focusedEpisode,
                      let episode = pages.values.lazy.flatMap({ $0 }).first(where: { $0.contentId == id }) else { return }
                onPlay(episode)
            }
            .onChange(of: heroEntryEpisode?.contentId, initial: true) { _, id in
                guard let id, let episode = heroEntryEpisode,
                      let season = seasons.first(where: { $0.seasonNumber == episode.seasonNumber }) else { return }
                // Prepare the destination while focus is still in the hero.
                // Native focus continues to own the downward transition.
                scrollHighlightedSeason = nil
                highlightedSeason = season.id
                pendingJump = season.id
                pendingEpisodeJump = id
                if selectedSeason?.id != season.id { onSeason(season) }
                jumpIfReady(proxy)
            }
            .onChange(of: contentKey, initial: true) { _, _ in
                if !seeded, pendingJump == nil, let season = selectedSeason, items(season) != nil {
                    seeded = true
                    if let id = currentContentId ?? items(season)?.first?.contentId {
                        proxy.scrollTo(id, anchor: .leading)
                    }
                }
                jumpIfReady(proxy)
            }
        }
    }

    private func selectSeason(_ season: Season, using proxy: ScrollViewProxy) {
        highlightedSeason = season.id
        pendingEpisodeJump = nil
        pendingJump = season.id
        if selectedSeason?.id != season.id { onSeason(season) }
        jumpIfReady(proxy)
    }

    private func jumpIfReady(_ proxy: ScrollViewProxy) {
        guard let pendingJump, let season = seasons.first(where: { $0.id == pendingJump }),
              let episodes = items(season),
              let id = pendingEpisodeJump.flatMap({ target in episodes.first { $0.contentId == target }?.contentId })
                ?? episodes.first?.contentId else { return }
        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .leading) }
        seeded = true
        self.pendingJump = nil
        pendingEpisodeJump = nil
    }
}

private struct TVContinuousSeasonButtonStyle: ButtonStyle {
    let isFocused: Bool
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isFocused ? Color.white : Color.white.opacity(isSelected ? 0.36 : 0.10), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
    }
}

#endif
