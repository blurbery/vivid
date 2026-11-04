import Foundation
import OSLog

/// Audio, subtitle and secondary subtitle picks, and the funnels that hand
/// every track change to Lucid Engine.
///
/// On a Silo (Protocol V3) plan the server owns audio switches: the pick is
/// sent up as a replan and comes back as a new plan, so it is never applied
/// locally first. Everything else is applied straight to the engine. The
/// automatic subtitle pick lives in `+SubtitlePreferences`, OpenSubtitles
/// files in `+OpenSubtitles`, and server burn-in in `+ServerBurnIn`.
extension PlayerViewModel {
    // MARK: - Audio

    func selectAudio(_ track: PlayerTrack) {
        guard activePreparedProtocolV3 != nil else {
            viewingAudioLanguage = viewingAudioLanguage(for: track)
            pendingAudioFfIndex = nil
            selectedAudioId = track.trackId
            audioPickedForCurrentItem = true
            reapplyAutomaticSubtitlePolicy()
            applyAudioTrackSelection(track.trackId, reason: "user_selection")
            scheduleHideControls()
            return
        }
        // The server switches the audio, so the track mustn't be applied
        // locally before its plan arrives. The selection is published first
        // because the replan reads it back, but nothing is kept or recorded
        // until the replan is actually under way: a dropped switch must not
        // be filed as a success.
        let priorAudioId = selectedAudioId
        let priorPendingAudioFfIndex = pendingAudioFfIndex
        let priorAudioPicked = audioPickedForCurrentItem
        let pickedLanguage = viewingAudioLanguage(for: track)
        pendingAudioFfIndex = nil
        selectedAudioId = track.trackId
        audioPickedForCurrentItem = true
        reapplyAutomaticSubtitlePolicy()
        let replanStarted = attemptProtocolV3Replan(
            position: currentTime,
            classification: "audio_track_changed",
            message: "User selected audio track \(track.title ?? String(track.trackId)).",
            requeueWhenBusy: true,
            trackTarget: queuedTrackTarget(forAudio: track)
        )
        guard replanStarted else {
            selectedAudioId = priorAudioId
            pendingAudioFfIndex = priorPendingAudioFfIndex
            audioPickedForCurrentItem = priorAudioPicked
            reapplyAutomaticSubtitlePolicy()
            showNotice(
                title: String(localized: "Couldn't change audio"),
                message: String(localized: "The audio track couldn't be switched. Try again."),
                tone: .warning,
                duration: 5
            )
            scheduleHideControls()
            return
        }
        viewingAudioLanguage = pickedLanguage
        recordAudioTrackSelectionBreadcrumb(track.trackId, reason: "user_selection", viaServerReplan: true)
        scheduleHideControls()
    }

    /// The language an audio pick carries to next episodes in this viewing.
    func viewingAudioLanguage(for track: PlayerTrack) -> String? {
        let catalog = currentSelectedVersion?.audioTracks ?? []
        let linesUp = audioTracks.count == catalog.count
        return Self.viewingAudioLanguage(
            stream: track.normalizedLanguageCode,
            catalog: linesUp ? catalog : [],
            ordinal: audioSelectionIndex(for: track)
        )
    }

    /// The stream's language tag, or the catalogue's language for that track
    /// when the stream has none. Nil when neither names a language, so the
    /// next episode follows Settings.
    static func viewingAudioLanguage(stream: String?, catalog: [AudioTrack], ordinal: Int?) -> String? {
        if let stream, !stream.isEmpty { return stream }
        guard let ordinal, catalog.indices.contains(ordinal),
              let language = catalog[ordinal].language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty,
              language.caseInsensitiveCompare("und") != .orderedSame else {
            return nil
        }
        return language
    }

    /// The track's position in the source's audio list, which is what the
    /// catalogue and the servers number audio by.
    func audioSelectionIndex(for track: PlayerTrack) -> Int? {
        track.srcId ?? track.ffIndex
    }

    /// The catalogue ordinal of the engine's selected audio track. It counts
    /// only when the engine's list lines up with the catalogue's, since a
    /// transcode can carry fewer audio tracks than the file.
    var engineCatalogAudioOrdinal: Int? {
        guard let selected = audioTracks.first(where: { $0.trackId == selectedAudioId }),
              audioTracks.count == (currentSelectedVersion?.audioTracks?.count ?? 0) else {
            return nil
        }
        return audioSelectionIndex(for: selected)
    }

    // MARK: - Subtitles

    /// Server subtitle files beside the media: mounted for Emby and Jellyfin,
    /// or offered for Silo and mounted when chosen.
    func isServerSidecarSubtitle(_ trackID: Int64) -> Bool {
        SubtitleTrackIdSpace.isSidecar(trackID)
            && (vividPlaybackController.containsSubtitle(appTrackID: trackID) || lazySubtitleSidecars[trackID] != nil)
    }

