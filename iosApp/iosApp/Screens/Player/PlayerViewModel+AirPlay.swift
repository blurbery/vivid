#if os(iOS)
import AVFoundation
import Foundation
import OSLog

/// Handing a title to an AirPlay video receiver on iPhone and iPad.
///
/// `VividPlaybackController` runs the probe, the receiver's player and the
/// hand-off rules. The player feeds it the output route and whether the load
/// could be handed off, and does what needs the server session: preparing
/// and committing receiver sessions and bringing Lucid back with a fresh
/// load.
extension PlayerViewModel {
    /// Where receiver streams come from: this player, through its session
    /// bridge, for a server load that can offer one. Nil leaves AirPlay to
    /// Lucid's audio. A Silo receiver needs the v2 delivery routes, which
    /// take a signed stream reference without headers; the bridge also
    /// checks the server address before it prepares one.
    var airPlayReceiverStreamSource: (any AirPlayReceiverStreamSource)? {
        if let plan = activePreparedProtocolV3?.plan, plan.nativeApiMajor != 2 { return nil }
        return self
    }

    /// Whether this load could be handed to a receiver at all: a settled
    /// video load from a server on Lucid's own route. A download or local
    /// file never is (the receiver can't fetch a file on the phone), and
    /// neither is a native engine route. This is when the AirPlay button
    /// shows.
    var airPlayHandOffSupportedForLoad: Bool {
        guard !isDisposed, airPlayReceiverStreamSource != nil,
              hasActiveVividSession, !isAudioOnlyVividLoad,
              offlinePlaybackContext == nil, lastLoadRequest?.offlineDownloadId == nil,
              vividEngine.videoRoute == .sampleBuffer,
              let epoch = activeVividLoadEpoch, startedVividLoadEpoch == epoch else { return false }
        // A Silo load hands off once its plan has committed.
        return activePreparedProtocolV3 == nil || committedProtocolV3LoadEpoch == epoch
    }

    /// A supported load that nothing else is reshaping right now: on screen
    /// rather than in Picture in Picture, with no replan, error, end screen
    /// or Next Up over it.
    var canStartAirPlayHandOff: Bool {
        airPlayHandOffSupportedForLoad
            && protocolV3ReplanTask == nil && error == nil
            && !hasReachedEndOfFile && !showNextUpScreen
            && !PictureInPictureCoordinator.shared.isEngaged
            && !vividEngine.pictureInPictureActive
    }

    /// Tells the controller what the output route is now, and whether the
    /// AirPlay button belongs on screen. Runs on every route change, once
    /// each load has settled (which covers opening the player, or reaching
    /// the next episode, with AirPlay already chosen), and when Picture in
    /// Picture or Next Up gets out of the way.
    func evaluateAirPlayRoute() {
        guard !isDisposed else { return }
        vividPlaybackController.setAirPlayHandOffAvailable(airPlayHandOffSupportedForLoad)
        vividPlaybackController.airPlayRouteChanged(
            routeID: Self.airPlayRouteID(),
            canHandOff: canStartAirPlayHandOff
        )
    }

    /// The AirPlay route picker closed. Picking the receiver that was
    /// already chosen sends no route change, so the route is checked again
    /// here, which lets a receiver that fell back be tried once more.
    func airPlayRoutePickerClosed() {
        guard !isDisposed else { return }
        vividPlaybackController.airPlayRoutePickerClosed()
        evaluateAirPlayRoute()
    }

    /// Picture in Picture started or stopped: the AirPlay button and a
    /// receiver picked meanwhile get their check.
    func pictureInPictureEngagementChanged() {
        guard !isDisposed else { return }
        vividPlaybackController.refreshExternalPlaybackStatus()
        evaluateAirPlayRoute()
    }

    /// New tracks or quality while a receiver plays: it gets a new stream at
    /// the current position, on the same player, so the receiver stays. A
    /// commit still out makes it wait until that lands. Returns false when
    /// no hand-off took the change, so it's Lucid's.
    @discardableResult
    func restartAirPlayReceiverIfHandedOff() -> Bool {
        guard vividPlaybackController.isAirPlayHandOffEngaged else { return false }
        return vividPlaybackController.restartAirPlayReceiverStream()
    }

