import Foundation
import OSLog

/// Bitmap subtitles (PGS, VobSub, DVB) on Emby and Jellyfin transcodes.
///
/// Lucid Engine draws them itself on direct play, but an HLS transcode only
/// carries text subtitles beside it. There the file's bitmap tracks are
/// offered as picker rows, and choosing one reloads playback with the server
/// drawing that track into the video. Leaving it reloads without.
extension PlayerViewModel {
    /// Whether `trackID` is a burn-in row of the current transcode.
    func isServerBurnInRow(_ trackID: Int64?) -> Bool {
        guard let trackID else { return false }
        return serverBurnInRows.contains { $0.trackId == trackID }
    }

    /// Whether `trackID` is the row the server is drawing into the video.
    func isServerBurnedInSubtitle(_ trackID: Int64?) -> Bool {
        guard let trackID, let burned = serverTranscodeSubtitles?.burnedIndex else { return false }
        return trackID == SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: burned) && isServerBurnInRow(trackID)
    }

    /// Takes in what the server did with bitmap subtitles for a new load. A
    /// burn-in it didn't confirm is dropped for the rest of the item, and the
    /// load plays without subtitles.
    func adoptServerTranscodeSubtitles(_ prepared: PreparedPlayback) {
        serverTranscodeSubtitles = prepared.transcodeSubtitles
        serverBurnInRows = []
        guard let failed = prepared.transcodeSubtitles?.failedIndex else { return }
        failedServerBurnIns.insert(ServerBurnInFailure(
            contentId: prepared.watchDetail.contentId, fileId: prepared.selectedVersion.fileId, index: failed))
        if pendingSubtitleFfIndex == failed { pendingSubtitleFfIndex = -1 }
        showServerBurnInNotice()
    }

    /// The load's subtitle pick, if the server should draw it in. Nil once
    /// a burn-in of it has failed for this item.
    func serverBurnInCandidate(for request: LoadRequest) -> Int? {
        Self.serverBurnInCandidate(for: request, usesNativeUser: MediaServerProvider.active.usesNativeUser,
                                   failures: failedServerBurnIns)
    }

    static func serverBurnInCandidate(for request: LoadRequest, usesNativeUser: Bool,
                                      failures: Set<ServerBurnInFailure>) -> Int? {
        guard usesNativeUser, request.offlineDownloadId == nil,
              let index = request.preferredSubtitleTrackIndex, index >= 0 else { return nil }
        let failed = failures.contains {
            $0.contentId == request.contentId && $0.index == index
                && (request.preferredFileId == nil || $0.fileId == request.preferredFileId)
        }
        return failed ? nil : index
    }

    /// Rebuilds the burn-in rows for the current transcode. They're kept out
    /// of `LucidSubtitleInventory`, which lists only what the file itself
    /// plays.
    func refreshServerBurnInRows() -> [PlayerTrack] {
        guard serverTranscodeSubtitles != nil, let version = currentSelectedVersion,
              let contentId = currentWatchDetail?.contentId else {
            serverBurnInRows = []
            return []
        }
        let failed = Set(failedServerBurnIns.filter { $0.contentId == contentId && $0.fileId == version.fileId }.map(\.index))
        serverBurnInRows = ServerSubtitleBurnIn.rows(version: version, excluding: failed)
        return serverBurnInRows
    }

    /// Keeps the burned-in row selected. The engine has no track for it, so
    /// each inventory update would otherwise read the selection back as Off,
    /// and Auto would pick the row again and reload.
    func reassertServerBurnedInSubtitle(loadIsEstablished: Bool) {
        guard let burned = serverTranscodeSubtitles?.burnedIndex else { return }
        let rowID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: burned)
        guard isServerBurnInRow(rowID) else { return }
        selectedSubtitleId = rowID
        if pendingSubtitleFfIndex == burned { pendingSubtitleFfIndex = nil }
        if pendingSidecarSubtitleTrackId == rowID { pendingSidecarSubtitleTrackId = nil }
        // Nothing else is drawn on top of it.
        if loadIsEstablished, vividPlaybackController.engine.activeSubtitleTrackIndex != nil {
            vividPlaybackController.selectSubtitleTrack(id: nil)
        }
    }

    /// The tracks Auto may choose from. While the transcode only repackages
    /// the video, an automatic pick doesn't make the server encode it just
    /// for a subtitle; the rows stay available to pick by hand.
    var subtitleTracksForAutomaticPick: [PlayerTrack] {
        guard serverTranscodeSubtitles?.copiesVideo == true else { return subtitleTracks }
        return subtitleTracks.filter { !isServerBurnInRow($0.trackId) }
    }

    /// What the subtitle selected now needs from the server.
    var serverBurnInReload: ServerSubtitleBurnIn.Reload {
        guard let transcode = serverTranscodeSubtitles else { return .none }
        let wanted = serverBurnInRows.first { $0.trackId == selectedSubtitleId }?.srcId
        return ServerSubtitleBurnIn.reload(wanted: wanted, burned: transcode.burnedIndex)
    }

    /// Reloads when the subtitle now selected needs a different burn-in from
    /// the one playing. Returns true when the reload takes over.
    ///
    /// The reload waits a turn and checks again, because an automatic pick
    /// can land while `loadVivid` is still restoring an OpenSubtitles or
    /// detail-page choice, which wins.
    func reloadForServerBurnInIfNeeded(reason: String) -> Bool {
        let decision = serverBurnInReload
        guard decision != .none, lastLoadRequest?.offlineDownloadId == nil else { return false }
        if case .burnIn = decision {
            // The server draws it once reloaded; nothing local meanwhile.
            vividPlaybackController.selectSubtitleTrack(id: nil)
        }
        let generation = streamLoadGeneration
        Task { @MainActor [weak self] in
            guard let self, !self.isDisposed, self.streamLoadGeneration == generation,
                  self.serverBurnInReload != .none else { return }
            self.reloadForServerBurnIn(reason: reason)
        }
        return true
    }

    private func reloadForServerBurnIn(reason: String) {
        guard var request = lastLoadRequest, request.offlineDownloadId == nil else { return }
        Self.logger.info(
            "[CMP-SUB] server burn-in reload decision=\(String(describing: self.serverBurnInReload), privacy: .public) reason=\(reason, privacy: .public)"
        )
        // Like a quality change: the same file and quality from here, with
        // the subtitle choice carried as the load's pick. The bridge asks the
        // server to draw a bitmap pick in only when it transcodes.
        let target = currentTime.isFinite ? max(0, currentTime) : 0
        request = request.copyForRecovery(
            preferredFileId: currentSelectedVersion?.fileId ?? request.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            offlineDownloadId: nil,
            serverSubtitlesDisabled: hasDisabledServerSubtitlesForResume
        )
        beginFreshLoad(
            request: request,
            progressPosition: target,
            finalizeCurrentSession: true,
            resumePositionOverride: target,
            allowNearEndResume: true
        )
    }

    /// A burned-in transcode that fails to open plays again without the
    /// subtitle, rather than ending playback. Returns true when that reload
    /// takes over.
    func fallBackFromFailedServerBurnIn(_ failure: ServerBurnInFailure, request: LoadRequest,
                                        origin: LoadOrigin) -> Bool {
        guard !isDisposed, request.offlineDownloadId == nil else { return false }
        failedServerBurnIns.insert(failure)
        Self.logger.warning("[CMP-SUB] server burn-in failed to open; playing without it")
        let fallback = request.copyForRecovery(
            preferredFileId: failure.fileId,
            preferredAudioTrackIndex: request.preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: -1,
            preferredSidecarSubtitleTrackId: nil,
            offlineDownloadId: nil,
            serverSubtitlesDisabled: true
        )
        let position = currentTime.isFinite ? max(0, currentTime) : 0
        beginFreshLoad(
            request: fallback,
            progressPosition: nil,
            resumePositionOverride: position,
            allowNearEndResume: true,
            origin: origin
        )
        // The new load clears notices as it starts.
        showServerBurnInNotice()
        return true
    }

    private func showServerBurnInNotice() {
        showNotice(
            title: "Couldn't show subtitles",
            message: "The server couldn't add this subtitle to the video, so subtitles are off.",
            tone: .warning,
            duration: 6
        )
    }
}
