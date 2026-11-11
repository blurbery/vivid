import Foundation
import OSLog

/// Starting an item: the server session (or a download's local record), the
/// published state the screens read, and the reload intent carried into
/// renewals, replans and retries.
extension PlayerViewModel {
    // MARK: Starting an item

    /// Plays an item picked from outside the player. A new viewing, so
    /// Settings > Subtitles and Audio Language apply again; an audio track
    /// picked on the detail page carries its language to next episodes, as a
    /// pick in the player does.
    func loadAndPlay(
        contentId: String,
        preferredFileId: Int? = nil,
        preferredAudioTrackIndex: Int? = nil,
        preferredSubtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool,
        resumePositionOverride: Double? = nil,
        prefersLastUsedVersion: Bool = false,
        offlineDownloadId: String? = nil
    ) {
        var request = LoadRequest(
            contentId: contentId,
            preferredFileId: preferredFileId,
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: startFromBeginning,
            offlineDownloadId: offlineDownloadId
        )
        request.prefersLastUsedVersion = prefersLastUsedVersion
        // A shuffle staged for this episode starts here; any other start
        // ends one.
        shuffleQueue = EpisodeShuffleHandoff.shared.take(for: contentId)
        viewingSubtitlePrefs = nil
        viewingAudioLanguage = nil
        viewingAudioSeedOrdinal = preferredAudioTrackIndex
        beginFreshLoad(
            request: request,
            progressPosition: currentTime,
            resumePositionOverride: resumePositionOverride
        )
    }