    /// The AirPlay outputs in the current route, or nil for a local route.
    /// Only compared, never logged.
    static func airPlayRouteID() -> String? {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .filter { $0.portType == .airPlay }
            .map(\.uid)
            .sorted()
        return outputs.isEmpty ? nil : outputs.joined(separator: ",")
    }

    func handleAirPlayHandOffRequest(_ request: VividPlaybackController.AirPlayHandOffRequest) {
        switch request {
        case .requestStream(let id):
            requestAirPlayReceiverStream(request: id)
        case .commitStream(let id, let stream, let position):
            commitAirPlayReceiverStream(stream, request: id, position: position)
        case .resumeLucid(let position):
            resumeLucidAfterAirPlay(at: position)
        case .releaseStream(let stream):
            Task { [sessionBridge] in await sessionBridge.abandonAirPlayReceiverSession(stream) }
        case .recheckOutputRoute:
            guard !isDisposed else { return }
            replanForOutputRouteIfNeeded()
        case .receiverStarted:
            guard !isDisposed else { return }
            Task { [sessionBridge] in await sessionBridge.reportAirPlayReceiverStarted() }
        case .retryRouteCheck:
            evaluateAirPlayRoute()
        case .restartFailed(let id):
            undoAirPlayReceiverChange(request: id)
        }
    }

    /// A change made while handed off didn't reach the receiver, which plays
    /// on with what it had: the menus go back to that, with the notice the
    /// same failure shows on the phone. A newer change still waiting has
    /// already been sent instead of this.
    private func undoAirPlayReceiverChange(request: Int) {
        let change = airPlayRequestSelections.removeValue(forKey: request)?.change ?? airPlayChangeKind
        guard !isDisposed else { return }
        airPlayReceiverSelection?.restore(on: self)
        switch change {
        case .audio:
            showNotice(
                title: String(localized: "Couldn't change audio"),
                message: String(localized: "The audio track couldn't be switched. The previous track was kept."),
                tone: .warning,
                duration: 5
            )
        case .subtitle:
            showNotice(
                title: String(localized: "Couldn't show subtitles"),
                message: String(localized: "Couldn't load the selected subtitles. Try again, or go back and choose other subtitles or turn them off."),
                tone: .warning,
                duration: 6
            )
        case .quality:
            qualitySwitchError = String(localized: "Couldn't change quality right now. Try again.")
        case .seek:
            showNotice(
                title: String(localized: "Couldn't seek"),
                message: String(localized: "Playback couldn't move to that position. Try again."),
                tone: .warning,
                duration: 5
            )
        }
    }

    /// Whether a receiver session that couldn't be had is worth trying again
    /// shortly: no network, a timeout, a busy or failing server, or a moment
    /// with no live session. A refusal or an unsupported plan, format or
    /// server isn't.
    nonisolated static func isTemporaryAirPlayFailure(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError { return true }
        if let failure = error as? PlaybackV3TerminalFailure { return failure.retryable }
        let status: Int
        if let http = error as? HTTPError {
            switch http {
            case .network: return true
            case .http(let code, _): status = code
            default: return false
            }
        } else if let api = error as? APIError, case .httpError(let code) = api {
            status = code
        } else {
            return false
        }
        return status == 408 || status == 429 || (500...599).contains(status)
    }

