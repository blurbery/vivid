#if os(tvOS)
import os
import SwiftUI
import UIKit

/// The Apple TV detail page for one content id. It keeps the title's view
/// model and the Play target state while it stays in the stack, and shows
/// the movie, series or season page for the loaded type. Episodes open
/// their series instead.
struct TVItemDetailView: View {
    let contentId: String
    let seed: TVItemDetailRouteSeed?

    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: ItemDetailViewModel
    @State private var nextUp = TVDetailNextUp()
    /// The series page's Play target, pinned apart from browsing.
    @State private var activeEpisodeId: String?
    @State private var pendingCompletion: TVPlaybackStateRefreshEvent?
    @State private var pendingContext: TVSeriesDetailNavigationContextStore.Context?
    @State private var hasLoadedOnce = false
    @State private var parentSeries: ItemDetail?
    @State private var failedRedirectId: String?
    @State private var seasonSelectionTask: Task<Void, Never>?
    @State private var selectionGeneration = 0
    @State private var allowsRemoteTrailers = false
    @State private var tmdbVideos: [ItemVideo] = []
    @State private var tmdbVideosContext: String?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app", category: "TVFocus")

    init(contentId: String, seed: TVItemDetailRouteSeed? = nil) {
        self.contentId = contentId
        self.seed = seed
        // Looked up on every construction so the cached model is refreshed
        // from the response cache and the first frame paints it.
        _viewModel = State(initialValue: ItemDetailCache.shared.viewModel(for: contentId))
    }

