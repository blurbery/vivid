import SwiftUI

#if !os(tvOS)
/// A request to play one title, before choosing between the downloaded copy
/// and the server.
struct MobilePlayRequest: Equatable {
    let contentId: String
    let fileId: Int?
    let audioTrackIndex: Int?
    let startFromBeginning: Bool
    let resumePosition: Double?
}

/// A downloaded copy the viewer can play instead of streaming.
struct MobileOfflineChoice: Equatable {
    let downloadId: String
    let leafContentId: String
    let label: String
    let request: MobilePlayRequest
}

/// What a detail page remembers while it's open: the viewer's version and
/// audio choices, the next episode's playback options on series and season
/// pages, and the play request waiting on an alert.
@MainActor @Observable
final class MobileDetailSession {
    let model = ItemDetailViewModel()

    /// The movie or episode page's choices. Nil follows the defaults.
    var movieVersionId: Int?
    var movieAudioIndex: Int?

    /// The series and season pages' choices for the next episode.
    var nextUpVersionId: Int?
    var nextUpAudioIndex: Int?
    var nextUpDetail: WatchDetail?
    var isLoadingNextUp = false

    /// The episode chosen on the series page.
    var selectedEpisodeId: String?
    var refreshesWhenPlayerCloses = false
    var pendingOffline: MobileOfflineChoice?
    var pendingUnreachable: MobilePlayRequest?

    /// Counts the viewer's next-episode choices, so a refresh never replaces
    /// one made while it ran.
    @ObservationIgnored private var nextUpChoiceCount = 0
    /// Only the latest next-episode refresh may change the page.
    @ObservationIgnored private var nextUpGeneration = 0

    // MARK: Loading

    func load(
        contentId: String,
        resumeContext: AppRouter.ItemDetailResumeContext?,
        scrollState: PhoneDetailScrollState
    ) async {
        movieVersionId = nil
        movieAudioIndex = nil
        nextUpVersionId = nil
        nextUpAudioIndex = nil
        nextUpDetail = nil
        isLoadingNextUp = false

        selectedEpisodeId = resumeContext?.episodeContentId
        model.initialResumeSeasonNumber = resumeContext?.seasonNumber
        if let resumeContext, MediaServerProvider.active == .jellyfin {
            model.jellyfinResumeEpisode = (resumeContext.episodeContentId, resumeContext.seasonNumber)
        } else {
            model.jellyfinResumeEpisode = nil
        }
        refreshesWhenPlayerCloses = false
        scrollState.prepare(for: contentId)
        await model.loadDetail(contentId: contentId)
    }

    // MARK: Versions and audio

