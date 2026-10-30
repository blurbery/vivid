#if os(iOS)
import SwiftUI

/// One server row on iPhone and iPad Home: a title over a horizontal rail
/// of posters, or of landscape stills for Continue Watching and Next Up.
struct HomeFeedRow: View {
    let section: ResolvedSection
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)?
    var onSetWatched: ((SectionItem, Bool) async -> Bool)?

    @State private var homeCards = TVHomeCardPreferences.shared
    @State private var scrolledItemID: String?

    init(
        section: ResolvedSection,
        onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil,
        onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil
    ) {
        self.section = section
        self.onRemoveFromContinueWatching = onRemoveFromContinueWatching
        self.onSetWatched = onSetWatched
    }

    private var isResumeRow: Bool { HomeFeedMeta.isResumeRow(section) }

    private var isNextRow: Bool { section.sectionType.lowercased().contains("next") }

    private var usesStills: Bool {
        isResumeRow || (isNextRow && section.items.contains { $0.type.lowercased() == "episode" })
    }

    private var usesSeriesBackdrops: Bool {
        usesStills && HomeSeriesBackdrops.applies(toSectionType: section.sectionType)
    }

    private var itemIDs: [String] { section.items.map(\.contentId) }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
            HomeSectionHeader(title: section.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: HomeFeedMetrics.cardSpacing) {
                    ForEach(section.items, id: \.contentId) { item in
                        card(item)
                    }
                }
                .scrollTargetLayout()
                .phoneMediaRailBounds()
            }
            .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
            .scrollClipDisabled()
            .scrollTargetBehavior(HorizontalMediaRailLayout.targetBehavior)
            .scrollPosition(id: $scrolledItemID, anchor: HorizontalMediaRailLayout.scrollAnchor)
            .environment(\.itemDetailBrowseSource, ItemDetailBrowseSource(originID: "home:\(section.id)", contentIDs: itemIDs))
        }
        .onAppear {
            let ids = itemIDs
            if !(scrolledItemID.map { ids.contains($0) } ?? false) {
                scrolledItemID = ids.first
            }
        }
        .onChange(of: itemIDs) { _, ids in
            if !(scrolledItemID.map { ids.contains($0) } ?? false) {
                scrolledItemID = ids.first
            }
        }
        .task(id: itemIDs) {
            guard usesSeriesBackdrops else { return }
            await HomeSeriesBackdrops.shared.keepPrepared(section.items)
        }
    }

    @ViewBuilder
    private func card(_ item: SectionItem) -> some View {
        let presentation = homeCards.presentation
        let scale = presentation.posterSize.scale
        let nativeNextRow = MediaServerProvider.active.usesNativeUser && isNextRow
        let removal: (() -> Void)? = isResumeRow ? onRemoveFromContinueWatching.map { remove in { remove(item) } } : nil
        let watched: ((Bool) async -> Bool)? = onSetWatched.map { update in { played in await update(item, played) } }
        if usesStills {
            HomeStillCard(
                item: item,
                width: HomeFeedMetrics.stillWidth * scale,
                showsCaption: presentation.caption.showsTitle,
                showsMetadata: presentation.caption.showsMetadata,
                showsEpisodeDetails: nativeNextRow,
                opensResumeContext: isResumeRow || nativeNextRow,
                usesSeriesBackdrop: usesSeriesBackdrops,
                onRemoveFromContinueWatching: removal,
                onSetWatched: watched
            )
        } else {
            HomePosterCard(
                item: item,
                width: HomeFeedMetrics.posterWidth * scale,
                showsCaption: presentation.caption.showsTitle,
                showsMetadata: presentation.caption.showsMetadata,
                showsProgress: isResumeRow,
                opensResumeContext: isResumeRow || nativeNextRow,
                episodeAccessibilityLabel: EpisodeCardCaption.accessibilityLabel(for: item),
                onRemove: removal,
                onSetWatched: watched
            )
        }
    }
}

// MARK: - Still card

/// A landscape still with the series title and episode line below, used on
/// Continue Watching and Next Up.
struct HomeStillCard: View {
    let item: SectionItem
    var width: CGFloat
    var showsCaption: Bool
    var showsMetadata: Bool
    var showsEpisodeDetails: Bool
    var opensResumeContext: Bool
    var usesSeriesBackdrop: Bool
    var onRemoveFromContinueWatching: (() -> Void)?
    var onSetWatched: ((Bool) async -> Bool)?