    var body: some View {
        content
            .environment(\.seasonWatchedAction, { [viewModel] id, played in
                await viewModel.setSeasonWatched(contentId: id, played: played)
            })
            .task(id: tmdbVideosKey) {
                await loadTMDbVideos()
            }
            .toolbar(.hidden, for: .navigationBar)
            .vividBackground()
            .vividNavigationTitleDisplayMode(.inline)
            .task(id: contentId) {
                await load()
            }
            .onAppear {
                Self.log.debug("itemDetail.appear contentId=\(contentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
                probeRemoteTrailers()
            }
            .onDisappear {
                seasonSelectionTask?.cancel()
                Self.log.debug("itemDetail.disappear contentId=\(contentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
                viewModel.cancelDeferredEpisodeFavoriteStateRefresh()
                // A page that pops proves the YouTube hand-off didn't take over.
                TVTrailerReturnStore.shared.clear()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                probeRemoteTrailers()
                TVTrailerReturnStore.shared.clear()
            }
            .onReceive(NotificationCenter.default.publisher(for: .tvPlaybackStateDidRefresh)) { notification in
                guard let event = notification.object as? TVPlaybackStateRefreshEvent else { return }
                applyCompletedPlayback(event)
            }
            .onChange(of: viewModel.episodesBySeason.keys.sorted()) { _, _ in
                guard let pendingCompletion else { return }
                applyCompletedPlayback(pendingCompletion)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let detail = viewModel.detail {
            page(for: detail)
        } else if let error = viewModel.error {
            ErrorView(state: error) {
                Task { await viewModel.loadDetail(contentId: contentId) }
            }
        } else {
            TVDetailLoadingPage(seed: seed)
        }
    }

    @ViewBuilder
    private func page(for detail: ItemDetail) -> some View {
        if detail.type == "season" {
            seasonPage(detail)
        } else if let redirect = redirectTarget(for: detail) {
            Color.clear
                .task(id: redirect) {
                    await runRedirect(redirect)
                }
        } else if detail.type == "series" {
            seriesPage(detail)
        } else {
            moviePage(detail)
        }
    }

    // MARK: - Pages

    private var pageActions: TVDetailPageActions {
        TVDetailPageActions(
            selectPerson: { personId in
                guard let id = Int(personId) else { return }
                router.navigate(to: .personDetail(personId: id))
            },
            selectItem: { id in
                router.navigate(to: .itemDetail(contentId: id))
            },
            toggleFavorite: { Task { await viewModel.toggleFavorite() } },
            toggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
            toggleWatched: { Task { await viewModel.toggleWatched() } },
            setEpisodeWatched: { [viewModel] id, played in
                await viewModel.setEpisodeWatched(contentId: id, played: played)
            },
            setEpisodeFavorite: { [viewModel] id, favorite in
                await viewModel.setEpisodeFavorite(contentId: id, isFavorite: favorite)
            },
            selectTrailer: { selectTrailer($0) }
        )
    }

    private var nextUpPicks: TVDetailNextUpPicks {
        TVDetailNextUpPicks(
            fileId: viewModel.preferredNextUpFileId,
            audio: viewModel.preferredNextUpAudioTrackIndex,
            subtitle: viewModel.preferredNextUpSubtitleTrackIndex,
            pickVersion: { pickNextUpVersion($0) },
            pickAudio: { pickNextUpAudio($0) },
            pickSubtitle: { pickNextUpSubtitle($0) }
        )
    }

    private func moviePage(_ detail: ItemDetail) -> some View {
        TVMovieDetailPage(
            viewModel: viewModel,
            detail: detail,
            contentId: contentId,
            supportingDetail: supportingDetail(for: detail),
            trailerEntries: trailerEntries,
            actions: pageActions,
            play: { playMovie(fromBeginning: $0) },
            pickVersion: { pickMovieVersion($0) },
            pickAudio: { pickMovieAudio($0) },
            pickSubtitle: { pickMovieSubtitle($0) },
            selectEpisode: { id in
                guard id != contentId else { return }
                router.replaceCurrent(with: .itemDetail(contentId: id))
            },
            playEpisodeShortcut: { presentEpisodeShortcut($0) }
        )
        .task(id: detail.type == "episode" ? detail.seriesId : nil) {
            await loadParentSeries(for: detail)
        }
    }

    private func seriesPage(_ detail: ItemDetail) -> some View {
        let target = seriesPlayTarget
        return TVSeriesDetailPage(
            viewModel: viewModel,
            detail: detail,
            contentId: contentId,
            playTarget: target,
            activeEpisodeId: activeEpisodeId,
            nextUp: nextUp,
            picks: nextUpPicks,
            trailerEntries: trailerEntries,
            actions: pageActions,
            selectSeason: { selectSeriesSeason($0) },
            playEpisode: { id, fileId, fromBeginning in
                activateEpisode(id)
                playSeriesEpisode(id, fileId: fileId, fromBeginning: fromBeginning)
            }
        )
        .task(id: target?.contentId) {
            await loadSeriesNextUp(target?.contentId)
        }
        .task(id: viewModel.selectedSeason?.contentId, priority: .background) {
            await TVDetailPlaybackRules.warmNeighbourSeasons(of: viewModel)
        }
    }

    private func seasonPage(_ detail: ItemDetail) -> some View {
        let next = TVDetailPlaybackRules.nextUpEpisode(in: viewModel.episodes)
        return TVSeasonDetailPage(
            viewModel: viewModel,
            detail: detail,
            nextUpEpisode: next,
            nextUp: nextUp,
            picks: nextUpPicks,
            actions: pageActions,
            selectEpisode: { router.navigate(to: .itemDetail(contentId: $0)) },
            selectSeason: { season in
                guard season.contentId != detail.contentId else { return }
                router.navigate(to: .itemDetail(contentId: season.contentId))
            },
            playEpisode: { id, fileId, fromBeginning in
                playSeasonEpisode(id, fileId: fileId, fromBeginning: fromBeginning)
            }
        )
        .task(id: next?.contentId) {
            await loadSeasonNextUp(next?.contentId)
        }
    }

    // MARK: - Main load

    private func load() async {
        seasonSelectionTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration

        if let staged = TVSeriesDetailNavigationContextStore.take(for: contentId) {
            pendingContext = staged
            activeEpisodeId = staged.episodeContentId
        }
        // The pending context outlives a cancelled run until it resolves.
        let context = pendingContext
        viewModel.initialResumeSeasonNumber = context?.seasonNumber
        if let context {
            viewModel.jellyfinResumeEpisode = MediaServerProvider.active == .jellyfin
                ? (contentId: context.episodeContentId, seasonNumber: Optional(context.seasonNumber))
                : nil
        } else if !hasLoadedOnce {
            viewModel.jellyfinResumeEpisode = nil
        }

        nextUp = TVDetailNextUp()
        parentSeries = nil
        failedRedirectId = nil

        await viewModel.loadDetail(contentId: contentId, preserveSeasonSelection: hasLoadedOnce && context == nil)
        guard !Task.isCancelled, generation == selectionGeneration else { return }

        if let context, viewModel.detail?.type == "series", !isResolved(context),
           let season = viewModel.seasons.first(where: { $0.seasonNumber == context.seasonNumber }) {
            await viewModel.selectSeason(season, forceRefresh: true)
        }
        guard !Task.isCancelled, generation == selectionGeneration else { return }

        hasLoadedOnce = viewModel.detail?.contentId == contentId
        if let context, isResolved(context) {
            pendingContext = nil
            viewModel.initialResumeSeasonNumber = nil
        }
    }

    /// The context's season is selected and holds its episode.
    private func isResolved(_ context: TVSeriesDetailNavigationContextStore.Context) -> Bool {
        viewModel.selectedSeason?.seasonNumber == context.seasonNumber
            && viewModel.episodes.contains { $0.contentId == context.episodeContentId }
    }

    // MARK: - Episode redirect

    private struct RedirectTarget: Hashable {
        let seriesId: String
        let seasonNumber: Int
        let episodeId: String
    }

    private func redirectTarget(for detail: ItemDetail) -> RedirectTarget? {
        guard detail.type == "episode" else { return nil }
        let seriesId = detail.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !seriesId.isEmpty, seriesId != detail.contentId,
              let seasonNumber = detail.seasonNumber,
              detail.contentId != failedRedirectId else { return nil }
        return RedirectTarget(seriesId: seriesId, seasonNumber: seasonNumber, episodeId: detail.contentId)
    }

    private func runRedirect(_ target: RedirectTarget) async {
        let key = CacheKey.itemDetail(target.seriesId)
        if let cached: ItemDetail = ResponseCache.shared.get(key), cached.type == "series" {
            route(to: target)
            return
        }
        do {
            let series = try await MetadataRequestPool.shared.itemDetail(contentId: target.seriesId)
            guard !Task.isCancelled, contentId == target.episodeId else { return }
            guard series.type == "series" else {
                failedRedirectId = target.episodeId
                return
            }
            ResponseCache.shared.set(series, for: key)
            route(to: target)
        } catch {
            guard !Task.isCancelled, contentId == target.episodeId else { return }
            failedRedirectId = target.episodeId
        }
    }

    /// Replaces the episode with its series, so Back returns to wherever the
    /// episode was opened from.
    private func route(to target: RedirectTarget) {
        guard contentId == target.episodeId else { return }
        TVSeriesDetailNavigationContextStore.stage(
            seriesContentId: target.seriesId,
            seasonNumber: target.seasonNumber,
            episodeContentId: target.episodeId
        )
        router.replaceCurrent(with: .itemDetail(contentId: target.seriesId))
    }

    // MARK: - Older layout's parent series

    private func loadParentSeries(for detail: ItemDetail) async {
        guard detail.type == "episode", let seriesId = detail.seriesId, !seriesId.isEmpty else {
            parentSeries = nil
            return
        }
        let key = CacheKey.itemDetail(seriesId)
        if let cached: ItemDetail = ResponseCache.shared.get(key) {
            parentSeries = cached
        }
        do {
            let series = try await MetadataRequestPool.shared.itemDetail(contentId: seriesId)
            guard !Task.isCancelled else { return }
            ResponseCache.shared.set(series, for: key)
            parentSeries = series
        } catch {
            // Keep what is shown.
        }
    }

    /// The series an episode belongs to, for its logo, title and cast. A
    /// series page that launched the episode has cached it already.
    private func supportingDetail(for detail: ItemDetail) -> ItemDetail? {
        if let parentSeries { return parentSeries }
        guard detail.type == "episode", let seriesId = detail.seriesId, !seriesId.isEmpty else { return nil }
        return ResponseCache.shared.get(CacheKey.itemDetail(seriesId))
    }

    // MARK: - Trailers

    private var tmdbVideosKey: String {
        "\(viewModel.detail?.contentId ?? "")|\(TVTMDbStore.shared.contextKey)"
    }

    private func loadTMDbVideos() async {
        tmdbVideos = []
        let store = TVTMDbStore.shared
        guard let detail = viewModel.detail, store.isConfigured else { return }
        let context = store.contextKey
        do {
            let videos = try await store.videos(contentId: detail.contentId)
            guard !Task.isCancelled, store.contextKey == context else { return }
            tmdbVideos = videos
            tmdbVideosContext = context
        } catch {
            // No trailers.
        }
    }

    private var trailerEntries: [TrailerRailEntry] {
        let store = TVTMDbStore.shared
        let videos = store.isConfigured && tmdbVideosContext == store.contextKey ? tmdbVideos : nil
        return TrailerRail.entries(videos: videos, extras: nil, allowRemote: allowsRemoteTrailers)
    }

    /// The simulator always shows remote trailers so the full layout can be
    /// built; a device needs the YouTube app.
    private func probeRemoteTrailers() {
        #if targetEnvironment(simulator)
        allowsRemoteTrailers = true
        #else
        allowsRemoteTrailers = URL(string: "youtube://").map { UIApplication.shared.canOpenURL($0) } ?? false
        #endif
    }

    private func selectTrailer(_ entry: TrailerRailEntry) {
        switch entry {
        case .remote(let video):
            let store = TVTrailerReturnStore.shared
            store.saveHandoff(contentId: contentId)
            guard let url = TrailerRail.youtubeDeepLinkURL(siteKey: video.siteKey) else {
                store.clear()
                return
            }
            UIApplication.shared.open(url, options: [:]) { opened in
                if !opened { store.clear() }
            }
        case .local(let extra):
            router.navigate(to: .player(contentId: extra.contentId, startFromBeginning: true, resumePosition: nil))
        }
    }

    // MARK: - Completed playback

    private func applyCompletedPlayback(_ event: TVPlaybackStateRefreshEvent) {
        guard event.refreshedContentIds.contains(contentId),
              viewModel.detail?.type == "series",
              !event.completedContentIds.isEmpty else { return }
        viewModel.applyCompletedPlayback(contentIds: event.completedContentIds)
        guard let outcome = TVDetailPlaybackRules.completionOutcome(
            completed: event.completedContentIds,
            activeEpisodeId: activeEpisodeId,
            seasons: viewModel.seasons,
            pages: viewModel.episodesBySeason
        ) else { return }
        if let id = outcome.activeEpisodeId {
            activeEpisodeId = id
        }
        pendingCompletion = outcome.staysPending ? event : nil
    }
}

// MARK: - Playback actions

extension TVItemDetailView {
    // MARK: Movie page

    private func playMovie(fromBeginning: Bool) {
        guard let detail = viewModel.detail else { return }
        let resume = fromBeginning
            ? nil
            : TVDetailPlaybackRules.resumePosition(detail.userData?.positionSeconds, duration: detail.userData?.durationSeconds)
        let audio = viewModel.preferredAudioTrackIndex
        let subtitle = viewModel.preferredSubtitleTrackIndex
        let fileId: Int?
        if let pick = viewModel.preferredVersionFileId {
            fileId = pick
        } else if audio != nil || subtitle != nil {
            fileId = TVDetailPlaybackRules.effectiveVersion(of: detail, filePick: nil)?.fileId
        } else {
            fileId = nil
        }
        navigateToPlayer(contentId: contentId, fileId: fileId, audio: audio, subtitle: subtitle,
                         fromBeginning: fromBeginning, resume: resume)
    }

    private func pickMovieVersion(_ fileId: Int?) {
        viewModel.preferredVersionFileId = fileId
        let version = TVDetailPlaybackRules.effectiveVersion(of: viewModel.detail, filePick: fileId)
        viewModel.preferredAudioTrackIndex = TVDetailPlaybackRules.sanitisedAudio(viewModel.preferredAudioTrackIndex, version: version)
        viewModel.preferredSubtitleTrackIndex = TVDetailPlaybackRules.sanitisedSubtitle(viewModel.preferredSubtitleTrackIndex, version: version)
    }

    private func pickMovieAudio(_ index: Int?) {
        let version = TVDetailPlaybackRules.effectiveVersion(of: viewModel.detail, filePick: viewModel.preferredVersionFileId)
        viewModel.preferredAudioTrackIndex = TVDetailPlaybackRules.sanitisedAudio(index, version: version)
    }

    private func pickMovieSubtitle(_ index: Int?) {
        viewModel.preferredSubtitleTrackWasManuallySelected = true
        let version = TVDetailPlaybackRules.effectiveVersion(of: viewModel.detail, filePick: viewModel.preferredVersionFileId)
        viewModel.preferredSubtitleTrackIndex = TVDetailPlaybackRules.sanitisedSubtitle(index, version: version)
    }

    /// Play/Pause on another episode in the older layout's rail presents the
    /// player for it, returning to that episode's page.
    private func presentEpisodeShortcut(_ episodeId: String) {
        let episode = viewModel.episodes.first { $0.contentId == episodeId }
        let resume = TVDetailPlaybackRules.resumePosition(
            episode?.userData?.positionSeconds,
            duration: episode?.userData?.durationSeconds
        )
        router.presentPlayer(contentId: episodeId, resumePosition: resume, returnToContentId: episodeId)
    }

    // MARK: Next-up picks (season and series pages)

    private var nextUpVersion: FileVersion? {
        TVDetailPlaybackRules.effectiveVersion(of: nextUp.detail, filePick: viewModel.preferredNextUpFileId)
    }

    private func pickNextUpVersion(_ fileId: Int?) {
        viewModel.preferredNextUpFileId = fileId
        let version = TVDetailPlaybackRules.effectiveVersion(of: nextUp.detail, filePick: fileId)
        viewModel.preferredNextUpAudioTrackIndex = sanitisedNextUpAudio(viewModel.preferredNextUpAudioTrackIndex, version: version)
        viewModel.preferredNextUpSubtitleTrackIndex = sanitisedNextUpSubtitle(viewModel.preferredNextUpSubtitleTrackIndex, version: version)
    }

    private func pickNextUpAudio(_ index: Int?) {
        viewModel.preferredNextUpAudioTrackIndex = sanitisedNextUpAudio(index, version: nextUpVersion)
    }

    private func pickNextUpSubtitle(_ index: Int?) {
        viewModel.preferredNextUpSubtitleTrackIndex = sanitisedNextUpSubtitle(index, version: nextUpVersion)
    }

    /// Without a next-up detail every pick is cleared.
    private func sanitisedNextUpAudio(_ pick: Int?, version: FileVersion?) -> Int? {
        guard nextUp.detail != nil else { return nil }
        return TVDetailPlaybackRules.sanitisedAudio(pick, version: version)
    }

    private func sanitisedNextUpSubtitle(_ pick: Int?, version: FileVersion?) -> Int? {
        guard nextUp.detail != nil else { return nil }
        return TVDetailPlaybackRules.sanitisedSubtitle(pick, version: version)
    }

    private func clearNextUpPicks() {
        viewModel.preferredNextUpFileId = nil
        viewModel.preferredNextUpAudioTrackIndex = nil
        viewModel.preferredNextUpSubtitleTrackIndex = nil
    }

    // MARK: Season page

    private func playSeasonEpisode(_ episodeId: String, fileId: Int?, fromBeginning: Bool) {
        pendingCompletion = nil
        let episode = viewModel.episodes.first { $0.contentId == episodeId }
        let resume = fromBeginning
            ? nil
            : TVDetailPlaybackRules.resumePosition(episode?.userData?.positionSeconds, duration: episode?.userData?.durationSeconds)
        let file = fileId ?? nextUpVersion?.fileId
        navigateToPlayer(
            contentId: episodeId,
            fileId: file,
            audio: viewModel.preferredNextUpAudioTrackIndex,
            subtitle: viewModel.preferredNextUpSubtitleTrackIndex,
            fromBeginning: fromBeginning,
            resume: resume
        )
    }

    private func loadSeasonNextUp(_ episodeId: String?) async {
        guard let episodeId else {
            nextUp = TVDetailNextUp()
            clearNextUpPicks()
            return
        }
        nextUp = TVDetailNextUp(detail: nil, isLoading: true, isLoaded: false)
        clearNextUpPicks()
        do {
            let item = try await MetadataRequestPool.shared.itemDetail(contentId: episodeId)
            guard !Task.isCancelled else { return }
            let enriched = await TVDetailPlaybackRules.enrich(item)
            guard !Task.isCancelled else { return }
            nextUp.detail = enriched
            nextUp.isLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            nextUp.detail = nil
            nextUp.isLoaded = true
        }
        nextUp.isLoading = false
    }

    // MARK: Series page

    /// The episode Play starts: the pinned episode once there is one,
    /// otherwise the season's next-up episode.
    private var seriesPlayTarget: EpisodeListItem? {
        if let activeEpisodeId {
            if let match = viewModel.episodes.first(where: { $0.contentId == activeEpisodeId }) {
                return match
            }
            for page in viewModel.episodesBySeason.values {
                if let match = page.first(where: { $0.contentId == activeEpisodeId }) { return match }
            }
            return nil
        }
        return TVDetailPlaybackRules.nextUpEpisode(in: viewModel.episodes)
    }

    private func activateEpisode(_ episodeId: String) {
        activeEpisodeId = episodeId
        pendingCompletion = nil
    }

    private func playSeriesEpisode(_ episodeId: String, fileId: Int?, fromBeginning: Bool) {
        pendingCompletion = nil
        let episode = viewModel.episodes.first { $0.contentId == episodeId }
            ?? viewModel.episodesBySeason.values.lazy.compactMap { $0.first { $0.contentId == episodeId } }.first
        let resume = fromBeginning
            ? nil
            : TVDetailPlaybackRules.resumePosition(episode?.userData?.positionSeconds, duration: episode?.userData?.durationSeconds)
        // A quick Play after focus moved never carries another episode's file.
        let file = nextUp.detail?.contentId == episodeId ? (fileId ?? nextUpVersion?.fileId) : nil
        navigateToPlayer(
            contentId: episodeId,
            fileId: file,
            audio: viewModel.preferredNextUpAudioTrackIndex,
            subtitle: viewModel.preferredNextUpSubtitleTrackIndex,
            fromBeginning: fromBeginning,
            resume: resume
        )
    }

    /// Selects a season from the shelf. A newer request always wins, and a
    /// superseded one never starts after it.
    private func selectSeriesSeason(_ season: Season) {
        pendingContext = nil
        viewModel.initialResumeSeasonNumber = nil
        seasonSelectionTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        seasonSelectionTask = Task { @MainActor in
            guard !Task.isCancelled, generation == selectionGeneration else { return }
            await viewModel.selectSeason(season)
            guard !Task.isCancelled, generation == selectionGeneration else { return }
            seasonSelectionTask = nil
        }
    }

    private func loadSeriesNextUp(_ episodeId: String?) async {
        guard let episodeId else {
            nextUp = TVDetailNextUp()
            clearNextUpPicks()
            return
        }
        // Later browsing or episode focus never retargets Play.
        if activeEpisodeId == nil {
            activeEpisodeId = episodeId
        }
        let key = CacheKey.itemDetail(episodeId)
        let cached: ItemDetail? = ResponseCache.shared.get(key)
        let usableCache = cached.flatMap { ($0.versions ?? []).isEmpty ? nil : $0 }
        nextUp = TVDetailNextUp(detail: usableCache, isLoading: true, isLoaded: usableCache != nil)
        clearNextUpPicks()

        let pool = MetadataRequestPool.shared
        async let watchRequest = try? pool.watchDetail(contentId: episodeId)
        do {
            let item = try await pool.itemDetail(contentId: episodeId)
            guard !Task.isCancelled else { return }
            if usableCache == nil, !(item.versions ?? []).isEmpty {
                // Fill the selectors without waiting for the watch detail.
                nextUp.detail = item
                nextUp.isLoaded = true
                nextUp.isLoading = false
            }
            let watch = await watchRequest
            guard !Task.isCancelled else { return }
            var enriched: ItemDetail?
            if let watch {
                enriched = await TVDetailPlaybackRules.enrich(item, watch: watch)
            }
            guard !Task.isCancelled else { return }
            if let enriched, !(enriched.versions ?? []).isEmpty {
                ResponseCache.shared.set(enriched, for: key)
                nextUp.detail = enriched
            } else {
                nextUp.detail = nextUp.detail ?? item
            }
            nextUp.isLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            nextUp.isLoaded = true
        }
        nextUp.isLoading = false

        do {
            try await Task.sleep(for: .seconds(1.2))
        } catch {
            return
        }
        await TVDetailPlaybackRules.warmNeighbours(of: episodeId, in: viewModel.episodes)
    }

    // MARK: Navigation

    private func navigateToPlayer(
        contentId: String,
        fileId: Int?,
        audio: Int?,
        subtitle: Int?,
        fromBeginning: Bool,
        resume: Double?
    ) {
        if let fileId {
            router.navigate(to: .playerWithFile(
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: audio,
                subtitleTrackIndex: subtitle,
                startFromBeginning: fromBeginning,
                resumePosition: resume
            ))
        } else {
            router.navigate(to: .player(contentId: contentId, startFromBeginning: fromBeginning, resumePosition: resume))
        }
    }
}

// MARK: - Page inputs

/// The next-up episode's playback detail on the season and series pages.
struct TVDetailNextUp {
    var detail: ItemDetail?
    var isLoading = false
    var isLoaded = false
}

/// The next-up picks and how to change them.
struct TVDetailNextUpPicks {
    var fileId: Int?
    var audio: Int?
    var subtitle: Int?
    var pickVersion: (Int?) -> Void
    var pickAudio: (Int?) -> Void
    var pickSubtitle: (Int?) -> Void
}

/// What every page can ask the entry page to do.
struct TVDetailPageActions {
    var selectPerson: (String) -> Void
    var selectItem: (String) -> Void
    var toggleFavorite: () -> Void
    var toggleWatchlist: () -> Void
    var toggleWatched: () -> Void
    var setEpisodeWatched: (String, Bool) async -> Bool
    var setEpisodeFavorite: (String, Bool) async -> Bool
    var selectTrailer: (TrailerRailEntry) -> Void
}
#endif