    /// Prepares a receiver session for the load on screen, which keeps
    /// playing on its own session meanwhile. A load still finishing (its
    /// native start report, its Silo commit) is waited for, so the receiver
    /// session follows the session that's really current. The answer always
    /// goes back to the controller, even after the player has gone, so a
    /// session that arrives late is released.
    private func requestAirPlayReceiverStream(request: Int) {
        let restarting = vividPlaybackController.isAirPlayHandOffEngaged
        guard !isDisposed, let source = airPlayReceiverStreamSource else {
            vividPlaybackController.airPlayStreamFailed(request: request)
            return
        }
        guard restarting || canStartAirPlayHandOff else {
            vividPlaybackController.airPlayHandOffBlocked(request: request)
            return
        }
        let epoch = activeVividLoadEpoch
        // The receiver shows the viewer's own subtitles, never a replay's.
        endReplaySubtitles(restoringSelection: true, reason: "airplay")
        airPlayRequestSelections[request] = (AirPlayReceiverSelection(of: self), restarting ? airPlayChangeKind : .seek)
        Task { @MainActor [weak self] in
            await self?.freshLoadTask?.value
            guard let self else { return }
            guard self.isAirPlayRequestStillWanted(epoch: epoch, restarting: restarting) else {
                if !restarting { self.airPlayRequestSelections[request] = nil }
                if restarting || self.isDisposed {
                    self.vividPlaybackController.airPlayStreamFailed(request: request)
                } else {
                    self.vividPlaybackController.airPlayHandOffBlocked(request: request)
                }
                return
            }
            do {
                let stream = try await source.prepareAirPlayReceiverSession(position: self.currentTime)
                // Picture in Picture, Next Up or an error may have arrived
                // during the wait: the stream is let go and the route tried
                // again once that clears.
                if !restarting, !self.isDisposed,
                   !self.isAirPlayRequestStillWanted(epoch: epoch, restarting: false) {
                    await source.releaseAirPlayReceiverSession(stream)
                    self.airPlayRequestSelections[request] = nil
                    self.vividPlaybackController.airPlayHandOffBlocked(request: request)
                    return
                }
                // Otherwise answered whatever happened meanwhile: a stream the
                // controller no longer wants comes straight back as a release.
                self.vividPlaybackController.airPlayStreamArrived(
                    stream,
                    request: request,
                    lucidPosition: self.currentTime
                )
            } catch {
                Self.logger.error(
                    "AirPlay receiver stream unavailable: \(AirPlayVideoHandOff.describe(error), privacy: .public)"
                )
                if !restarting { self.airPlayRequestSelections[request] = nil }
                if !restarting, Self.isTemporaryAirPlayFailure(error) {
                    self.vividPlaybackController.airPlayStreamUnavailable(request: request)
                } else {
                    self.vividPlaybackController.airPlayStreamFailed(request: request)
                }
            }
        }
    }

    private func isAirPlayRequestStillWanted(epoch: VividPlaybackController.LoadEpoch?, restarting: Bool) -> Bool {
        guard !isDisposed, activeVividLoadEpoch == epoch else { return false }
        return restarting ? vividPlaybackController.isAirPlayHandOffEngaged : canStartAirPlayHandOff
    }

    /// Lucid is already paused and muted, so retiring its session now can't
    /// start a recovery on it. A Silo receiver's realtime commands follow its
    /// session.
    private func commitAirPlayReceiverStream(_ stream: AirPlayReceiverStream, request: Int, position: Double) {
        let isSilo = activePreparedProtocolV3 != nil
        Task { @MainActor [weak self, sessionBridge] in
            let result = await sessionBridge.commitAirPlayReceiverSession(stream, position: position)
            guard let self else { return }
            let prepared = self.airPlayRequestSelections.removeValue(forKey: request)
            if result == .committed, self.vividPlaybackController.isAirPlayHandOffEngaged {
                // The receiver now plays what this request was prepared with.
                if let prepared { self.airPlayReceiverSelection = prepared.selection }
                if isSilo, !self.isDisposed, let sessionId = stream.serverSessionId {
                    self.airPlayReceiverSessionId = sessionId
                    await self.realtimeClient.bind(sessionId: sessionId)
                }
            }
            self.vividPlaybackController.airPlayCommitFinished(request: request, result: result)
        }
    }

    /// Lucid takes the title back where the receiver left it. The receiver
    /// session replaced the phone's server session, so this is a fresh load
    /// (the same one Retry and a quality change use), which stops the
    /// receiver session and starts a normal one with the tracks and quality
    /// in use. Play or pause is the viewer's last choice.
    private func resumeLucidAfterAirPlay(at position: Double) {
        guard !isDisposed, let last = lastLoadRequest, last.offlineDownloadId == nil else { return }
        let target = position.isFinite ? max(0, position) : currentTime
        currentTime = target
        var request = last.copyForRecovery(
            preferredFileId: currentSelectedVersion?.fileId ?? last.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            offlineDownloadId: nil,
            serverSubtitlesDisabled: hasDisabledServerSubtitlesForResume
        )
        request.keepsAutomaticSubtitles = !hasExplicitSubtitleChoice
        beginFreshLoad(
            request: request,
            progressPosition: target,
            finalizeCurrentSession: true,
            resumePositionOverride: target,
            allowNearEndResume: true,
            origin: .recovery
        )
    }
}

