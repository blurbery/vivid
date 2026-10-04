import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

extension PlayerViewModel {
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
        showControls = false
        // The HUD belongs to the outgoing item. Replans deliberately bypass
        // this reset so the HUD survives them; a replacement load must close
        // it, both because its content is stale and because the tvOS controls
        // host stays mounted through `isLoading` whenever this flag is up.
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
        // Subtitle `-1` is the explicit "Off" sentinel; Vivid inventory
        // adoption disables subtitles when it sees a negative value.
        pendingAudioFfIndex = preferredAudioTrackIndex
        pendingSubtitleFfIndex = preferredSubtitleTrackIndex
        pendingSidecarSubtitleTrackId = preferredSidecarSubtitleTrackId
        hasExplicitSubtitleChoice =
            preferredSubtitleTrackIndex != nil
            || preferredSidecarSubtitleTrackId != nil
            || preferredProtocolV3SubtitleIndex != nil
        prefsForCurrentItem = nil
        prefsResolvedForCurrentItem = false
    }

    func resolvedAudioTrackIndexForResume() -> Int? {
        guard let selectedAudioId,
              let selected = audioTracks.first(where: { $0.trackId == selectedAudioId }),
              let selectionIndex = audioSelectionIndex(for: selected) else {
            return lastLoadRequest?.preferredAudioTrackIndex
        }
        return selectionIndex
    }

    func subtitleUsesMovieTimeline(_ trackID: Int64?, slot: SubtitleSlot = .primary) -> Bool {
        vividPlaybackController.subtitleUsesMovieTimeline(appTrackID: trackID, slot: slot)
    }

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

    static func serverSubtitlesDisabledForResume(
        selectedTrackID: Int64?, hasExplicitChoice: Bool,
        pendingEmbeddedIndex: Int?, pendingSidecarID: Int64?,
        pendingServerRenderedID: Int64? = nil
    ) -> Bool {
        // Before inventory arrives, nil can mean an unresolved requested track.
        return hasExplicitChoice && selectedTrackID == nil
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

    func resolvedSubtitleTrackIndexForResume() -> Int? {
        if hasDisabledServerSubtitlesForResume { return -1 }
        if let index = Self.selectedEmbeddedSubtitleIndexForResume(
            plan: activePreparedProtocolV3?.plan, selectedTrackID: selectedSubtitleId
        ) {
            return index
        }
        // The id space decides, not the row's metadata: a V3 picker row is
        // published in the sidecar space and carries its FFmpeg index only so
        // an embedded pick can be persisted. Restoring it as an embedded index
        // would arm both identities for the same subtitle.
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            // Sidecars are re-applied client-side after the playback
            // session returns `subtitle_urls`; keep embedded subtitles off
            // until that explicit sidecar selection is restored.
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

    func resolvedProtocolV3SubtitleIndexForResume() -> Int? {
        -1
    }

    func resolvedSidecarSubtitleTrackIdForResume() -> Int64? {
        if hasDisabledServerSubtitlesForResume { return nil }
        if Self.selectedEmbeddedSubtitleIndexForResume(
            plan: activePreparedProtocolV3?.plan, selectedTrackID: selectedSubtitleId
        ) != nil { return nil }
        if let selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
            return selectedSubtitleId
        }
        return lastLoadRequest?.preferredSidecarSubtitleTrackId
    }

    func adoptProtocolV3RenewalIntent(from prepared: PreparedPlayback) {
        guard let protocolV3 = prepared.protocolV3,
              let lastLoadRequest,
              lastLoadRequest.offlineDownloadId == nil else {
            return
        }
        let adopted = lastLoadRequest.adoptingProtocolV3Intent(
            plan: protocolV3.plan,
            selectedVersion: prepared.selectedVersion,
            activeQualityId: prepared.activeQualityId
        )
        self.lastLoadRequest = adopted

        armAdoptedProtocolV3TrackIntent(
            plan: protocolV3.plan,
            request: adopted
        )

        // Adopting an authoritative server plan does not convert an automatic
        // system/server policy into a user choice. Manual choices stay latched;
        // automatic choices remain eligible for later policy changes.
        if hasExplicitSubtitleChoice {
            prefsForCurrentItem = nil
            prefsResolvedForCurrentItem = true
        }
    }

    private func armAdoptedProtocolV3TrackIntent(
        plan: PlaybackV3Plan,
        request: LoadRequest
    ) {
        // The V3 plan is authoritative for the tracks actually rendered.
        // Apply it before the new source publishes a track list so container
        // defaults and the post-open Auto resolver cannot drift away from the
        // selection the server will preserve through replans and renewals.
        let intent = Self.protocolV3PendingTrackIntent(plan: plan, request: request)
        pendingAudioFfIndex = intent.audioIndex
        // Subtitle selection belongs to the local media decoder.
        pendingSidecarSubtitleTrackId = nil
        pendingServerRenderedSubtitleTrackId = nil
    }

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
        let currentItemCompleted = completedPlaybackContentId != nil
        recordCurrentPlaybackMutation(markedCompleted: currentItemCompleted)
        let priorProgressEligible = progressIsEligible
        let priorCompletedContentId = completedPlaybackContentId
        if lastLoadRequest?.contentId != request.contentId {
            watchTimeGate = PlaybackWatchTimeGate()
            completedPlaybackContentId = nil
        }
        watchTimeGate.interrupt()
        let pendingNaturalEndProgressTask = naturalEndProgressTask
        naturalEndProgressTask = nil
        qualityFallbackTask?.cancel()
        qualityFallbackTask = nil
        playbackFallbackGate.update(buffering: false, eligible: false,
                                    now: ProcessInfo.processInfo.systemUptime)
        if lastLoadRequest?.contentId != request.contentId {
            playbackFallbackMode = request.preferredQualityOverride.map {
                PlaybackFallbackMode(rawValue: $0)
            } ?? settings.fallbackMode
            playbackFallbackGate = PlaybackFallbackGate()
        }
        lastLoadRequest = request
        offlinePlaybackContext = nil
        contentIdsNeedingDetailRefresh.insert(request.contentId)
        hasReachedEndOfFile = false
        // Retire the outgoing load's epoch *synchronously*. The actual
        // dispose happens several awaits down, and until this is nil a late
        // `.ended` or failure from the item we're replacing still matches
        // `handleVividEvent`'s epoch filter — landing end-of-file, or a
        // terminal error, on the item that is only just starting to load.
        activeVividLoadEpoch = nil
        committedProtocolV3LoadEpoch = nil
        pendingProtocolV3FirstFrameEpoch = nil
        // The outgoing item's queued follow-ups must not be replayed against
        // the incoming one.
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

        // The prior item's timer reads bridge state at each tick. Stop it
        // before a replacement session becomes provisional or it can publish
        // the new item's reset position against an uncommitted candidate.
        progressTask?.cancel()
        progressTask = nil
        freshLoadTask?.cancel()
        protocolV3ReplanTask?.cancel()
        protocolV3ReplanTask = nil
        freshLoadGeneration &+= 1
        transientRecoveryBudget.cancel()
        transientRecoveryBudget = VividTransientRecoveryBudget()
        prematureEndRecoveryGate = VividPrematureEndRecoveryGate()
        let currentFreshLoadGeneration = freshLoadGeneration
        streamLoadGeneration &+= 1
        let currentStreamLoadGeneration = streamLoadGeneration
        let snapshotPosition = progressPosition
        // Offline loads never start a replacement server session, so the
        // prior one must be finalized here — otherwise the bridge keeps
        // holding it and a later teardown would report the offline item's
        // position against the stale session.
        let shouldFinalizeCurrentSession = finalizeCurrentSession || request.offlineDownloadId != nil
        // From here until this task exits, its catch is the only handler for
        // a load failure — see `handleVividFailure`.
        freshLoadOwnsFailureHandling = true
        freshLoadTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            var uncommittedPrepared: PreparedPlayback?
            defer {
                defer { self.recoverPendingUnexpectedEnd() }
                if self.freshLoadGeneration == currentFreshLoadGeneration {
                    self.freshLoadTask = nil
                    self.freshLoadOwnsFailureHandling = false
                }
            }

            await pendingNaturalEndProgressTask?.value
            if let snapshotPosition, snapshotPosition.isFinite, snapshotPosition >= 0 {
                if shouldFinalizeCurrentSession {
                    await self.sessionBridge.stopSession(position: snapshotPosition, isPaused: true, eligible: priorProgressEligible, completedContentId: priorCompletedContentId)
                } else {
                    await self.sessionBridge.reportProgress(position: snapshotPosition, isPaused: true, eligible: priorProgressEligible, completedContentId: priorCompletedContentId)
                }
                #if os(iOS) || os(tvOS)
                self.refreshHomeAfterPlaybackWrite?()
                #endif
            }
            guard !Task.isCancelled,
                  !self.isDisposed,
                  currentFreshLoadGeneration == self.freshLoadGeneration,
                  currentStreamLoadGeneration == self.streamLoadGeneration else { return }

            await self.realtimeClient.unbind()
            guard !Task.isCancelled,
                  !self.isDisposed,
                  currentFreshLoadGeneration == self.freshLoadGeneration,
                  currentStreamLoadGeneration == self.streamLoadGeneration else { return }

            do {
                self.disposeVividPlayback(forReplacement: true)
                guard !Task.isCancelled, !self.isDisposed else { return }

                // The init kicked off `settingsRefreshTask` to fetch the
                // server's effective device settings before playback
                // starts. Awaiting it here (instead of issuing a fresh
                // `refreshFromServer`) avoids the race that produced two
                // back-to-back `/settings/effective` round-trips on every
                // play — the init request is already in flight and its
                // result is what we want anyway. If the task already
                // finished, this returns immediately.
                await self.settingsRefreshTask?.value
                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                guard currentFreshLoadGeneration == self.freshLoadGeneration else {
                    throw CancellationError()
                }

                let prepared: PreparedPlayback
                var preparedOfflineContext: OfflinePlaybackContext?
                var preparedOfflineArtworkURL: URL?
                if let offlineDownloadId = request.offlineDownloadId {
                    // Fully local prepare from the stored record + manifest.
                    // Must keep working in airplane mode, so nothing on this
                    // branch (or downstream of it while
                    // `offlinePlaybackContext` is set) may require the server.
                    let offline = try await OfflinePlaybackBuilder.loadPreparedPlayback(
                        downloadId: offlineDownloadId,
                        startFromBeginning: request.startFromBeginning,
                        resumePositionOverride: resumePositionOverride
                    )
                    preparedOfflineContext = OfflinePlaybackContext(
                        downloadId: offline.downloadId,
                        mediaItemId: offline.mediaItemId
                    )
                    preparedOfflineArtworkURL = offline.posterFileURL
                    prepared = offline.prepared
                } else {
                    // Bound the start-session call when the load was triggered
                    // by autoplay or interruption recovery. A user-initiated load
                    // keeps the unbounded behavior — a slow manual pick is
                    // annoying but doesn't wedge the UI; a hung autoplay does
                    // (the user is stuck on a half-cross-faded Next Up screen
                    // with no obvious way out).
                    prepared = try await self.runStartSession(
                        request: request,
                        resumePosition: resumePositionOverride,
                        allowNearEndResume: allowNearEndResume,
                        timeout: origin == .userInitiated ? nil : Self.autoplayStartSessionTimeout
                    )
                }
                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                guard currentFreshLoadGeneration == self.freshLoadGeneration else {
                    throw CancellationError()
                }
                if prepared.protocolV3 != nil {
                    uncommittedPrepared = prepared
                }
                if let preparedOfflineContext {
                    self.offlinePlaybackContext = preparedOfflineContext
                }
                if let preparedOfflineArtworkURL {
                    self.nowPlaying.setArtworkURL(preparedOfflineArtworkURL)
                }

                let session = prepared.session
                self.activePlaybackSessionId = session.sessionId
                self.autoSkippedIntroKey = nil
                self.autoSkippedCreditsKey = nil
                self.autoSkipIntroCancelledKey = nil
                self.cancelPendingIntroAutoSkip()
                self.staleSessionRecoverySessionId = nil
                // Snapshot the preferred language for track-list ordering
                // unconditionally (even with an explicit choice) so the
                // displayed groups float the user's language to the top.
                self.subtitleOrderingLanguage = self.settings.subtitleMatchesSystemAppearance
                    ? self.settings.subtitleSystemSelectionPreferences.preferredLanguages.first
                    : self.settings.preferredSubtitleLanguage

                // Snapshot the server-resolved subtitle policy so the
                // track-list callback (which fires after Vivid opens media)
                // can pick the right track without another fetch. Skip
                // entirely if the caller already passed an explicit
                // subtitle index — manual override always wins.
                if !self.hasExplicitSubtitleChoice {
                    self.prefsForCurrentItem = self.settings.subtitleMatchesSystemAppearance
                        ? self.systemCaptionPrefsSnapshot()
                        : self.localSubtitlePrefsSnapshot(prepared.watchDetail)
                }

                self.title = prepared.displayTitle
                self.metadata = prepared.playerMetadata()
                self.currentWatchDetail = prepared.watchDetail
                self.currentSelectedVersion = prepared.selectedVersion
                self.activePreparedProtocolV3 = prepared.protocolV3
                self.adoptProtocolV3RenewalIntent(from: prepared)
                // Artwork and Next Up are catalog fetches; the offline path
                // already published its cached poster above and has no
                // server to resolve a next episode against.
                if request.offlineDownloadId == nil {
                    self.pushNowPlayingArtwork(contentId: prepared.watchDetail.contentId)
                    // The panel still describes the successor being loaded.
                    // Fetch its following episode only once it has a picture,
                    // otherwise the visible Play Now target can jump again.
                    if !self.isNextUpTransitioning {
                        self.loadNextUpCandidate(for: prepared.watchDetail)
                        self.loadNextUpOnDeckItems(for: prepared.watchDetail)
                    }
                }
                self.qualityOptions = prepared.nativeQualityOptions ?? ApplePlaybackQuality.playbackOptions(
                    serverQualities: prepared.protocolV3?.plan.availableQualities ?? [],
                    fallbackVersion: prepared.selectedVersion
                )
                self.activeQualityId = prepared.activeQualityId
                self.isQualitySwitching = false
                self.qualitySwitchError = nil
                self.duration = session.durationSeconds ?? prepared.selectedVersion.duration ?? 0
                self.currentTime = self.movieTime(for: session)
                self.loadVividMarkers(for: prepared.watchDetail)

                guard let streamRequest = await self.makeStreamRequest(
                    session: session,
                    additionalHeaders: prepared.protocolV3?.plan.stream.headers ?? [:],
                    requiresHeaderAuthenticatedMedia: prepared.protocolV3?.serverFeatures.contains(
                        PlaybackProtocolV3.headerAuthenticatedMediaFeature
                    ) == true,
                    allowsAuthorizedMediaOrigins:
                        prepared.protocolV3?.negotiatedAuthorizedMediaOrigins == true,
                    nativeApiMajor: prepared.protocolV3?.plan.nativeApiMajor
                ) else {
                    throw VividLoadSpec.ValidationError.invalidStreamURL(session.streamUrl)
                }
                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                guard currentFreshLoadGeneration == self.freshLoadGeneration else {
                    throw CancellationError()
                }
                self.resolvedServerUrl = streamRequest.serverUrl

                Self.logger.info("Play method: \(session.playMethod, privacy: .public)")
                // Keep the tvOS console breadcrumb useful without printing the
                // signed stream URL or any server identity.
                print("[CMP] streamPrepared engine=VividEngine playMethod=\(session.playMethod) startTime=\(session.position)")

                try await self.loadVivid(
                    prepared: prepared,
                    streamRequest: streamRequest,
                    expectedStreamLoadGeneration: currentStreamLoadGeneration,
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
                    // The realtime channel is a server websocket keyed by the
                    // committed session. Binding before Vivid accepts the
                    // candidate can leave commands attached to a rolled-back
                    // session after a failed load.
                    await self.realtimeClient.bind(sessionId: session.sessionId)
                    await self.sessionBridge.reportProtocolV3PlanExecutionStarted(prepared)
                    try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                }
            } catch is CancellationError {
                // Tear the abandoned Vivid load down before retiring its
                // session. Without this the engine keeps reading the stream
                // URL after the DELETE and spends minutes in 404 backoff.
                // Skip when a newer load already took the controller: its
                // own `beginLoad` replaced this source.
                if currentFreshLoadGeneration == self.freshLoadGeneration,
                   currentStreamLoadGeneration == self.streamLoadGeneration {
                    _ = self.disposeVividPlayback()
                }
                if let uncommittedPrepared {
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                return
            } catch let error {
                let loadFailure = self.protocolV3LoadFailureRecovery(error)
                if let uncommittedPrepared {
                    // `errorInfo` may already have been published for this
                    // epoch, but the committed-load gate prevents that event
                    // from racing us. Promote only the failed V3 identity (not
                    // execution success) and let the server choose the next
                    // bounded route rather than ending at the first open
                    // failure.
                    if loadFailure.shouldAdvanceRoute {
                        if await self.sessionBridge.promotePendingProtocolV3TransitionForRecovery(
                            uncommittedPrepared
                        ) {
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
                    }
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                guard !Task.isCancelled, !self.isDisposed else { return }
                await self.sessionBridge.stopSession(
                    position: self.currentTime,
                    isPaused: true, eligible: self.progressIsEligible, completedContentId: self.completedPlaybackContentId
                )
                Self.logger.error(
                    "Load failed: \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
                self.handleBeginFreshLoadFailure(error: error, origin: origin)
            }
        }
    }

    /// Race `sessionBridge.startSession` against an optional timeout. A nil
    /// `timeout` runs unbounded (matches the historical behavior). A non-nil
    /// timeout cancels the in-flight start when it elapses; URLSession's
    /// cancellation propagates as `CancellationError`, which we translate to
    /// `BeginFreshLoadError.startSessionTimeout` for the caller's catch block.
    /// If the surrounding `freshLoadTask` itself is cancelled (e.g. user
    /// navigated away), we propagate the cancellation unchanged.
    private func runStartSession(
        request: LoadRequest,
        resumePosition: Double?,
        allowNearEndResume: Bool,
        timeout: TimeInterval?
    ) async throws -> PreparedPlayback {
        if let timeout {
            let startTask = Task<PreparedPlayback, Error> { [sessionBridge] in
                try await sessionBridge.startSession(
                    contentId: request.contentId,
                    preferredFileId: request.preferredFileId,
                    preferredAudioTrackIndex: request.preferredAudioTrackIndex,
                    preferredSubtitleTrackIndex: -1,
                    preferredProtocolV3SubtitleIndex: -1,
                    initialSubtitlePreferences: nil,
                    startFromBeginning: request.startFromBeginning,
                    resumePosition: resumePosition,
                    allowNearEndResume: allowNearEndResume,
                    prefersLastUsedVersion: request.prefersLastUsedVersion,
                    preferredQualityOverride: request.preferredQualityOverride
                )
            }
            let timeoutTask = Task<Void, Never> { [startTask] in
                try? await Task.sleep(for: .seconds(timeout))
                startTask.cancel()
            }
            defer { timeoutTask.cancel() }

            do {
                return try await startTask.value
            } catch is CancellationError {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw BeginFreshLoadError.startSessionTimeout
            }
        } else {
            return try await self.sessionBridge.startSession(
                contentId: request.contentId,
                preferredFileId: request.preferredFileId,
                preferredAudioTrackIndex: request.preferredAudioTrackIndex,
                preferredSubtitleTrackIndex: -1,
                preferredProtocolV3SubtitleIndex: -1,
                initialSubtitlePreferences: nil,
                startFromBeginning: request.startFromBeginning,
                resumePosition: resumePosition,
                allowNearEndResume: allowNearEndResume,
                prefersLastUsedVersion: request.prefersLastUsedVersion,
                preferredQualityOverride: request.preferredQualityOverride
            )
        }
    }

    /// Routes a `beginFreshLoad` failure based on what triggered the load.
    /// User-initiated loads keep the historical full-screen error wall.
    /// Autoplay and interruption-recovery loads instead restore the Next Up
    /// postroll with `nextUpStartError` set so the user can pick something
    /// from On Deck or hit Back without the player being taken hostage by an
    /// `error` overlay.
    @MainActor
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
            let logMessage = MediaLogRedactor.sanitize(message)
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from autoplay failure: \(logMessage, privacy: .public)"
            )
            // Tear down the disposed player the same way
            // `finalizeTerminalPlaybackError` would, but DON'T set
            // `viewModel.error` — we want a recoverable surface, not a wall.
            disposeVividPlayback()
            isLoading = false
            isPlaying = false
            // Restore the postroll surface so the user can choose what to
            // do next. Drop the candidate episode so the panel renders the
            // "Finished" branch with the new `nextUpStartError` message.
            cancelNextUpFlow()
            nextUpStartError = message
            nextUpEpisode = nil
            nextUpAutoplayCancelled = true
            isLoadingNextUpEpisode = false
            showNextUpScreen = true
            nextUpScreenVideoEnded = true
            showNotice(
                title: "Couldn't start the next episode",
                message: message,
                tone: .warning,
                duration: 6
            )
        case .recovery:
            let logMessage = MediaLogRedactor.sanitize(message)
            Self.logger.warning(
                "[CMP] beginFreshLoad recovered from playback recovery failure: \(logMessage, privacy: .public)"
            )
            disposeVividPlayback()
            isLoading = false
            isPlaying = false
            showNotice(
                title: "Playback recovery failed",
                message: message,
                tone: .warning,
                duration: 6
            )
        }
    }

    func finalizeTerminalPlaybackError(_ message: String) {
        suppressNextUpForPlaybackFailure()
        #if os(iOS) || os(tvOS)
        // Terminal outcome #1 of 2 (the other is `handleEndOfFile`). Every
        // Every Vivid recovery path ends either here or in `handleEndOfFile`,
        // so a report always shows how playback finished. Emit before teardown
        // so position and plan still describe the failed session.
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
                // Shared with the bridge's session breadcrumbs so a report's
                // positions are all on the same scale and rounding.
                "position_ms": .int(failurePositionMs),
            ]
        )
        AppHealthMonitor.playbackFailed(reason: failureToken, playMethod: activeRouteLabel, positionMs: failurePositionMs)
        #endif
        // Pin the resume point before anything is torn down. The periodic
        // reporter ticks every 10s and is cancelled immediately below, so
        // without this the user resumes up to ten seconds behind where the
        // failure actually happened. Best-effort and non-blocking; issued
        // while `activePlaybackSessionId` is still live.
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

    @discardableResult
    func attemptStaleSessionRenewal(reason: String, observedPosition: Double) -> Bool {
        guard !isDisposed,
              let lastLoadRequest else {
            return false
        }

        let staleSessionId = activePlaybackSessionId ?? "unknown"
        if staleSessionRecoverySessionId == staleSessionId {
            return true
        }
        staleSessionRecoverySessionId = staleSessionId
        let resumePosition = observedPosition.isFinite
            ? max(0, observedPosition)
            : max(0, currentTime)
        let contentId = currentWatchDetail?.contentId ?? lastLoadRequest.contentId
        let durationHint = duration.isFinite && duration > 0
            ? duration
            : (currentSelectedVersion?.duration ?? 0)
        let renewalRequest = lastLoadRequest.copyForRecovery(
            preferredFileId: currentSelectedVersion?.fileId ?? lastLoadRequest.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            offlineDownloadId: nil,
            serverSubtitlesDisabled: hasDisabledServerSubtitlesForResume
        )

        Self.logger.warning(
            "Renewing stale playback session \(staleSessionId, privacy: .public) reason=\(reason, privacy: .public) position=\(resumePosition, privacy: .public)"
        )

        staleSessionRecoveryTask?.cancel()
        staleSessionRecoveryTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            if self.progressIsEligible {
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

    /// A signed playback URL can surface a bare 404 through Vivid. Renew once
    /// at the current source position before treating it as a missing file.
    ///
    /// Deliberately typed rather than a substring match on the message. Only
    /// `sourceRefused` names the *session's own* source request, and only with
    /// `underlyingDomain == nil` is `underlyingCode` the origin's HTTP status
    /// rather than some framework's error code. Matching "404" anywhere in
    /// free text used to tear down a live session over a sidecar or segment
    /// 404, and could never fire at all on a non-English device — half of
    /// Vivid's messages are `localizedDescription` forwarded from underneath.
    func isExpiredPlaybackSessionSource(_ failure: PlaybackErrorInfo?) -> Bool {
        guard let failure,
              failure.kind == .sourceRefused,
              failure.underlyingDomain == nil,
              failure.underlyingCode == 404 else {
            return false
        }
        // Nothing to renew unless we actually hold a server session.
        return activePlaybackSessionId != nil
    }

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
        beginFreshLoad(
            request: request,
            progressPosition: currentTime,
            resumePositionOverride: resumePositionOverride
        )
    }

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
        let token = auth?.accessToken
        var headers = additionalHeaders
        if nativeApiMajor == 2 {
            guard let accountServerURL = auth?.account.serverURL,
                  ServerRegistry.normalize(url: accountServerURL) == ServerRegistry.normalize(url: serverUrl) else { return nil }
            headers["X-Profile-Id"] = auth?.profileId
            headers["X-Profile-Token"] = auth?.profileToken
        }
        return StreamRequest.resolve(
            rawURL: session.streamUrl,
            serverURL: serverUrl,
            additionalHeaders: headers,
            accessToken: token,
            requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
            // The caller knows the attempt's session, so a proxy URL naming a
            // different one is rejected rather than trusted.
            authorizedMediaOriginSessionId: allowsAuthorizedMediaOrigins
                ? session.sessionId
                : nil,
            nativeApiMajor: nativeApiMajor
        )
    }

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