    func effectiveMovieVersion(_ detail: ItemDetail) -> FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: detail.versions ?? [],
            selectedFileId: movieVersionId,
            lastFileId: detail.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    var effectiveNextUpVersion: FileVersion? {
        guard let nextUpDetail else { return nil }
        return DetailVersionSelection.displayVersion(
            versions: nextUpDetail.versions,
            selectedFileId: nextUpVersionId,
            lastFileId: nextUpDetail.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    func chooseMovieVersion(_ fileId: Int?, detail: ItemDetail) {
        movieVersionId = fileId
        movieAudioIndex = Self.checkedAudioIndex(movieAudioIndex, in: effectiveMovieVersion(detail))
    }

    func chooseMovieAudio(_ index: Int?, detail: ItemDetail) {
        movieAudioIndex = Self.checkedAudioIndex(index, in: effectiveMovieVersion(detail))
    }

    func chooseNextUpVersion(_ fileId: Int?) {
        nextUpVersionId = fileId
        nextUpAudioIndex = Self.checkedAudioIndex(nextUpAudioIndex, in: effectiveNextUpVersion)
        nextUpChoiceCount += 1
    }

    func chooseNextUpAudio(_ index: Int?) {
        nextUpAudioIndex = Self.checkedAudioIndex(index, in: effectiveNextUpVersion)
        nextUpChoiceCount += 1
    }

    /// An audio track index the version actually has, or nil.
    nonisolated static func checkedAudioIndex(_ index: Int?, in version: FileVersion?) -> Int? {
        guard let index, let version else { return nil }
        return (version.audioTracks ?? []).indices.contains(index) ? index : nil
    }

    // MARK: Resume positions

    /// The position pages show and offer to resume from: past the first 30
    /// seconds and not in the last 5.
    nonisolated static func displayResumePosition(_ userData: LeafItemUserData?) -> Double? {
        guard let position = userData?.positionSeconds, position > 30 else { return nil }
        if let duration = userData?.durationSeconds, duration > 0, position >= duration - 5 { return nil }
        return position
    }

    /// The position handed to the player, which also has to be finite.
    nonisolated static func playerResumePosition(_ userData: LeafItemUserData?) -> Double? {
        guard let position = userData?.positionSeconds, position.isFinite, position > 30 else { return nil }
        if let duration = userData?.durationSeconds, duration.isFinite, duration > 0, position >= duration - 5 {
            return nil
        }
        return position
    }

    // MARK: The next episode

    /// The first episode in progress, else the first unwatched one, else
    /// the first.
    nonisolated static func defaultEpisode(_ episodes: [EpisodeListItem]) -> EpisodeListItem? {
        episodes.first { $0.userData?.isInProgress == true }
            ?? episodes.first { $0.userData?.played != true }
            ?? episodes.first
    }

    /// The episode whose playback options the page loads. The series page
    /// follows the episode the viewer chose; Jellyfin waits for it to load.
    func playbackEpisode(isSeries: Bool) -> EpisodeListItem? {
        let episodes = model.episodes
        guard isSeries, let selectedEpisodeId else { return Self.defaultEpisode(episodes) }
        if let chosen = episodes.first(where: { $0.contentId == selectedEpisodeId }) { return chosen }
        return MediaServerProvider.active == .jellyfin ? nil : Self.defaultEpisode(episodes)
    }

    /// The episode id the series page is told to treat as next up.
    var seriesNextUpEpisodeId: String? {
        let playback = playbackEpisode(isSeries: true)?.contentId
        if MediaServerProvider.active == .jellyfin {
            return selectedEpisodeId ?? playback
        }
        return playback
    }

    private enum NextUpResult {
        case playback(WatchDetail?)
        case catalogue(ItemDetail?)
    }

    /// Loads the next episode's playback options: from the cache at once,
    /// then from the server, then warms its neighbours.
    func refreshNextUp(isSeries: Bool) async {
        nextUpGeneration += 1
        let generation = nextUpGeneration
        defer {
            if generation == nextUpGeneration { isLoadingNextUp = false }
        }

        model.stopEpisodePagePrefetch()
        nextUpVersionId = nil
        nextUpAudioIndex = nil
        guard let episode = playbackEpisode(isSeries: isSeries) else {
            nextUpDetail = nil
            return
        }

        let episodeId = episode.contentId
        let choicesAtStart = nextUpChoiceCount
        let cache = ResponseCache.shared
        let watchKey = CacheKey.itemWatchDetail(episodeId)
        let catalogueKey = CacheKey.itemDetail(episodeId)

        var isShowing = false
        if let cached = cache.get(watchKey, as: WatchDetail.self), cached.contentId == episodeId {
            nextUpDetail = cached
            isShowing = true
        } else if let item = cache.get(catalogueKey, as: ItemDetail.self), item.contentId == episodeId,
                  let preview = WatchDetail(catalogItem: item) {
            nextUpDetail = preview
            isShowing = true
        } else {
            nextUpDetail = nil
        }
        isLoadingNextUp = !isShowing
        let needsCatalogue = !isShowing

        guard let identity = await TokenStore.shared.captureOrdinaryRequestAuth() else { return }

        var hasPlaybackDetail = false
        var abandoned = false
        await withTaskGroup(of: NextUpResult.self) { group in
            group.addTask {
                .playback(try? await MetadataRequestPool.shared.watchDetail(contentId: episodeId))
            }
            if needsCatalogue {
                group.addTask {
                    .catalogue(try? await MetadataRequestPool.shared.itemDetail(contentId: episodeId))
                }
            }
            for await result in group {
                guard await isCurrent(generation, identity: identity),
                      playbackEpisode(isSeries: isSeries)?.contentId == episodeId else {
                    abandoned = true
                    group.cancelAll()
                    return
                }
                switch result {
                case .playback(let detail):
                    guard let detail, detail.contentId == episodeId else { continue }
                    cache.set(detail, for: watchKey)
                    hasPlaybackDetail = true
                    if nextUpChoiceCount == choicesAtStart {
                        nextUpDetail = detail
                        isShowing = true
                    }
                    isLoadingNextUp = false
                    group.cancelAll()
                case .catalogue(let item):
                    guard let item, item.contentId == episodeId,
                          let preview = WatchDetail(catalogItem: item) else { continue }
                    cache.set(item, for: catalogueKey)
                    if !hasPlaybackDetail, !isShowing, nextUpChoiceCount == choicesAtStart {
                        nextUpDetail = preview
                        isShowing = true
                        isLoadingNextUp = false
                    }
                }
            }
        }

        guard !abandoned, hasPlaybackDetail else { return }
        let episodes = model.episodes
        guard let index = episodes.firstIndex(where: { $0.contentId == episodeId }) else { return }
        let neighbours = [index + 1, index - 1]
            .filter { episodes.indices.contains($0) }
            .map { episodes[$0].contentId }
        for neighbourId in neighbours {
            guard await isCurrent(generation, identity: identity) else { return }
            let key = CacheKey.itemWatchDetail(neighbourId)
            if cache.get(key, as: WatchDetail.self) != nil { continue }
            let fetched = try? await MetadataRequestPool.shared.watchDetail(contentId: neighbourId)
            guard await isCurrent(generation, identity: identity) else { return }
            guard let fetched else { continue }
            guard fetched.contentId == neighbourId else { return }
            cache.set(fetched, for: key)
        }
        guard generation == nextUpGeneration, !Task.isCancelled else { return }
        model.prefetchSeasonsAfterPlaybackSelectors()
    }

    /// Still the latest refresh, not cancelled, and the same sign-in.
    private func isCurrent(_ generation: Int, identity: CapturedOrdinaryRequestAuth) async -> Bool {
        guard !Task.isCancelled, generation == nextUpGeneration else { return false }
        guard await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: identity) != nil else { return false }
        return !Task.isCancelled && generation == nextUpGeneration
    }

    // MARK: Playing

    func playMovie(contentId: String, detail: ItemDetail, fromBeginning: Bool, router: AppRouter) {
        let fileId = movieVersionId ?? (movieAudioIndex != nil ? effectiveMovieVersion(detail)?.fileId : nil)
        play(
            MobilePlayRequest(
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: fileId == nil ? nil : movieAudioIndex,
                startFromBeginning: fromBeginning,
                resumePosition: fromBeginning ? nil : Self.playerResumePosition(detail.userData)
            ),
            router: router
        )
    }

    /// Plays an episode from a series or season page. Only the episode whose
    /// options are showing takes the chosen version and audio track.
    func playEpisode(_ episodeId: String, fromBeginning: Bool, fileChoice: Int?, isSeries: Bool, router: AppRouter) {
        let live = model.episodes.first { $0.contentId == episodeId }
        var fileId: Int?
        var audioTrackIndex: Int?
        if playbackEpisode(isSeries: isSeries)?.contentId == episodeId {
            fileId = fileChoice ?? (nextUpAudioIndex != nil ? effectiveNextUpVersion?.fileId : nil)
            audioTrackIndex = fileId == nil ? nil : nextUpAudioIndex
        }
        play(
            MobilePlayRequest(
                contentId: episodeId,
                fileId: fileId,
                audioTrackIndex: audioTrackIndex,
                startFromBeginning: fromBeginning,
                resumePosition: fromBeginning ? nil : Self.playerResumePosition(live?.userData)
            ),
            router: router
        )
    }

    /// Plays a downloaded copy directly when the server can't be reached,
    /// asks when it can, and otherwise streams.
    private func play(_ request: MobilePlayRequest, router: AppRouter) {
        if let record = DownloadManager.shared.record(forContentId: request.contentId), record.isPlayableOffline {
            if !ConnectionMonitor.shared.isServerReachable {
                refreshesWhenPlayerCloses = true
                router.presentOfflinePlayer(
                    downloadId: record.id,
                    contentId: record.leafMediaItemId,
                    startFromBeginning: request.startFromBeginning,
                    resumePosition: request.resumePosition
                )
            } else {
                pendingOffline = MobileOfflineChoice(
                    downloadId: record.id,
                    leafContentId: record.leafMediaItemId,
                    label: Self.offlineLabel(record),
                    request: request
                )
            }
            return
        }
        guard ConnectionMonitor.shared.isServerReachable else {
            pendingUnreachable = request
            return
        }
        stream(request, router: router)
    }

    func stream(_ request: MobilePlayRequest, router: AppRouter) {
        refreshesWhenPlayerCloses = true
        let ownItem = model.detail?.contentId == request.contentId ? model.detail : nil
        router.presentPlayer(
            contentId: request.contentId,
            fileId: request.fileId,
            audioTrackIndex: request.audioTrackIndex,
            subtitleTrackIndex: nil,
            startFromBeginning: request.startFromBeginning,
            resumePosition: request.resumePosition,
            posterURL: ownItem?.posterUrl,
            backdropURL: ownItem?.backdropUrl
        )
    }

    func playOffline(_ choice: MobileOfflineChoice, router: AppRouter) {
        refreshesWhenPlayerCloses = true
        router.presentOfflinePlayer(
            downloadId: choice.downloadId,
            contentId: choice.leafContentId,
            startFromBeginning: choice.request.startFromBeginning,
            resumePosition: choice.request.resumePosition
        )
    }

    /// "Play Downloaded (20 Mbps · 2.1 GB)".
    static func offlineLabel(_ record: DownloadRecord) -> String {
        var parts: [String] = []
        let quality = record.effectiveQuality ?? record.format
        if !quality.isEmpty {
            parts.append(DownloadFormat(rawValue: quality)?.displayName ?? quality.capitalized)
        }
        if record.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
        }
        guard !parts.isEmpty else { return String(localized: "Play Downloaded") }
        let details = parts.joined(separator: " · ")
        return String(localized: "Play Downloaded (\(details))")
    }
}
#endif
