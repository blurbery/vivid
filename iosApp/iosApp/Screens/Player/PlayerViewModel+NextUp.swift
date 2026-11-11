import Foundation

/// Next Up: the following episode and the On Deck items, the prompt before
/// the end, the postroll after it, and the countdown that plays on.
///
/// Both lookups start at the current item's first picture. The prompt shows
/// within the Next Up prompt window only while the item is genuinely
/// playing: loading, buffering, scrubbing, seeking, quality changes, replans
/// and errors all hold it back.
extension PlayerViewModel {
    // MARK: - Lookups

    func loadNextUpCandidate(for detail: WatchDetail) {
        nextUpLookupTask?.cancel()
        nextUpLookupTask = nil
        nextUpEpisode = nil
        nextUpLookupError = nil
        isLoadingNextUpEpisode = false
        nextUpAutoplayCancelled = false
        nextUpPromptDismissed = false
        cancelNextUpCountdown()
        loadNextUpTitleArtwork(for: detail)

        // Shuffle already knows what plays next, so there's nothing to look
        // up, and it doesn't need the episode's own numbers.
        if shuffleQueue != nil {
            nextUpEpisode = shuffleSuccessor(of: detail.contentId) ?? shuffleSuccessor(of: lastLoadRequest?.contentId)
            if showNextUpScreen {
                startNextUpCountdownIfNeeded()
            } else {
                updateNextUpPresentation(for: currentTime)
            }
            return
        }

        guard detail.type == "episode",
              let seriesId = detail.seriesId,
              let seasonNumber = detail.seasonNumber,
              let episodeNumber = detail.episodeNumber else {
            return
        }

        isLoadingNextUpEpisode = true
        nextUpLookupTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            defer {
                if !Task.isCancelled { self.nextUpLookupTask = nil }
            }
            do {
                let episode = try await Self.resolveNextUpEpisode(
                    contentId: detail.contentId,
                    seriesId: seriesId,
                    seriesTitle: detail.seriesTitle,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                )
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.nextUpEpisode = episode
                self.isLoadingNextUpEpisode = false
                self.nextUpLookupError = nil
                if self.showNextUpScreen {
                    self.startNextUpCountdownIfNeeded()
                } else {
                    self.updateNextUpPresentation(for: self.currentTime)
                }
            } catch {
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.isLoadingNextUpEpisode = false
                self.nextUpLookupError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                if self.showNextUpScreen {
                    self.cancelNextUpCountdown()
                }
            }
        }
    }

    /// Fetches the logo and background of the episode's series, or of the
    /// movie. The next episode of the same series keeps what is already
    /// loaded. A failure (offline playback, for one) leaves the title as text
    /// over the fallback artwork.
    func loadNextUpTitleArtwork(for detail: WatchDetail) {
        let titleId = Self.nonEmpty(detail.type == "episode" ? detail.seriesId : detail.contentId)
        guard nextUpTitleArtwork == nil || nextUpTitleArtwork?.titleId != titleId else { return }
        nextUpArtworkTask?.cancel()
        nextUpArtworkTask = nil
        nextUpTitleArtwork = nil
        guard let titleId else { return }

        nextUpArtworkTask = Task { @MainActor [weak self] in
            // Through the pool, so a request already in flight for the same
            // title is shared.
            guard let item = try? await MetadataRequestPool.shared.itemDetail(contentId: titleId) else { return }
            guard let self, !Task.isCancelled, !self.isDisposed else { return }
            self.nextUpTitleArtwork = PlayerNextUpTitleArtwork(
                titleId: titleId,
                title: item.title,
                logoUrl: Self.nonEmpty(item.logoUrl),
                backdropUrl: Self.nonEmpty(item.backdropUrl),
                backdropThumbhash: item.backdropThumbhash
            )
            self.nextUpArtworkTask = nil
        }
    }

    func loadNextUpOnDeckItems(for detail: WatchDetail) {
        nextUpOnDeckTask?.cancel()
        nextUpOnDeckTask = nil
        nextUpOnDeckItems = []
        isLoadingNextUpOnDeck = true

        nextUpOnDeckTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            defer {
                if !Task.isCancelled { self.nextUpOnDeckTask = nil }
            }
            do {
                let response = try await VividAPI.shared.homeSections()
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.nextUpOnDeckItems = await Self.onDeckItems(from: response, excluding: detail)
                self.isLoadingNextUpOnDeck = false
                self.updateNextUpPresentation(for: self.currentTime)
            } catch {
                guard !Task.isCancelled, !self.isDisposed else { return }
                self.nextUpOnDeckItems = []
                self.isLoadingNextUpOnDeck = false
            }
        }
    }

    /// The episode after the current one: the rest of its season, then the
    /// first season after it that isn't specials.
    private static func resolveNextUpEpisode(
        contentId: String,
        seriesId: String,
        seriesTitle: String?,
        seasonNumber: Int,
        episodeNumber: Int
    ) async throws -> PlayerNextUpEpisode? {
        async let seasonsRequest = VividAPI.shared.seasons(seriesId: seriesId)
        async let currentSeasonRequest = VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: seasonNumber)
        let seasons = try await seasonsRequest.seasons.sortedForDisplay()
        var episodes = try await currentSeasonRequest.episodes

        if let nextSeason = seasons.first(where: { !($0.isSpecials ?? false) && $0.seasonNumber > seasonNumber }) {
            episodes += try await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: nextSeason.seasonNumber).episodes
        }

        let ordered = episodes.sorted { lhs, rhs in
            if lhs.seasonNumber != rhs.seasonNumber { return lhs.seasonNumber < rhs.seasonNumber }
            if lhs.episodeNumber != rhs.episodeNumber { return lhs.episodeNumber < rhs.episodeNumber }
            return lhs.contentId < rhs.contentId
        }
        let currentIndex = ordered.firstIndex { $0.contentId == contentId }
            ?? ordered.firstIndex { $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber }
        guard let currentIndex, currentIndex + 1 < ordered.count else { return nil }
        return PlayerNextUpEpisode(episode: ordered[currentIndex + 1], seriesId: seriesId, seriesTitle: seriesTitle)
    }

    // MARK: - On Deck

    private static let onDeckSectionTypes: Set<String> = ["continue_watching", "in_progress", "next_up"]
    private static let onDeckItemLimit = 12

    /// Up to a dozen Home items in progress or up next, leaving out the
    /// current item and its series. Only items with horizontal artwork are
    /// kept, in Home's order.
    private static func onDeckItems(from response: SectionsResponse, excluding current: WatchDetail) async -> [PlayerOnDeckItem] {
        var seenContentIds: Set<String> = []
        var sourceItems: [SectionItem] = []
        sections: for section in response.sections where onDeckSectionTypes.contains(section.sectionType) {
            for item in section.items {
                guard item.contentId != current.contentId else { continue }
                if let currentSeriesId = current.seriesId, item.seriesId == currentSeriesId { continue }
                guard seenContentIds.insert(item.contentId).inserted else { continue }
                sourceItems.append(item)
                if sourceItems.count >= onDeckItemLimit { break sections }
            }
        }

        return await withTaskGroup(of: (Int, PlayerOnDeckItem)?.self) { group in
            for (index, item) in sourceItems.enumerated() {
                group.addTask {
                    guard let artwork = await horizontalArtwork(for: item) else { return nil }
                    return (index, PlayerOnDeckItem(item: item, artworkUrl: artwork.url,
                                                    artworkThumbhash: artwork.thumbhash))
                }
            }
            var indexed: [(Int, PlayerOnDeckItem)] = []
            for await result in group {
                if let result { indexed.append(result) }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// 16:9 artwork for an On Deck item. Nil drops the item rather than
    /// stretching a poster. Artwork failures never block the choice.
    private static func horizontalArtwork(for item: SectionItem) async -> (url: String, thumbhash: String?)? {
        // An episode's own still is real 16:9 scene art; its backdrop is
        // usually the show's key art.
        if let seriesId = nonEmpty(item.seriesId), let seasonNumber = item.seasonNumber,
           let response = try? await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: seasonNumber),
           let episode = response.episodes.first(where: {
               $0.contentId == item.contentId || $0.episodeNumber == item.episodeNumber
           }),
           let stillUrl = nonEmpty(episode.stillUrl) {
            return (stillUrl, episode.stillThumbhash)
        }
        if let backdropUrl = nonEmpty(item.backdropUrl) {
            return (backdropUrl, item.backdropThumbhash)
        }
        if let detail = try? await VividAPI.shared.itemDetail(contentId: item.contentId),
           let backdropUrl = nonEmpty(detail.backdropUrl) {
            return (backdropUrl, detail.backdropThumbhash)
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Presentation

    /// Called on each time tick and when a lookup finishes. Opens the prompt
    /// on entering the prompt window, and drives the countdown while it
    /// shows.
    func updateNextUpPresentation(for movieTime: Double) {
        // A kept native host must not reopen the outgoing episode's postroll
        // before the next episode has shown its own first frame.
        guard !hasReachedEndOfFile, error == nil, !isLoading, !isBuffering,
              isPlaying, !isScrubbing, seekTargetTime == nil,
              !vividPlaybackController.engine.isSeeking, !isQualitySwitching,
              protocolV3ReplanTask == nil,
              let epoch = activeVividLoadEpoch,
              startedVividLoadEpoch == epoch else { return }
        if showNextUpScreen {
            updateNextUpCountdownForActivePlayback(at: movieTime)
            return
        }
        if let credits = creditsNextUpRange {
            if movieTime >= credits.start {
                // Watching the credits full screen keeps Next Up away until
                // the episode ends.
                guard !nextUpCreditsDismissed else { return }
                // Past the marker's end (it may stop a few seconds short of
                // the file's), the prompt before the end takes over.
                if movieTime < credits.end {
                    beginNextUpPostroll(videoEnded: false, source: .credits)
                    return
                }
            } else {
                // A seek back before the credits lets them open Next Up again.
                nextUpCreditsDismissed = false
            }
        }
        let inPromptWindow = canShowNextUpScreen && PlayerNextUpCompletionPolicy.isInPromptWindow(
            currentTime: movieTime,
            duration: duration,
            promptSeconds: settings.nextUpPromptSeconds
        )
        guard inPromptWindow else {
            // Leaving the window (a seek back) lets Keep Watching's prompt
            // come back naturally.
            nextUpPromptDismissed = false
            return
        }
        guard !nextUpPromptDismissed else { return }
        beginNextUpPostroll(videoEnded: false, source: .automatic)
    }

    /// The credits that open Next Up when playback reaches them: those of an
    /// episode with another one after it, running to the end of the file.
    /// Nil without a marker, where the prompt before the end still applies.
    var creditsNextUpRange: TimeRange? {
        guard settings.introDBEnabled else { return nil }
        return CreditsNextUpPolicy.range(
            credits: creditsRange,
            duration: duration,
            hasNextEpisode: nextUpEpisode != nil
        )
    }

    /// Whether the viewer went back to the current item to watch its credits.
    var nextUpCreditsDismissed: Bool {
        get {
            guard let dismissed = nextUpCreditsDismissedContentId else { return false }
            return dismissed == currentWatchDetail?.contentId
        }
        set { nextUpCreditsDismissedContentId = newValue ? currentWatchDetail?.contentId : nil }
    }

    /// Whether Next Up was left to watch the credits and can come back.
    var canReopenNextUpForCredits: Bool {
        nextUpCreditsDismissed && canOpenNextUpForCredits
    }

    private var canOpenNextUpForCredits: Bool {
        guard !showNextUpScreen, !isNextUpTransitioning, error == nil, !isLoading,
              !hasReachedEndOfFile,
              let credits = creditsNextUpRange else { return false }
        return currentTime >= credits.start
    }

    /// Brings Next Up back after the viewer returned to the episode to watch
    /// the credits. Returns false when there's nothing to bring back.
    @discardableResult
    func reopenNextUpForCredits() -> Bool {
        guard canReopenNextUpForCredits else { return false }
        return openNextUpForCredits()
    }

    /// Opens Next Up over the playing credits. Returns false when these
    /// credits don't open Next Up.
    @discardableResult
    func openNextUpForCredits() -> Bool {
        guard canOpenNextUpForCredits else { return false }
        nextUpCreditsDismissed = false
        // The count runs on a timer, so it mustn't run over a paused frame.
        if !isPlaying {
            vividPlaybackController.play()
        }
        beginNextUpPostroll(videoEnded: false, source: .credits)
        return true
    }

    func showNextUpNow() {
        guard canShowNextUpScreen else { return }
        beginNextUpPostroll(videoEnded: false, source: .hud)
    }

    /// Shows Next Up: the prompt before the end (`videoEnded` false) or the
    /// postroll after it. A prompt that was already counting down when the
    /// episode ended plays on straight away.
    func beginNextUpPostroll(videoEnded: Bool, source: NextUpPresentationSource = .automatic) {
        #if DEBUG
        testRecorder?.record(.postroll(videoEnded: videoEnded))
        #endif
        let wasShowing = showNextUpScreen
        let wasShowingBeforeEnd = showNextUpScreen && !nextUpScreenVideoEnded
        if !wasShowing {
            nextUpPresentationSource = source
        }
        showNextUpScreen = true
        nextUpScreenVideoEnded = videoEnded
        setControlsVisible(false, cause: .nextUp)
        activeNotice = nil
        isHUDPresented = false
        if !wasShowingBeforeEnd && !videoEnded {
            nextUpAutoplayCancelled = false
        }
        if videoEnded, wasShowingBeforeEnd, settings.autoPlayNextEpisode,
           nextUpEpisode != nil, !nextUpAutoplayCancelled {
            playNextEpisodeNow()
            return
        }
        startNextUpCountdownIfNeeded()
    }

    // MARK: - Countdown

    /// Before the end the countdown follows the time left in the episode.
    /// After it, a ten-second countdown runs.
    private func startNextUpCountdownIfNeeded() {
        cancelNextUpCountdown()
        guard showNextUpScreen,
              !isNextUpTransitioning,
              settings.autoPlayNextEpisode,
              nextUpEpisode != nil,
              !nextUpAutoplayCancelled else {
            return
        }
        // Opened by the credits, the count runs on a timer while they play,
        // as it does once the video has ended.
        guard nextUpScreenVideoEnded || nextUpPresentationSource == .credits else {
            updateNextUpCountdownForActivePlayback(at: currentTime)
            return
        }

        nextUpCountdownTotalSeconds = Self.nextUpCountdownDefaultSeconds
        nextUpCountdownSeconds = Self.nextUpCountdownDefaultSeconds
        nextUpCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = Self.nextUpCountdownDefaultSeconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !self.isDisposed else { return }
                remaining -= 1
                self.nextUpCountdownSeconds = remaining
            }
            guard !Task.isCancelled, !self.isDisposed else { return }
            self.playNextEpisodeNow()
        }
    }

    /// The prompt's countdown is the time left in the episode, and plays on
    /// in the last 0.35 seconds. Opened from the HUD with 100 seconds or more
    /// left, it shows no count until the time left drops below that.
    private func updateNextUpCountdownForActivePlayback(at movieTime: Double) {
        guard error == nil, !isLoading, !isBuffering, isPlaying,
              !isScrubbing, seekTargetTime == nil, !isQualitySwitching,
              !vividPlaybackController.engine.isSeeking, protocolV3ReplanTask == nil,
              showNextUpScreen,
              !isNextUpTransitioning,
              !nextUpScreenVideoEnded,
              nextUpPresentationSource != .credits,
              settings.autoPlayNextEpisode,
              nextUpEpisode != nil,
              !nextUpAutoplayCancelled,
              duration.isFinite,
              duration > 0,
              movieTime.isFinite else {
            return
        }

        let remaining = max(0, duration - movieTime)
        let openedFromHUD = nextUpPresentationSource == .hud
        let hudThreshold = Self.nextUpHUDCountdownThresholdSeconds
        // This runs on every time report. Each value is only written when it
        // changes, so the Next Up screen isn't redrawn on every report.
        if openedFromHUD, remaining >= hudThreshold {
            setNextUpCountdown(seconds: nil, total: Int(hudThreshold))
            return
        }
        setNextUpCountdown(
            seconds: max(0, Int(ceil(remaining))),
            total: openedFromHUD ? Int(hudThreshold) : max(1, settings.nextUpPromptSeconds)
        )
        if remaining <= 0.35 {
            playNextEpisodeNow()
        }
    }

    private func setNextUpCountdown(seconds: Int?, total: Int) {
        if nextUpCountdownTotalSeconds != total { nextUpCountdownTotalSeconds = total }
        if nextUpCountdownSeconds != seconds { nextUpCountdownSeconds = seconds }
    }

    func cancelNextUpCountdown() {
        nextUpCountdownTask?.cancel()
        nextUpCountdownTask = nil
        nextUpCountdownSeconds = nil
        nextUpCountdownTotalSeconds = Self.nextUpCountdownDefaultSeconds
    }

    func cancelNextUpFlow() {
        nextUpLookupTask?.cancel()
        nextUpLookupTask = nil
        nextUpOnDeckTask?.cancel()
        nextUpOnDeckTask = nil
        nextUpArtworkTask?.cancel()
        nextUpArtworkTask = nil
        cancelNextUpCountdown()
    }

    func cancelNextUpAutoPlay() {
        nextUpAutoplayCancelled = true
        cancelNextUpCountdown()
    }

    func setNextUpAutoPlayEnabled(_ enabled: Bool) {
        settings.setAutoPlayNextEpisode(enabled)
        if enabled {
            nextUpAutoplayCancelled = false
            startNextUpCountdownIfNeeded()
        } else {
            cancelNextUpAutoPlay()
        }
    }

    // MARK: - Actions

    /// Keep Watching. Returns false when there's no episode to go back to,
    /// so the player closes instead.
    @discardableResult
    func keepWatchingCurrentEpisode() -> Bool {
        // An autoplay load failure can restore the postroll after disposing
        // the old playback, leaving nothing to resume.
        guard hasActiveVividSession, !isNextUpTransitioning else { return false }

        let shouldResumeAfterEnd = nextUpScreenVideoEnded || hasReachedEndOfFile
        // Only a return during the credits counts: leaving a prompt opened
        // before them still lets the credits open Next Up.
        if let credits = creditsNextUpRange, currentTime >= credits.start {
            nextUpCreditsDismissed = true
        }
        nextUpAutoplayCancelled = true
        nextUpPromptDismissed = true
        showNextUpScreen = false
        nextUpScreenVideoEnded = false
        cancelNextUpCountdown()

        if shouldResumeAfterEnd, duration.isFinite, duration > 0 {
            // Resuming at the exact end would show the postroll again, so
            // replay the last ten seconds.
            hasReachedEndOfFile = false
            let reloadsPlaybackPipeline = commitSeek(to: max(0, duration - 10), source: "nextUpBack")
            if !reloadsPlaybackPipeline {
                vividPlaybackController.play()
            }
        } else if !isPlaying {
            vividPlaybackController.play()
        }
        scheduleHideControls()
        return true
    }

    /// The shuffle's episode after `contentId`, as Next Up shows it. Nil
    /// without a shuffle or at its end.
    func shuffleSuccessor(of contentId: String?) -> PlayerNextUpEpisode? {
        guard let queue = shuffleQueue, let contentId,
              let episode = queue.episode(after: contentId) else { return nil }
        return PlayerNextUpEpisode(episode: episode, seriesId: queue.seriesId, seriesTitle: queue.seriesTitle)
    }

    func playNextEpisodeNow() {
        let contentId: String
        switch PlayerNextUpPlaybackAction.resolve(
            candidateId: nextUpEpisode?.contentId,
            currentId: lastLoadRequest?.contentId,
            awaitingPicture: isNextUpTransitioning
        ) {
        case .unavailable, .waitForPicture:
            return
        case .expand:
            // The next episode is already loaded in the preview, so this only
            // changes presentation: no prepare, load, seek or play. A preview
            // that is playing, paused or buffering stays as it is.
            cancelNextUpCountdown()
            nextUpAutoplayCancelled = true
            nextUpPromptDismissed = true
            nextUpScreenVideoEnded = false
            showNextUpScreen = false
            return
        case .load(let id):
            contentId = id
        }
        var request = LoadRequest(
            contentId: contentId,
            preferredFileId: nil,
            preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            // A shuffled episode plays from its start, wherever it was left.
            startFromBeginning: shuffleQueue != nil
        )
        request.preferredQualityOverride = ApplePlaybackQuality.nextEpisodeQualityOverride(
            activeQualityId: activeQualityId
        )
        // Keep the cap this episode actually ran with instead of reading one
        // from the tier table. Ignored when nothing carries over.
        request.carriedBandwidthCap = activeBandwidthCap
        // The presenter's artwork hints describe the item it opened, so the
        // next episode fetches its own.
        applyArtworkURLHints(posterURL: nil, backdropURL: nil)
        beginFreshLoad(
            request: request,
            progressPosition: completionProgressPositionForCurrentItem(),
            finalizeCurrentSession: true,
            origin: .autoplay
        )
    }
}