    @State private var playedOverride: Bool?
    @Environment(AppRouter.self) private var router

    init(
        item: SectionItem,
        width: CGFloat = HomeFeedMetrics.stillWidth,
        showsCaption: Bool = true,
        showsMetadata: Bool = true,
        showsEpisodeDetails: Bool = false,
        opensResumeContext: Bool = false,
        usesSeriesBackdrop: Bool = false,
        onRemoveFromContinueWatching: (() -> Void)? = nil,
        onSetWatched: ((Bool) async -> Bool)? = nil
    ) {
        self.item = item
        self.width = width
        self.showsCaption = showsCaption
        self.showsMetadata = showsMetadata
        self.showsEpisodeDetails = showsEpisodeDetails
        self.opensResumeContext = opensResumeContext
        self.usesSeriesBackdrop = usesSeriesBackdrop
        self.onRemoveFromContinueWatching = onRemoveFromContinueWatching
        self.onSetWatched = onSetWatched
    }

    private var height: CGFloat { (width * 9 / 16).rounded() }
    private var isResumeCard: Bool { onRemoveFromContinueWatching != nil }
    private var isPlayed: Bool { playedOverride ?? (item.userState?.played == true) }
    private var progress: Double? { HomeFeedMeta.progress(of: item) }
    private var resumeCaption: String? { HomeFeedMeta.resumeCaption(for: item) }
    private var isDirectlyPlayable: Bool { VividMediaType.isDirectlyPlayable(item.type) }

    private var showsRuntimeStatus: Bool {
        MediaRuntimeStatusOverlay.applies(toType: item.type, inContinueWatching: isResumeCard)
    }

    private var playActionName: LocalizedStringKey {
        (item.positionSeconds ?? 0) > 0 ? "Resume" : "Play"
    }