    /// Replaces whatever is loaded with `request`.
    ///
    /// Everything that belongs to the outgoing item is retired synchronously
    /// (its load epoch, queued replan work, Next Up flow and published state)
    /// before the load task starts, so nothing late from it can land on the
    /// new one. The task then reports the outgoing position (`progressPosition`,
    /// stopping the session when `finalizeCurrentSession` or the new item is
    /// a download), prepares the new session, opens it in the engine and, for
    /// Silo, commits the plan and binds realtime.
    ///
    /// Until the task exits it's the only handler of a failure of this load
    /// (`freshLoadOwnsFailureHandling`); `origin` decides how that failure is
    /// shown.
    func beginFreshLoad(
        request: LoadRequest,
        progressPosition: Double?,
        finalizeCurrentSession: Bool = false,
        resumePositionOverride: Double? = nil,
        allowNearEndResume: Bool = false,
        origin: LoadOrigin = .userInitiated
    ) {
        guard !isDisposed else { return }
        #if os(tvOS)
        PlaybackTrialTrace.requestPlay()
        #endif
        #if os(iOS) || os(tvOS)
        AppHealthMonitor.playerOpened()
        if refreshHomeAfterPlaybackWrite == nil {
            refreshHomeAfterPlaybackWrite = StartupContentPrefetcher.homeRefreshAfterPlaybackWrite()
        }
        #endif
        #if os(tvOS)
        PosterImageCache.trimDecodedMemory()
        #endif
        isNextUpTransitioning = origin == .autoplay && showNextUpScreen
        recordCurrentPlaybackMutation(markedCompleted: completedPlaybackContentId != nil)
        let priorProgressEligible = progressIsEligible
        let priorCompletedContentId = completedPlaybackContentId
        let isNewItem = lastLoadRequest?.contentId != request.contentId
        if isNewItem {
            hasStartedPlayback = false
            completedPlaybackContentId = nil
        } else if request.startFromBeginning {
            // Play from Beginning of the same item restarts at 0, which isn't
            // a watched position until its first frame. Other reloads of an
            // item that has played resume in place and keep the latch.
            hasStartedPlayback = false
        }
        let pendingNaturalEndProgressTask = naturalEndProgressTask
        naturalEndProgressTask = nil
        qualityFallbackTask?.cancel()
        qualityFallbackTask = nil
        playbackFallbackGate.update(buffering: false, eligible: false, now: ProcessInfo.processInfo.systemUptime)
        if isNewItem {
            playbackFallbackMode = request.preferredQualityOverride.map {
                PlaybackFallbackMode(rawValue: $0)
            } ?? settings.fallbackMode
            playbackFallbackGate = PlaybackFallbackGate()
            failedServerBurnIns = []
        }
        lastLoadRequest = request
        offlinePlaybackContext = nil
        contentIdsNeedingDetailRefresh.insert(request.contentId)
        hasReachedEndOfFile = false
        // Retire the outgoing epoch now. The engine is only disposed several
        // awaits later, and until this is nil a late end or failure from the
        // old item still passes `handleVividEvent`'s epoch filter and lands on
        // the item that's just starting.
        activeVividLoadEpoch = nil
        committedProtocolV3LoadEpoch = nil
        pendingProtocolV3FirstFrameEpoch = nil
        // The outgoing item's queued follow-ups don't apply to this one.
        pendingProtocolV3SeekReanchorPosition = nil
        pendingProtocolV3TrackChange = nil
        seekReplanTask?.cancel()
        seekReplanTask = nil
        cancelNextUpFlow()
        attachNowPlayingIfNeeded()
        resetPublishedLoadState(
            preferredAudioTrackIndex: request.preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: request.preferredSidecarSubtitleTrackId,
            preferredProtocolV3SubtitleIndex: request.preferredProtocolV3SubtitleIndex
        )
        if request.keepsAutomaticSubtitles {
            // The carried subtitle is Auto's, so an audio switch after the
            // reload still runs Auto again.
            hasExplicitSubtitleChoice = false
        }

        // The outgoing item's timer reads bridge state on each tick. Stop it
        // before the new session becomes provisional, or it can report the
        // new item's reset position against an uncommitted candidate.
        progressTask?.cancel()
        progressTask = nil
        freshLoadTask?.cancel()
        protocolV3ReplanTask?.cancel()
        protocolV3ReplanTask = nil
        freshLoadGeneration &+= 1
        transientRecoveryBudget.cancel()
        transientRecoveryBudget = VividTransientRecoveryBudget()
        prematureEndRecoveryGate = VividPrematureEndRecoveryGate()
        let freshGeneration = freshLoadGeneration
        streamLoadGeneration &+= 1
        let streamGeneration = streamLoadGeneration
        // A download never starts a server session of its own, so the current
        // one is stopped here. Otherwise the bridge keeps holding it and a
        // later teardown reports the download's position against it.
        let stopsCurrentSession = finalizeCurrentSession || request.offlineDownloadId != nil
        freshLoadOwnsFailureHandling = true
        freshLoadTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            var uncommittedPrepared: PreparedPlayback?
            var burnedInLoad: ServerBurnInFailure?
            defer {
                defer { self.recoverPendingUnexpectedEnd() }
                if self.freshLoadGeneration == freshGeneration {
                    self.freshLoadTask = nil
                    self.freshLoadOwnsFailureHandling = false
                }
            }
            @MainActor func isCurrentLoad() -> Bool {
                !Task.isCancelled && !self.isDisposed
                    && freshGeneration == self.freshLoadGeneration
                    && streamGeneration == self.streamLoadGeneration
            }
            @MainActor func requireCurrentLoad() throws {
                try self.requireCurrentStreamLoad(streamGeneration)
                guard freshGeneration == self.freshLoadGeneration else { throw CancellationError() }
            }

            await pendingNaturalEndProgressTask?.value
            if let progressPosition, progressPosition.isFinite, progressPosition >= 0 {
                if stopsCurrentSession {
                    await self.sessionBridge.stopSession(
                        position: progressPosition, isPaused: true,
                        eligible: priorProgressEligible, completedContentId: priorCompletedContentId
                    )
                } else {
                    await self.sessionBridge.reportProgress(
                        position: progressPosition, isPaused: true,
                        eligible: priorProgressEligible, completedContentId: priorCompletedContentId
                    )
                }
                #if os(iOS) || os(tvOS)
                self.refreshHomeAfterPlaybackWrite?()
                #endif
            }
            guard isCurrentLoad() else { return }
            await self.realtimeClient.unbind()
            guard isCurrentLoad() else { return }

            do {
                self.disposeVividPlayback(forReplacement: true)
                guard !Task.isCancelled, !self.isDisposed else { return }
                // `init` started fetching the server's device settings. Wait
                // for that request rather than sending a second one; if it has
                // finished this returns at once.
                await self.settingsRefreshTask?.value
                try requireCurrentLoad()

                let preparation = try await self.prepareFreshPlayback(
                    request: request,
                    resumePositionOverride: resumePositionOverride,
                    allowNearEndResume: allowNearEndResume,
                    origin: origin
                )
                try requireCurrentLoad()
                let prepared = preparation.prepared
                if prepared.protocolV3 != nil {
                    uncommittedPrepared = prepared
                }
                if let offlineContext = preparation.offlineContext {
                    self.offlinePlaybackContext = offlineContext
                }
                if let artworkURL = preparation.offlineArtworkURL {
                    self.nowPlaying.setArtworkURL(artworkURL)
                }
                self.publishPreparedPlayback(prepared, request: request)
                burnedInLoad = prepared.transcodeSubtitles?.burnedIndex.map {
                    ServerBurnInFailure(
                        contentId: prepared.watchDetail.contentId,
                        fileId: prepared.selectedVersion.fileId,
                        index: $0
                    )
                }

                let session = prepared.session
                guard let streamRequest = await self.makeStreamRequest(for: prepared) else {
                    throw VividLoadSpec.ValidationError.invalidStreamURL(session.streamUrl)
                }
                try requireCurrentLoad()
                self.resolvedServerUrl = streamRequest.serverUrl

                Self.logger.info("Play method: \(session.playMethod, privacy: .public)")
                // A console breadcrumb without the signed stream URL or any
                // server identity.
                print("[CMP] streamPrepared engine=VividEngine playMethod=\(session.playMethod) startTime=\(session.position)")

                try await self.loadVivid(
                    prepared: prepared,
                    streamRequest: streamRequest,
                    expectedStreamLoadGeneration: streamGeneration,
                    // Recovery keeps the viewer's play or pause; anything else
                    // starts playing.
                    shouldPlayWhenReady: origin == .recovery
                        ? self.vividPlaybackController.shouldPlayWhenReady : true
                )
                await self.sessionBridge.reportNativePlaybackStarted(prepared)
                if prepared.protocolV3 != nil {
                    guard await self.sessionBridge.commitPendingProtocolV3Transition(prepared) else {
                        throw CancellationError()
                    }
                    self.markProtocolV3VividLoadCommitted()
                    uncommittedPrepared = nil
                    // Realtime is keyed by the committed session. Binding
                    // before the engine accepts the candidate could leave
                    // commands attached to a session that's rolled back.
                    await self.realtimeClient.bind(sessionId: session.sessionId)
                    await self.sessionBridge.reportProtocolV3PlanExecutionStarted(prepared)
                    try self.requireCurrentStreamLoad(streamGeneration)
                }
            } catch is CancellationError {
                // Tear the abandoned load down before retiring its session, or
                // the engine keeps reading the stream after the DELETE and
                // spends minutes in 404 backoff. A newer load that already
                // took the controller has replaced this source itself.
                if freshGeneration == self.freshLoadGeneration, streamGeneration == self.streamLoadGeneration {
                    _ = self.disposeVividPlayback()
                }
                if let uncommittedPrepared {
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                return
            } catch let error {
                let loadFailure = Self.protocolV3LoadFailureRecovery(error)
                if let uncommittedPrepared {
                    // The engine's failure may already be published for this
                    // epoch, but the committed-load gate keeps it from racing
                    // this. Promote only the failed plan's identity (not a
                    // success) and let Silo choose the next bounded route
                    // rather than ending at the first open failure.
                    if loadFailure.shouldAdvanceRoute,
                       await self.sessionBridge.promotePendingProtocolV3TransitionForRecovery(uncommittedPrepared) {
                        Self.logger.warning(
                            "Initial Protocol V3 route failed to open; requesting next route: \(MediaLogRedactor.sanitize(error), privacy: .public)"
                        )
                        if self.attemptProtocolV3Replan(
                            position: self.currentTime,
                            classification: loadFailure.classification,
                            message: loadFailure.message
                        ) {
                            return
                        }
                    }
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                guard !Task.isCancelled, !self.isDisposed else { return }
                await self.sessionBridge.stopSession(
                    position: self.currentTime, isPaused: true,
                    eligible: self.progressIsEligible, completedContentId: self.completedPlaybackContentId
                )
                Self.logger.error("Load failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
                if let burnedInLoad,
                   self.fallBackFromFailedServerBurnIn(burnedInLoad, error: error, request: request, origin: origin) {
                    return
                }
                self.handleBeginFreshLoadFailure(error: error, origin: origin)
            }
        }
    }

    /// A prepared item, with a download's local context when it plays offline.
    private struct FreshPreparation {
        let prepared: PreparedPlayback
        var offlineContext: OfflinePlaybackContext?
        var offlineArtworkURL: URL?
    }

    private func prepareFreshPlayback(
        request: LoadRequest,
        resumePositionOverride: Double?,
        allowNearEndResume: Bool,
        origin: LoadOrigin
    ) async throws -> FreshPreparation {
        guard let downloadId = request.offlineDownloadId else {
            // Autoplay and recovery loads have a time limit on starting the
            // session; a user's own pick doesn't. A slow manual pick is only
            // annoying, but a hung autoplay leaves the viewer stuck on a
            // half-faded Next Up screen with no obvious way out.
            let prepared = try await runStartSession(
                request: request,
                resumePosition: resumePositionOverride,
                allowNearEndResume: allowNearEndResume,
                timeout: origin == .userInitiated ? nil : Self.autoplayStartSessionTimeout
            )
            return FreshPreparation(prepared: prepared)
        }
        // Prepared entirely from the stored record and manifest. It has to
        // work in airplane mode, so nothing here (or anything later while
        // `offlinePlaybackContext` is set) may need the server.
        let offline = try await OfflinePlaybackBuilder.loadPreparedPlayback(
            downloadId: downloadId,
            startFromBeginning: request.startFromBeginning,
            resumePositionOverride: resumePositionOverride,
            preferredAudioTrackIndex: request.preferredAudioTrackIndex,
            viewingAudioLanguage: viewingAudioLanguage,
            audioLanguage: settings.audioLanguage
        )
        return FreshPreparation(
            prepared: offline.prepared,
            offlineContext: OfflinePlaybackContext(downloadId: offline.downloadId, mediaItemId: offline.mediaItemId),
            offlineArtworkURL: offline.posterFileURL
        )
    }

    /// Publishes a prepared item: its session, title, metadata, tracks
    /// intent, quality choices, timeline and markers.
    private func publishPreparedPlayback(_ prepared: PreparedPlayback, request: LoadRequest) {
        let session = prepared.session
        activePlaybackSessionId = session.sessionId
        autoSkippedIntroKey = nil
        autoSkippedCreditsKey = nil
        autoSkipIntroCancelledKey = nil
        cancelPendingIntroAutoSkip()
        staleSessionRecoverySessionId = nil
        // Use the device's caption settings as they are now, not as they were
        // when Vivid last noticed a change.
        if settings.subtitleMatchesSystemAppearance {
            settings.refreshSubtitleSystemAppearance()
        }
        // The preferred language orders the subtitle list, even when a track
        // was picked, so the viewer's language groups float to the top.
        subtitleOrderingLanguage = settings.subtitleMatchesSystemAppearance
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first
            : settings.preferredSubtitleLanguage
        // Auto's inputs (Settings > Subtitles, the device's caption settings or
        // this viewing's pick), read once the engine lists its tracks. A pick
        // passed in with the request always wins, so none is taken then.
        if !hasExplicitSubtitleChoice {
            prefsForCurrentItem = automaticSubtitlePrefsSnapshot(prepared.watchDetail)
        }

        title = prepared.displayTitle
        metadata = prepared.playerMetadata()
        currentWatchDetail = prepared.watchDetail
        currentSelectedVersion = prepared.selectedVersion
        activePreparedProtocolV3 = prepared.protocolV3
        adoptProtocolV3RenewalIntent(from: prepared)
        adoptServerTranscodeSubtitles(prepared)
        // Artwork and Next Up are catalogue fetches. A download has already
        // published its own poster and has no server to find a next episode on.
        if request.offlineDownloadId == nil {
            pushNowPlayingArtwork(contentId: prepared.watchDetail.contentId)
            // Next Up and On Deck wait for the first picture. During a Next Up
            // hand-off the panel still describes the item being loaded, and
            // fetching its successor now would move the Play Now target again;
            // an ordinary load waits too, because On Deck reads the whole Home
            // payload plus up to a dozen items, which competes with startup.
            nextUpPrefetchPending = !isNextUpTransitioning
        }
        qualityOptions = Self.playbackQualityOptions(for: prepared)
        activeQualityId = prepared.activeQualityId
        activeBandwidthCap = prepared.bandwidthCap
        isQualitySwitching = false
        qualitySwitchError = nil
        duration = session.durationSeconds ?? prepared.selectedVersion.duration ?? 0
        currentTime = movieTime(for: session)
        loadVividMarkers(for: prepared.watchDetail)
    }

    /// Starts the server session, with an optional time limit. When the limit
    /// passes, the start is cancelled and reported as
    /// `BeginFreshLoadError.startSessionTimeout`; a cancellation of the load
    /// itself stays a cancellation.
    private func runStartSession(
        request: LoadRequest,
        resumePosition: Double?,
        allowNearEndResume: Bool,
        timeout: TimeInterval?
    ) async throws -> PreparedPlayback {
        // Emby and Jellyfin draw a bitmap pick into the video when they transcode.
        let serverBurnInSubtitleIndex = serverBurnInCandidate(for: request)
        let viewingAudioLanguage = viewingAudioLanguage
        let start = { [sessionBridge] () async throws -> PreparedPlayback in
            // Subtitles are never asked of the server at start: Vivid picks
            // and draws them itself once the engine lists its tracks.
            try await sessionBridge.startSession(
                contentId: request.contentId,
                preferredFileId: request.preferredFileId,
                preferredAudioTrackIndex: request.preferredAudioTrackIndex,
                viewingAudioLanguage: viewingAudioLanguage,
                preferredSubtitleTrackIndex: -1,
                preferredProtocolV3SubtitleIndex: -1,
                initialSubtitlePreferences: nil,
                startFromBeginning: request.startFromBeginning,
                resumePosition: resumePosition,
                allowNearEndResume: allowNearEndResume,
                prefersLastUsedVersion: request.prefersLastUsedVersion,
                preferredQualityOverride: request.preferredQualityOverride,
                carriedBandwidthCap: request.carriedBandwidthCap,
                serverBurnInSubtitleIndex: serverBurnInSubtitleIndex
            )
        }
        guard let timeout else { return try await start() }

        let startTask = Task<PreparedPlayback, Error> { try await start() }
        let timeoutTask = Task<Void, Never> { [startTask] in
            try? await Task.sleep(for: .seconds(timeout))
            startTask.cancel()
        }
        defer { timeoutTask.cancel() }
        do {
            return try await startTask.value
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            throw BeginFreshLoadError.startSessionTimeout
        }
    }

    /// Shows a failed load according to what started it. A viewer's own pick
    /// gets the full-screen Retry. Autoplay goes back to the Next Up postroll
    /// with `nextUpStartError`, so the viewer can choose something else or go
    /// back. A recovery load stays on the player with a notice.
    private func handleBeginFreshLoadFailure(error: Error, origin: LoadOrigin) {
        isNextUpTransitioning = false
        let message: String = {
            if case BeginFreshLoadError.startSessionTimeout = error {
                return "The server didn't respond in time."
            }
            if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
                return localized
            }
            return String(describing: error)
        }()

        switch origin {
        case .userInitiated:
            finalizeTerminalPlaybackError(message)
        case .autoplay:
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from autoplay failure: \(MediaLogRedactor.sanitize(message), privacy: .public)"
            )
            // Only the engine dispose and the loading and playing flags are
            // shared with the Retry screen's teardown, and there's no
            // `error`: this surface stays recoverable.
            stopAfterRecoverableLoadFailure()
            // Drop the candidate episode so the panel shows its Finished state
            // with the start error, unless a shuffle offers the one after it.
            cancelNextUpFlow()
            nextUpStartError = message
            // A shuffle offers the episode after the one that failed, so one
            // unplayable episode doesn't end it. Autoplay stays off.
            nextUpEpisode = shuffleSuccessor(of: lastLoadRequest?.contentId)
            nextUpAutoplayCancelled = true
            isLoadingNextUpEpisode = false
            showNextUpScreen = true
            nextUpScreenVideoEnded = true
            showNotice(
                title: String(localized: "Couldn't start the next episode"),
                message: PlaybackFailureText.localized(message),
                tone: .warning,
                duration: 6
            )
        case .recovery:
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from playback recovery failure: \(MediaLogRedactor.sanitize(message), privacy: .public)"
            )
            stopAfterRecoverableLoadFailure()
            showNotice(
                title: String(localized: "Playback recovery failed"),
                message: PlaybackFailureText.localized(message),
                tone: .warning,
                duration: 6
            )
        }
    }

    private func stopAfterRecoverableLoadFailure() {
        disposeVividPlayback()
        isLoading = false
        isPlaying = false
    }

    /// Ends the current item at the Retry screen and writes the "playback
    /// ended in failure" breadcrumb. A failed autoplay load goes back to
    /// Next Up and a failed recovery load shows a notice instead; neither
    /// comes through here.
    func finalizeTerminalPlaybackError(_ message: String) {
        #if DEBUG
        testRecorder?.record(.terminalError(message))
        #endif
        suppressNextUpForPlaybackFailure()
        #if os(iOS) || os(tvOS)
        // Recorded before teardown, while the position and plan still
        // describe the failed session.
        let failureToken = stablePlaybackFailureToken(for: message)
        let failurePositionMs = PlaybackSessionBridge.diagnosticsPositionMilliseconds(currentTime)
        DiagTrace.breadcrumb(
            .essential,
            level: .error,
            category: .playback,
            tag: "Player",
            message: "playback ended in failure",
            attrs: [
                "reason": .string(failureToken),
                "play_method": .string(activeRouteLabel),
                // The same scale and rounding as the bridge's session
                // breadcrumbs, so a report's positions line up.
                "position_ms": .int(failurePositionMs),
            ]
        )
        AppHealthMonitor.playbackFailed(reason: failureToken, playMethod: activeRouteLabel, positionMs: failurePositionMs)
        #endif
        // Save the resume point before anything is torn down. The periodic
        // report runs every 10 seconds and is cancelled just below, so without
        // this the viewer resumes up to ten seconds before the failure. Sent
        // while `activePlaybackSessionId` is still set; best effort.
        flushPlaybackProgressNow(reason: "terminal_failure")
        progressTask?.cancel()
        progressTask = nil
        staleSessionRecoveryTask?.cancel()
        staleSessionRecoveryTask = nil
        disposeVividPlayback()
        activePlaybackSessionId = nil
        activePreparedProtocolV3 = nil
        error = message
        isLoading = false
        isPlaying = false
    }

    // MARK: Session renewal

    /// Starts a new session for the current item at `observedPosition` after
    /// the server lost the old one. Runs once per lost session; returns false
    /// only when there's nothing to renew.
    @discardableResult
    func attemptStaleSessionRenewal(reason: String, observedPosition: Double) -> Bool {
        guard !isDisposed, let lastLoadRequest else { return false }

        let staleSessionId = activePlaybackSessionId ?? "unknown"
        if staleSessionRecoverySessionId == staleSessionId {
            return true
        }
        staleSessionRecoverySessionId = staleSessionId
        let resumePosition = observedPosition.isFinite ? max(0, observedPosition) : max(0, currentTime)
        let contentId = currentWatchDetail?.contentId ?? lastLoadRequest.contentId
        let durationHint = duration.isFinite && duration > 0
            ? duration
            : (currentSelectedVersion?.duration ?? 0)
        var renewal = lastLoadRequest.copyForRecovery(
            preferredFileId: currentSelectedVersion?.fileId ?? lastLoadRequest.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            offlineDownloadId: nil,
            serverSubtitlesDisabled: hasDisabledServerSubtitlesForResume
        )
        renewal.keepsAutomaticSubtitles = !hasExplicitSubtitleChoice
        let renewalRequest = renewal

        Self.logger.warning(
            "Renewing stale playback session \(staleSessionId, privacy: .public) reason=\(reason, privacy: .public) position=\(resumePosition, privacy: .public)"
        )

        staleSessionRecoveryTask?.cancel()
        staleSessionRecoveryTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            // Silo ignores position 0 in session reports; a forced overwrite
            // would store it and clear the saved resume point.
            if self.progressIsEligible, resumePosition > 0 {
                _ = await self.sessionBridge.syncProgress(
                    contentId: contentId,
                    position: resumePosition,
                    duration: durationHint,
                    forceOverwrite: true
                )
            }
            guard !Task.isCancelled, !self.isDisposed else { return }

            self.progressTask?.cancel()
            self.beginFreshLoad(
                request: renewalRequest,
                progressPosition: nil,
                resumePositionOverride: resumePosition,
                allowNearEndResume: true,
                origin: .recovery
            )
        }
        return true
    }

    func isPlaybackSessionMissingMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("playback_session_not_found")
            || lowered.contains("playback session not found")
    }

    /// A signed playback URL can come back as a bare 404 once its session has
    /// gone. That's renewed once at the current position before it counts as
    /// a missing file.
    ///
    /// Typed on purpose, not a search of the message for "404": only
    /// `sourceRefused` names the session's own source request, and only with
    /// no `underlyingDomain` is `underlyingCode` the origin's HTTP status. A
    /// text match tore down live sessions over a sidecar or segment 404, and
    /// never matched at all on a device in another language.
    func isExpiredPlaybackSessionSource(_ failure: PlaybackErrorInfo?) -> Bool {
        guard let failure,
              failure.kind == .sourceRefused,
              failure.underlyingDomain == nil,
              failure.underlyingCode == 404 else {
            return false
        }
        // Nothing to renew without a server session.
        return activePlaybackSessionId != nil
    }

    // MARK: Published state

    /// Resets everything the screens read about the current item, ready for
    /// a new load. A replan keeps this state (the HUD stays open through it);
    /// a new load closes the HUD and clears Next Up unless a Next Up hand-off
    /// is running.
    ///
    /// The `preferred*` indexes are the request's track picks, held until the
    /// engine lists its tracks. A subtitle index of -1 means Off.
    func resetPublishedLoadState(
        preferredAudioTrackIndex: Int?,
        preferredSubtitleTrackIndex: Int?,
        preferredSidecarSubtitleTrackId: Int64?,
        preferredProtocolV3SubtitleIndex: Int? = nil
    ) {
        isLoadingSubtitles = false
        isLoading = true
        error = nil
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        remoteDismissTask?.cancel()
        remoteDismissTask = nil
        activeNotice = nil
        remoteDismissToken = nil
        hideControlsTask?.cancel()
        nextUpPrefetchPending = false
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        seekFilterTimeoutTask?.cancel()
        seekFilterTimeoutTask = nil
        tearDownHoldSeek()
        isScrubbing = false
        scrubPreviewTime = currentTime
        scrubPreviewProvider.endInteraction()
        scrubPreviewImage = nil
        scrubPreviewImageSourceTime = nil
        seekOriginTime = nil
        seekTargetTime = nil
        setControlsVisible(false, cause: .newLoad)
        // The HUD describes the outgoing item, and on Apple TV the controls
        // host stays mounted through loading while this is set.
        isHUDPresented = false
        #if os(iOS)
        touchControlsPinned = false
        touchControlPressed = false
        #endif
        showNextUpScreen = isNextUpTransitioning
        if !isNextUpTransitioning {
            nextUpEpisode = nil
            nextUpOnDeckItems = []
        }
        isLoadingNextUpEpisode = false
        isLoadingNextUpOnDeck = false
        nextUpLookupError = nil
        nextUpStartError = nil
        nextUpCountdownSeconds = nil
        nextUpCountdownTotalSeconds = Self.nextUpCountdownDefaultSeconds
        nextUpScreenVideoEnded = false
        nextUpPresentationSource = .automatic
        nextUpAutoplayCancelled = false
        nextUpPromptDismissed = false
        nextUpCreditsDismissed = false
        audioTracks = []
        subtitleTracks = []
        chapters = []
        loadedIntroDBSegments = nil
        introRange = nil
        recapRange = nil
        creditsRange = nil
        introDBLookupTask?.cancel()
        introDBLookupTask = nil
        cancelPendingIntroAutoSkip()
        qualityOptions = [ApplePlaybackQuality.auto]
        activeQualityId = ApplePlaybackQuality.autoId
        activeBandwidthCap = .savedSetting
        isQualitySwitching = false
        qualitySwitchError = nil
        currentWatchDetail = nil
        currentSelectedVersion = nil
        activePreparedProtocolV3 = nil
        autoSkippedIntroKey = nil
        autoSkippedCreditsKey = nil
        autoSkipIntroCancelledKey = nil
        selectedAudioId = nil
        selectedSubtitleId = nil
        selectedSecondarySubtitleId = nil
        bufferedAheadSeconds = 0
        playbackReadAheadSeconds = nil
        cancelPlaybackStatsRefresh()
        playbackStatsCadence.reset()
        playbackStatsEpoch = nil
        playbackStats = .empty
        pendingServerRenderedSubtitleTrackId = nil
        serverTranscodeSubtitles = nil
        serverBurnInRows = []
        pendingAudioFfIndex = preferredAudioTrackIndex
        pendingSubtitleFfIndex = preferredSubtitleTrackIndex
        pendingSidecarSubtitleTrackId = preferredSidecarSubtitleTrackId
        hasExplicitSubtitleChoice = preferredSubtitleTrackIndex != nil
            || preferredSidecarSubtitleTrackId != nil
            || preferredProtocolV3SubtitleIndex != nil
        audioPickedForCurrentItem = false
        loadAudioOrdinal = nil
        prefsForCurrentItem = nil
        prefsResolvedForCurrentItem = false
    }

    // MARK: Reload intent

    /// The catalogue ordinal of the audio playing now, for a reload of the
    /// same item. A transcode can carry fewer audio tracks than the file, so
    /// its engine ordinal 0 isn't the file's first track; then the load's own
    /// audio is what's playing, as nothing else could be picked.
    func resolvedAudioTrackIndexForResume() -> Int? {
        if let ordinal = engineCatalogAudioOrdinal { return ordinal }
        // An older download's manifest lists no audio, so there's nothing for
        // the engine's tracks to line up with: its own ordinal stands.
        if (currentSelectedVersion?.audioTracks ?? []).isEmpty,
           let selected = audioTracks.first(where: { $0.trackId == selectedAudioId }),
           let ordinal = audioSelectionIndex(for: selected) {
            return ordinal
        }
        return activePreparedProtocolV3?.plan.selectedTracks.audio?.index
            ?? loadAudioOrdinal
            ?? lastLoadRequest?.preferredAudioTrackIndex
    }

    func subtitleUsesMovieTimeline(_ trackID: Int64?, slot: SubtitleSlot = .primary) -> Bool {
        vividPlaybackController.subtitleUsesMovieTimeline(appTrackID: trackID, slot: slot)
    }

    /// The embedded stream index of a subtitle a Silo plan renders from the
    /// file, when the selected picker row is that plan entry.
    static func selectedEmbeddedSubtitleIndexForResume(plan: PlaybackV3Plan?, selectedTrackID: Int64?) -> Int? {
        guard let plan,
              plan.subtitle.mode == PlaybackProtocolV3.SubtitleMode.render,
              let embedded = plan.subtitle.embedded,
              let selected = plan.selectedSubtitleInventoryItem,
              selectedTrackID == SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: selected.combinedIndex) else {
            return nil
        }
        return embedded.streamIndex
    }

    /// Whether the viewer turned subtitles off for this item. Before the
    /// engine lists its tracks, no selection can still mean a requested track
    /// that hasn't been found yet, so a pending pick isn't Off.
    static func serverSubtitlesDisabledForResume(
        selectedTrackID: Int64?, hasExplicitChoice: Bool,
        pendingEmbeddedIndex: Int?, pendingSidecarID: Int64?,
        pendingServerRenderedID: Int64? = nil
    ) -> Bool {
        hasExplicitChoice && selectedTrackID == nil
            && pendingSidecarID == nil && pendingServerRenderedID == nil
            && (pendingEmbeddedIndex ?? -1) < 0
    }

    var hasDisabledServerSubtitlesForResume: Bool {
        Self.serverSubtitlesDisabledForResume(
            selectedTrackID: selectedSubtitleId, hasExplicitChoice: hasExplicitSubtitleChoice,
            pendingEmbeddedIndex: pendingSubtitleFfIndex, pendingSidecarID: pendingSidecarSubtitleTrackId,
            pendingServerRenderedID: pendingServerRenderedSubtitleTrackId
        )
    }

    /// The embedded subtitle stream a reload asks for: an index, -1 for none
    /// (Off, or a subtitle file that's re-applied another way), or nil when
    /// nothing is known yet.
    func resolvedSubtitleTrackIndexForResume() -> Int? {
        if hasDisabledServerSubtitlesForResume { return -1 }
        if let index = Self.selectedEmbeddedSubtitleIndexForResume(
            plan: activePreparedProtocolV3?.plan, selectedTrackID: selectedSubtitleId
        ) {
            return index
        }
        // The ID space decides, not the row's metadata: a Silo picker row is
        // published in the sidecar space and carries its FFmpeg index only so
        // an embedded pick can be saved. Restoring it as an embedded index
        // would arm both identities for the same subtitle.
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            // A Silo subtitle file picked on this device stays local; it's
            // re-applied after the reload rather than sent to Silo.
            if lazySubtitleSidecars[selectedSubtitleId] != nil { return -1 }
            // Emby and Jellyfin mount their subtitle files again with each
            // session, so the server stream index finds the same file.
            if activePreparedProtocolV3 == nil {
                return SubtitleTrackIdSpace.sidecarIndex(from: selectedSubtitleId)
            }
            // Silo sidecars are re-applied locally once the new session lists
            // its files; embedded subtitles stay off until then.
            return -1
        }
        if let selectedSubtitleId,
           let selected = subtitleTracks.first(where: { $0.trackId == selectedSubtitleId }),
           let ffIndex = selected.ffIndex {
            return ffIndex
        }
        if !subtitleTracks.isEmpty || lastLoadRequest?.preferredSubtitleTrackIndex == -1 {
            return -1
        }
        return lastLoadRequest?.preferredSubtitleTrackIndex
    }

    /// The subtitle a Silo replan asks for: always none, because Vivid picks
    /// and draws subtitles itself.
    func resolvedProtocolV3SubtitleIndexForResume() -> Int? {
        -1
    }

    /// The sidecar subtitle a reload re-applies, if any.
    func resolvedSidecarSubtitleTrackIdForResume() -> Int64? {
        if hasDisabledServerSubtitlesForResume { return nil }
        // A Silo subtitle file picked on this device is never sent to Silo;
        // `loadVivid` re-applies it locally.
        if let selectedSubtitleId, lazySubtitleSidecars[selectedSubtitleId] != nil { return nil }
        if Self.selectedEmbeddedSubtitleIndexForResume(
            plan: activePreparedProtocolV3?.plan, selectedTrackID: selectedSubtitleId
        ) != nil { return nil }
        // A burn-in row has no file of its own; its stream index carries it.
        if isServerBurnInRow(selectedSubtitleId) { return nil }
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            return selectedSubtitleId
        }
        return lastLoadRequest?.preferredSidecarSubtitleTrackId
    }

    /// Takes a Silo plan's tracks as the item's reload intent, so renewals
    /// and replans repeat what the server is rendering.
    func adoptProtocolV3RenewalIntent(from prepared: PreparedPlayback) {
        guard let protocolV3 = prepared.protocolV3,
              let lastLoadRequest,
              lastLoadRequest.offlineDownloadId == nil else {
            return
        }
        let adopted = lastLoadRequest.adoptingProtocolV3Intent(
            plan: protocolV3.plan,
            selectedVersion: prepared.selectedVersion,
            activeQualityId: prepared.activeQualityId,
            bandwidthCap: prepared.bandwidthCap
        )
        self.lastLoadRequest = adopted

        // The plan says which tracks are actually rendered. Arm it before the
        // new source lists its tracks, so container defaults and Auto can't
        // drift from what the server keeps through replans and renewals.
        let intent = Self.protocolV3PendingTrackIntent(plan: protocolV3.plan, request: adopted)
        pendingAudioFfIndex = intent.audioIndex
        // Subtitle selection belongs to the local decoder.
        pendingSidecarSubtitleTrackId = nil
        pendingServerRenderedSubtitleTrackId = nil

        // Adopting the server's plan doesn't turn an automatic choice into a
        // viewer's pick. A pick stays latched; an automatic choice can still
        // follow later policy changes.
        if hasExplicitSubtitleChoice {
            prefsForCurrentItem = nil
            prefsResolvedForCurrentItem = true
        }
    }

    // MARK: Stream requests

    /// The request the engine opens a session's stream with. Emby and
    /// Jellyfin build their own; Silo's resolves the plan's URL against the
    /// current server with the account's credentials, plus the profile
    /// headers on Silo's v2 API (refused when the signed-in account belongs to
    /// another server). A download's `file://` URL passes straight through.
    func makeStreamRequest(
        session: PlaybackSessionResponse,
        additionalHeaders: [String: String] = [:],
        requiresHeaderAuthenticatedMedia: Bool = false,
        allowsAuthorizedMediaOrigins: Bool = false,
        nativeApiMajor: Int? = nil
    ) async -> StreamRequest? {
        if MediaServerProvider.active == .jellyfin, !session.streamUrl.hasPrefix("file://") {
            return await sessionBridge.jellyfinStreamRequest(sessionID: session.sessionId)
        }
        if MediaServerProvider.active == .emby, !session.streamUrl.hasPrefix("file://") {
            return await sessionBridge.embyStreamRequest(sessionID: session.sessionId)
        }
        let serverUrl = await VividAPI.shared.currentServerUrl()
        let auth = await TokenStore.shared.captureOrdinaryRequestAuth()
        var headers = additionalHeaders
        if nativeApiMajor == 2 {
            guard let accountServerURL = auth?.account.serverURL,
                  ServerRegistry.normalize(url: accountServerURL) == ServerRegistry.normalize(url: serverUrl) else {
                return nil
            }
            headers["X-Profile-Id"] = auth?.profileId
            headers["X-Profile-Token"] = auth?.profileToken
        }
        return StreamRequest.resolve(
            rawURL: session.streamUrl,
            serverURL: serverUrl,
            additionalHeaders: headers,
            accessToken: auth?.accessToken,
            requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
            // The caller knows the attempt's session, so a proxy URL naming
            // another one is refused rather than trusted.
            authorizedMediaOriginSessionId: allowsAuthorizedMediaOrigins ? session.sessionId : nil,
            nativeApiMajor: nativeApiMajor
        )
    }

    /// The stream request for a freshly prepared item or replan, with the
    /// plan's headers and the features its attempt negotiated.
    func makeStreamRequest(for prepared: PreparedPlayback) async -> StreamRequest? {
        let protocolV3 = prepared.protocolV3
        return await makeStreamRequest(
            session: prepared.session,
            additionalHeaders: protocolV3?.plan.stream.headers ?? [:],
            requiresHeaderAuthenticatedMedia: protocolV3?.serverFeatures.contains(
                PlaybackProtocolV3.headerAuthenticatedMediaFeature
            ) == true,
            allowsAuthorizedMediaOrigins: protocolV3?.negotiatedAuthorizedMediaOrigins == true,
            nativeApiMajor: protocolV3?.plan.nativeApiMajor
        )
    }

    /// The quality menu for a prepared item: the provider's own options, or
    /// Silo's available qualities.
    static func playbackQualityOptions(for prepared: PreparedPlayback) -> [ApplePlaybackQualityOption] {
        prepared.nativeQualityOptions ?? ApplePlaybackQuality.playbackOptions(
            serverQualities: prepared.protocolV3?.plan.availableQualities ?? [],
            fallbackVersion: prepared.selectedVersion
        )
    }

    /// A stable reason for the diagnostics breadcrumb, read from the message.
    private func stablePlaybackFailureToken(for message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("timed out") || lowered.contains("timeout") { return "timeout" }
        if lowered.contains("404") || lowered.contains("not found") { return "not_found" }
        if lowered.contains("401") || lowered.contains("403") || lowered.contains("unauthorized") || lowered.contains("forbidden") {
            return "auth"
        }
        if lowered.contains("cancel") { return "cancelled" }
        if lowered.contains("decode") { return "decode" }
        if lowered.contains("remux") || lowered.contains("mux") { return "remux" }
        if lowered.contains("network") || lowered.contains("connection") { return "network" }
        return "playback_error"
    }
}