    /// Whether a picker row names something the engine can show: an embedded
    /// track it holds, a server sidecar, or a mounted OpenSubtitles file.
    func isSelectableSubtitle(_ track: PlayerTrack) -> Bool {
        #if os(iOS) || os(tvOS)
        if track.isExternal {
            return (openSubtitleIDs.contains(track.trackId) && vividPlaybackController.containsSubtitle(appTrackID: track.trackId))
                || isServerSidecarSubtitle(track.trackId)
        }
        #endif
        return !track.isExternal && vividPlaybackController.containsSubtitle(appTrackID: track.trackId)
    }

    func selectSubtitle(_ track: PlayerTrack) {
        guard isServerBurnInRow(track.trackId) || isSelectableSubtitle(track) else { return }
        #if os(iOS) || os(tvOS)
        openSubtitleFiles.selectedID = openSubtitleIDs.contains(track.trackId) ? track.trackId : nil
        rememberOpenSubtitleChoice(openSubtitleFiles.selectedID)
        #endif
        hasExplicitSubtitleChoice = true
        pendingSubtitleFfIndex = nil
        pendingSidecarSubtitleTrackId = nil
        pendingServerRenderedSubtitleTrackId = nil
        if selectedSecondarySubtitleId == track.trackId { disableSecondarySubtitles() }
        selectedSubtitleId = track.trackId
        // An OpenSubtitles file belongs to this device, so it isn't carried
        // into the viewing's preferences.
        if !track.isExternal || SubtitleTrackIdSpace.isSidecar(track.trackId) {
            keepSubtitlePickForViewing(track)
        }
        applyUserSubtitlePick(track.trackId)
    }

    func disableSubtitles() {
        #if os(iOS) || os(tvOS)
        openSubtitleFiles.selectedID = nil
        rememberOpenSubtitleChoice(nil)
        #endif
        localExternalSubtitlePick = nil
        hasExplicitSubtitleChoice = true
        pendingSubtitleFfIndex = -1
        pendingSidecarSubtitleTrackId = nil
        pendingServerRenderedSubtitleTrackId = nil
        selectedSubtitleId = nil
        disableSecondarySubtitles()
        keepSubtitlePickForViewing(nil)
        applyUserSubtitlePick(nil)
    }

    /// The last step of a picker choice: a reload when the server has to
    /// draw a different subtitle in, otherwise the engine switches.
    private func applyUserSubtitlePick(_ trackId: Int64?) {
        if !reloadForServerBurnInIfNeeded(reason: "user_selection") {
            applySubtitleTrackSelection(trackId, reason: "user_selection")
        }
        scheduleHideControls()
    }

    /// Keeps an explicit subtitle pick (or Off when `track` is nil) for the
    /// rest of this viewing. Settings > Subtitles is left alone: one pick
    /// must not turn Auto into Always, or Off, for everything played later.
    private func keepSubtitlePickForViewing(_ track: PlayerTrack?) {
        viewingSubtitlePrefs = Self.viewingSubtitlePrefs(for: track)
    }

    // MARK: - Secondary subtitles

    func selectSecondarySubtitle(_ track: PlayerTrack) {
        guard backendCapabilities.supportsSecondarySubtitles,
              !SubtitleCodecClassifier.isBitmap(track.codec),
              // It can't be the primary subtitle too. Refusing here gives an
              // immediate no-op rather than a checkmark that renders nothing.
              track.trackId != selectedSubtitleId,
              canRenderAsSecondarySubtitle(track) else { return }
        selectedSecondarySubtitleId = track.trackId
        applySecondarySubtitleTrackSelection(track.trackId)
        scheduleHideControls()
    }

    func disableSecondarySubtitles() {
        guard backendCapabilities.supportsSecondarySubtitles else { return }
        selectedSecondarySubtitleId = nil
        applySecondarySubtitleTrackSelection(nil)
        scheduleHideControls()
    }

    /// Whether a picker row can be shown as the secondary subtitle: an
    /// embedded track the engine already holds.
    func canRenderAsSecondarySubtitle(_ track: PlayerTrack) -> Bool {
        !track.isExternal && vividPlaybackController.containsSubtitle(appTrackID: track.trackId)
    }