    private var secondLine: String? {
        guard isResumeCard || showsEpisodeDetails, EpisodeCardCaption.isEpisode(item) else {
            return HomeFeedMeta.secondLine(for: item)
        }
        var code: [String] = []
        if let season = item.seasonNumber {
            code.append(String(localized: "S\(String(season))", comment: "Season number in an episode code, e.g. S1"))
        }
        if let episode = item.episodeNumber {
            code.append(String(localized: "E\(String(episode))", comment: "Episode number in an episode code, e.g. E2"))
        }
        let codeText = code.joined(separator: " ")
        let parts = [codeText.isEmpty ? nil : codeText, EpisodeCardCaption.episodeTitle(for: item)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{2013} ")
    }

    private var artwork: (url: String, thumbhash: String?) {
        if usesSeriesBackdrop {
            return HomeSeriesBackdrops.shared.art(for: item)
        }
        if let backdrop = item.backdropUrl, !backdrop.isEmpty {
            return (backdrop, item.backdropThumbhash)
        }
        return (item.posterUrl ?? "", item.posterThumbhash)
    }

    private var accessibilityText: String {
        var parts = [HomeFeedMeta.title(for: item)]
        if let episode = EpisodeCardCaption.accessibilityLabel(for: item) {
            parts.append(episode)
        } else if let year = item.year {
            parts.append(String(year))
        }
        if let resumeCaption {
            parts.append(resumeCaption)
        }
        if isPlayed {
            parts.append(String(localized: "Watched"))
        }
        if showsRuntimeStatus,
           let minutes = MediaRuntimeStatusOverlay.displayedRuntime(minutes: item.runtime, duration: item.durationSeconds) {
            parts.append(String(localized: "\(minutes) minutes", comment: "Spoken runtime"))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HomeCardButton(item: item, opensResumeContext: opensResumeContext) {
            VStack(alignment: .leading, spacing: 8) {
                artworkView
                if showsCaption || isResumeCard || showsEpisodeDetails {
                    caption
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityActions {
            if isDirectlyPlayable {
                Button(playActionName, action: play)
            }
        }
        .modifier(HomeCardMenu(
            item: item,
            playedOverride: $playedOverride,
            onSetWatched: onSetWatched,
            onRemove: onRemoveFromContinueWatching
        ))
    }

    private func play() {
        router.presentPlayer(
            contentId: item.contentId,
            resumePosition: item.positionSeconds,
            prefersLastUsedVersion: opensResumeContext,
            posterURL: item.posterUrl,
            backdropURL: item.backdropUrl
        )
    }

    private var artworkView: some View {
        let art = artwork
        let shape = RoundedRectangle(cornerRadius: HomeFeedMetrics.stillRadius, style: .continuous)
        return ZStack(alignment: .bottom) {
            AsyncImageView(
                url: art.url,
                thumbhash: art.thumbhash,
                targetSize: CGSize(width: width, height: height),
                contentMode: .fill
            )
            .frame(width: width, height: height)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .frame(height: height * 0.6)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            if showsRuntimeStatus {
                MediaRuntimeStatusOverlay(
                    isPlayed: isPlayed,
                    duration: item.durationSeconds,
                    progress: progress,
                    runtimeMinutes: item.runtime
                )
            } else if let progress {
                if isResumeCard {
                    ResumeProgressBar(value: progress, duration: item.durationSeconds)
                } else {
                    ResumeProgressBar(value: progress, duration: item.durationSeconds, height: 3, inset: 8)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .overlay { playBadge }
        .overlay(alignment: .topTrailing) {
            if isPlayed, !showsRuntimeStatus {
                HomeWatchedTick()
                    .padding(6)
            }
        }
        .overlay {
            DownloadedBadgeOverlay(contentId: item.contentId, padding: 6)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var playBadge: some View {
        let badge = Image(systemName: "play.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.black.opacity(0.32)))
            .overlay(Circle().stroke(Color.white.opacity(0.38), lineWidth: 0.75))
            .contentShape(Circle())
        if isDirectlyPlayable {
            Button(action: play) { badge }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(playActionName))
        } else {
            badge.allowsHitTesting(false)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: HomeFeedMeta.title(for: item))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.vividOnSurface)
                .lineLimit(1)
            if showsMetadata || isResumeCard || showsEpisodeDetails {
                Text(verbatim: secondLine ?? "")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.vividOnSurface.opacity(0.7))
                    .monospacedDigit()
                    .lineLimit(1, reservesSpace: true)
                    .truncationMode(.tail)
            }
            if showsMetadata, !isResumeCard,
               (opensResumeContext && HorizontalMediaRailLayout.isPhone) || resumeCaption != nil {
                // Without a caption the line is kept, invisible, so the
                // cards of a row line up.
                Text(verbatim: resumeCaption ?? "0m left")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.vividOnSurface.opacity(0.55))
                    .lineLimit(1)
                    .opacity(resumeCaption == nil ? 0 : 1)
                    .accessibilityHidden(resumeCaption == nil)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Poster card

private struct HomePosterCard: View {
    let item: SectionItem
    let width: CGFloat
    let showsCaption: Bool
    let showsMetadata: Bool
    let showsProgress: Bool
    let opensResumeContext: Bool
    let episodeAccessibilityLabel: String?
    let onRemove: (() -> Void)?
    let onSetWatched: ((Bool) async -> Bool)?

    @State private var playedOverride: Bool?

    private var height: CGFloat { (width * HomeFeedMetrics.posterAspect).rounded() }
    private var isPlayed: Bool { playedOverride ?? (item.userState?.played == true) }

    private var accessibilityText: String {
        var parts = [HomeFeedMeta.title(for: item)]
        if let episodeAccessibilityLabel {
            parts.append(episodeAccessibilityLabel)
        } else if let year = item.year {
            parts.append(String(year))
        }
        if isPlayed {
            parts.append(String(localized: "Watched"))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HomeCardButton(item: item, opensResumeContext: opensResumeContext) {
            VStack(alignment: .leading, spacing: 7) {
                artwork
                if showsCaption {
                    caption
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .modifier(HomeCardMenu(
            item: item,
            playedOverride: $playedOverride,
            onSetWatched: onSetWatched,
            onRemove: onRemove
        ))
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: HomeFeedMetrics.posterRadius, style: .continuous)
        return AsyncImageView(
            url: item.posterUrl ?? "",
            thumbhash: item.posterThumbhash,
            targetSize: CGSize(width: width, height: height),
            contentMode: .fill
        )
        .frame(width: width, height: height)
        .clipped()
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if isPlayed {
                WatchedCheckPill()
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if showsProgress, let progress = HomeFeedMeta.progress(of: item) {
                ResumeProgressBar(value: progress, duration: item.durationSeconds, height: 3, inset: 6)
            }
        }
        .overlay {
            DownloadedBadgeOverlay(contentId: item.contentId, padding: 6)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: HomeFeedMeta.title(for: item))
                .homePosterTitleStyle()
            if showsMetadata, let line = HomeFeedMeta.secondLine(for: item) {
                Text(verbatim: line)
                    .homePosterSecondLineStyle()
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Shared card parts

/// The green tick on a watched still.
private struct HomeWatchedTick: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color(red: 0.16, green: 0.62, blue: 0.34)))
    }
}

/// Opens item detail from a Home card, zooming from the card's artwork.
private struct HomeCardButton<Label: View>: View {
    let item: SectionItem
    let opensResumeContext: Bool
    @ViewBuilder let label: () -> Label

    /// One per card, so the same title in two rows zooms from the right one.
    @State private var zoomSourceID = UUID().uuidString
    @Environment(AppRouter.self) private var router
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(\.itemDetailBrowseSource) private var browseSource

    var body: some View {
        Button {
            router.pendingZoomSourceID = zoomSourceID
            if opensResumeContext {
                router.presentContinueWatchingDetail(for: item, browseSource: browseSource)
            } else {
                router.presentItemDetail(contentId: item.contentId, browseSource: browseSource)
            }
        } label: {
            label()
                .zoomTransitionSource(id: zoomSourceID, in: zoomNamespace)
        }
        .buttonStyle(.plain)
    }
}

/// The long-press menu on a Home card: watched, favourite and watchlist,
/// and removal from Continue Watching. Left off when it would be empty.
private struct HomeCardMenu: ViewModifier {
    let item: SectionItem
    @Binding var playedOverride: Bool?
    let onSetWatched: ((Bool) async -> Bool)?
    let onRemove: (() -> Void)?

    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?

    private var isPlayed: Bool { playedOverride ?? (item.userState?.played == true) }
    private var isFavorite: Bool { favoriteOverride ?? (item.userState?.isFavorite == true) }
    private var inWatchlist: Bool { watchlistOverride ?? (item.userState?.inWatchlist == true) }

    private var removesFromContinueWatching: Bool {
        onRemove != nil && MediaServerProvider.active.supportsContinueWatchingRemoval
    }

    private var hasActions: Bool {
        onSetWatched != nil || item.userState != nil || removesFromContinueWatching
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if hasActions {
            content
                .contextMenu { menuItems }
                .onChange(of: item.userState) {
                    playedOverride = nil
                    favoriteOverride = nil
                    watchlistOverride = nil
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let onSetWatched {
            Button {
                let played = !isPlayed
                Task { @MainActor in
                    playedOverride = played
                    if !(await onSetWatched(played)) {
                        playedOverride = nil
                    }
                }
            } label: {
                if isPlayed {
                    Label("Mark as Unwatched", systemImage: "circle")
                } else {
                    Label("Mark as Watched", systemImage: "checkmark.circle")
                }
            }
        }
        if item.userState != nil {
            PersonalListMenuItems(
                isFavorite: isFavorite,
                inWatchlist: inWatchlist,
                onToggleFavorite: toggleFavorite,
                onToggleWatchlist: toggleWatchlist
            )
        }
        if let onRemove, removesFromContinueWatching {
            Button(role: .destructive, action: onRemove) {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }

    private func toggleFavorite() {
        let previous = isFavorite
        let favorite = !previous
        let watchlist = inWatchlist
        favoriteOverride = favorite
        Task { @MainActor in
            let saved = await PersonalListSync.setFavorite(
                contentId: item.contentId, isFavorite: favorite, inWatchlist: watchlist
            )
            if !saved { favoriteOverride = previous }
        }
    }

    private func toggleWatchlist() {
        let previous = inWatchlist
        let watchlist = !previous
        let favorite = isFavorite
        watchlistOverride = watchlist
        Task { @MainActor in
            let saved = await PersonalListSync.setWatchlist(
                contentId: item.contentId, isFavorite: favorite, inWatchlist: watchlist
            )
            if !saved { watchlistOverride = previous }
        }
    }
}
#endif