extension PlayerViewModel: AirPlayReceiverStreamSource {
    /// Prepares the receiver session through the bridge for the title,
    /// version, tracks and quality on screen. A subtitle drawn only on the
    /// phone (a downloaded or OpenSubtitles file) can't reach the receiver
    /// and is left off.
    func prepareAirPlayReceiverSession(position: Double) async throws -> AirPlayReceiverStream {
        guard let detail = currentWatchDetail, let version = currentSelectedVersion else {
            throw CancellationError()
        }
        let qualityOverride = lastLoadRequest?.preferredQualityOverride
        return try await sessionBridge.prepareAirPlayReceiverSession(
            detail: detail,
            version: version,
            audioOrdinal: resolvedAudioTrackIndexForResume(),
            subtitleStreamIndex: resolvedSubtitleTrackIndexForResume(),
            qualityId: qualityOverride.map { ApplePlaybackQuality.protocolV3QualityId($0) },
            bitrateKbps: AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: qualityOverride,
                carriedCap: lastLoadRequest?.carriedBandwidthCap,
                fallbackBitrateKbps: settings.maxBitrateKbps
            ),
            position: position
        )
    }

    func releaseAirPlayReceiverSession(_ stream: AirPlayReceiverStream) async {
        await sessionBridge.abandonAirPlayReceiverSession(stream)
    }
}

/// The kind of change a receiver restart was for, which picks the notice if
/// it fails.
enum AirPlayReceiverChange {
    case audio, subtitle, quality, seek
}

/// The track and quality choices a receiver stream was prepared with.
struct AirPlayReceiverSelection {
    let selectedAudioId: Int64?
    let audioPickedForCurrentItem: Bool
    let selectedSubtitleId: Int64?
    let pendingSubtitleFfIndex: Int?
    let pendingSidecarSubtitleTrackId: Int64?
    let hasExplicitSubtitleChoice: Bool
    let activeQualityId: String
    let playbackFallbackMode: PlaybackFallbackMode?
    let preferredQualityOverride: String?
    let carriedBandwidthCap: CarriedBandwidthCap?

    @MainActor
    init(of player: PlayerViewModel) {
        selectedAudioId = player.selectedAudioId
        audioPickedForCurrentItem = player.audioPickedForCurrentItem
        selectedSubtitleId = player.selectedSubtitleId
        pendingSubtitleFfIndex = player.pendingSubtitleFfIndex
        pendingSidecarSubtitleTrackId = player.pendingSidecarSubtitleTrackId
        hasExplicitSubtitleChoice = player.hasExplicitSubtitleChoice
        activeQualityId = player.activeQualityId
        playbackFallbackMode = player.playbackFallbackMode
        preferredQualityOverride = player.lastLoadRequest?.preferredQualityOverride
        carriedBandwidthCap = player.lastLoadRequest?.carriedBandwidthCap
    }

    /// Puts these choices back in the menus, and in the request Lucid
    /// reloads with when it takes the title back.
    @MainActor
    func restore(on player: PlayerViewModel) {
        player.selectedAudioId = selectedAudioId
        player.audioPickedForCurrentItem = audioPickedForCurrentItem
        player.selectedSubtitleId = selectedSubtitleId
        player.pendingSubtitleFfIndex = pendingSubtitleFfIndex
        player.pendingSidecarSubtitleTrackId = pendingSidecarSubtitleTrackId
        player.hasExplicitSubtitleChoice = hasExplicitSubtitleChoice
        player.activeQualityId = activeQualityId
        player.playbackFallbackMode = playbackFallbackMode
        player.lastLoadRequest?.preferredQualityOverride = preferredQualityOverride
        player.lastLoadRequest?.carriedBandwidthCap = carriedBandwidthCap
    }
}
#endif