    func applySecondarySubtitleTrackSelection(_ trackId: Int64?) {
        guard let trackId else {
            vividPlaybackController.selectSecondarySubtitleTrack(id: nil)
            return
        }
        guard let track = subtitleTracks.first(where: { $0.trackId == trackId }),
              !SubtitleCodecClassifier.isBitmap(track.codec) else {
            selectedSecondarySubtitleId = nil
            vividPlaybackController.selectSecondarySubtitleTrack(id: nil)
            return
        }
        // Only a track the engine actually holds can be shown. A Silo plan
        // mounts a single subtitle file, so another sidecar row has no engine
        // track at all, and a checkmark over nothing is worse than refusing.
        guard vividPlaybackController.containsSubtitle(appTrackID: trackId)
                || !SubtitleTrackIdSpace.isSidecar(trackId) else {
            Self.logger.warning(
                "[CMP-SUB] secondary subtitle \(trackId, privacy: .public) has no Vivid track; clearing"
            )
            selectedSecondarySubtitleId = nil
            vividPlaybackController.selectSecondarySubtitleTrack(id: nil)
            return
        }
        vividPlaybackController.selectSecondarySubtitleTrack(id: trackId)
    }

    // MARK: - Engine funnels

    /// Every audio change that the engine makes, whether the viewer chose it
    /// or a reload restored it, comes through here. `reason` has no default,
    /// because a breadcrumb that can't tell a pick from a restore can't answer
    /// the question it's there for.
    func applyAudioTrackSelection(_ trackId: Int64, reason: String) {
        recordAudioTrackSelectionBreadcrumb(trackId, reason: reason, viaServerReplan: false)
        guard let id = Int(exactly: trackId) else { return }
        vividPlaybackController.selectAudioTrack(id: id)
    }

    /// The one funnel for primary subtitle changes, with the same `reason`
    /// rule as audio. Nil means subtitles off.
    func applySubtitleTrackSelection(_ trackId: Int64?, reason: String) {
        Self.logger.info(
            "[CMP-SUB] apply primary selection trackId=\(trackId.map(String.init) ?? "nil", privacy: .public) route=\(self.activeRouteLabel, privacy: .public)"
        )
        recordSubtitleTrackSelectionBreadcrumb(trackId, reason: reason, viaServerReplan: false)
        // A Silo subtitle file is fetched only once it's chosen, and
        // remembered so replacement loads put it back. A reload's interim Off
        // (nil) leaves that pick alone; an explicit Off clears it elsewhere.
        if let trackId {
            if let sidecar = lazySubtitleSidecars[trackId] {
                if !vividPlaybackController.containsSubtitle(appTrackID: trackId) {
                    vividPlaybackController.addExternalSubtitleTrack(sidecar, appTrackID: trackId)
                }
                localExternalSubtitlePick = currentWatchDetail.map {
                    (trackId, $0.contentId, currentSelectedVersion?.fileId, ServerSubtitleSidecars.storedSubtitleID(in: sidecar.url))
                }
            } else {
                localExternalSubtitlePick = nil
            }
        }
        // The server draws a burn-in row, so the engine shows nothing for it.
        vividPlaybackController.selectSubtitleTrack(id: isServerBurnInRow(trackId) ? nil : trackId)
    }

    // MARK: - Breadcrumbs
    //
    // Kept apart from the funnels because a Silo track change never reaches
    // them: the pick goes to the server as a replan. Both only read state and
    // record it. Recording an intent must never apply it, since applying a
    // track locally before the server's plan lands is exactly the mismatch
    // these breadcrumbs are there to diagnose.

    /// `viaServerReplan` tells an instant engine switch from a pick sent to
    /// the server (which reloads playback). No registered key says that, so
    /// it goes in the message.
    private func recordAudioTrackSelectionBreadcrumb(_ trackId: Int64, reason: String, viaServerReplan: Bool) {
        #if os(iOS) || os(tvOS)
        // Track titles and languages are content, not diagnostics, so only
        // the ordinal is recorded. It matches the plan's selected tracks.
        let ordinal = audioTracks.first { $0.trackId == trackId }.flatMap(audioSelectionIndex(for:))
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "Player",
            message: viaServerReplan
                ? "audio track selected, requesting server replan"
                : "audio track selected",
            attrs: [
                "reason": .string(reason),
                "sink": .string(ordinal.map { "audio_ordinal_\($0)" } ?? "audio_ordinal_unknown"),
                "play_method": .string(activeRouteLabel),
            ]
        )
        #endif
    }

    /// A primary subtitle pick, or Off when `trackId` is nil. Records the
    /// kind of source, never the subtitle's title.
    private func recordSubtitleTrackSelectionBreadcrumb(_ trackId: Int64?, reason: String, viaServerReplan: Bool) {
        #if os(iOS) || os(tvOS)
        let action = trackId == nil ? "subtitles disabled" : "subtitle track selected"
        let kind = trackId.map { SubtitleTrackIdSpace.isSidecar($0) ? "sidecar" : "embedded" }
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "Player",
            message: viaServerReplan ? "\(action), requesting server replan" : action,
            attrs: [
                "reason": .string(reason),
                "sink": .string(kind ?? "none"),
                "play_method": .string(activeRouteLabel),
            ]
        )
        #endif
    }

    // MARK: - Emby and Jellyfin reports

    /// The playing tracks as an Emby or Jellyfin report names them.
    var playingTracksForServer: MediaServerPlayingTracks {
        let subtitle: MediaServerPlayingTracks.Subtitle?
        if let selectedSubtitleId {
            if SubtitleTrackIdSpace.isSidecar(selectedSubtitleId) {
                subtitle = .serverStream(SubtitleTrackIdSpace.sidecarIndex(from: selectedSubtitleId))
            } else if let track = subtitleTracks.first(where: { $0.trackId == selectedSubtitleId }) {
                // An OpenSubtitles file is the viewer's own; the server has none.
                subtitle = track.isExternal ? .off : track.ffIndex.map { .embedded($0) }
            } else {
                subtitle = nil
            }
        } else {
            subtitle = .off
        }
        return MediaServerPlayingTracks(audioOrdinal: engineCatalogAudioOrdinal, subtitle: subtitle)
    }

    /// Hands the playing tracks to the Emby or Jellyfin session, so its next
    /// progress report names them. Silo plans carry their own tracks.
    func reportPlayingTracksToServer() {
        // Empty lists mean a load is being torn down or hasn't published its
        // tracks yet; the outgoing session's last report keeps what played.
        guard offlinePlaybackContext == nil,
              activePreparedProtocolV3 == nil,
              !audioTracks.isEmpty || !subtitleTracks.isEmpty,
              let sessionID = activePlaybackSessionId else { return }
        let tracks = playingTracksForServer
        playingTracksGeneration &+= 1
        let generation = playingTracksGeneration
        Task { [sessionBridge] in
            await sessionBridge.updatePlayingTracks(tracks, sessionID: sessionID, generation: generation)
        }
    }

    // MARK: - Silo plan helpers

    enum ProtocolV3SidecarRestoreIntent: Equatable {
        case renderLocally(Int64)
        case serverRendered(Int64)
    }

    /// What a replacement plan means for a sidecar subtitle that was selected
    /// before it: render it here again, keep it as a row the server draws,
    /// or nothing when the plan selected something else.
    static func protocolV3SidecarRestoreIntent(
        snapshot: Int64?,
        selectedSubtitleIndex: Int?,
        subtitleMode: String?,
        isEmbedded: Bool = false
    ) -> ProtocolV3SidecarRestoreIntent? {
        guard !isEmbedded,
              let snapshot,
              SubtitleTrackIdSpace.isSidecar(snapshot),
              SubtitleTrackIdSpace.sidecarIndex(from: snapshot) == selectedSubtitleIndex else {
            return nil
        }
        switch subtitleMode {
        case let mode? where PlaybackProtocolV3.SubtitleMode.locallyRendered.contains(mode):
            return .renderLocally(snapshot)
        case PlaybackProtocolV3.SubtitleMode.burnIn:
            return .serverRendered(snapshot)
        default:
            return nil
        }
    }

    static func isCurrentStreamCallback(_ callbackGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        callbackGeneration == currentGeneration
    }

    /// A clock report more than three quarters of a second behind the
    /// playhead while no seek is in flight.
    static func isUnexpectedBackwardPlaybackTime(
        _ candidate: Double,
        currentTime: Double,
        explicitSeekInFlight: Bool
    ) -> Bool {
        guard !explicitSeekInFlight, candidate.isFinite, currentTime.isFinite else { return false }
        return candidate + 0.75 < currentTime
    }

    struct ProtocolV3PendingTrackIntent: Equatable {
        let audioIndex: Int?
        let embeddedSubtitleIndex: Int?
        let sidecarSubtitleTrackId: Int64?
        let serverRenderedSubtitleTrackId: Int64?
    }

    /// The track picks a new plan leaves for the engine to apply once its
    /// tracks are listed. A subtitle the server burns in is local Off (-1)
    /// and kept as the row the server draws.
    static func protocolV3PendingTrackIntent(plan: PlaybackV3Plan, request: LoadRequest) -> ProtocolV3PendingTrackIntent {
        let rendersSubtitleLocally = PlaybackProtocolV3.SubtitleMode.locallyRendered.contains(plan.subtitle.mode)
        let rendersBurnIn = plan.subtitle.mode == PlaybackProtocolV3.SubtitleMode.burnIn
        return ProtocolV3PendingTrackIntent(
            audioIndex: request.preferredAudioTrackIndex,
            embeddedSubtitleIndex: rendersSubtitleLocally
                ? (plan.subtitle.embedded?.streamIndex ?? request.preferredSubtitleTrackIndex)
                : -1,
            sidecarSubtitleTrackId: rendersSubtitleLocally && plan.subtitle.embedded == nil
                ? request.preferredSidecarSubtitleTrackId
                : nil,
            serverRenderedSubtitleTrackId: rendersBurnIn
                ? plan.selectedSubtitleCombinedIndex.map { SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0) }
                : nil
        )
    }
}
