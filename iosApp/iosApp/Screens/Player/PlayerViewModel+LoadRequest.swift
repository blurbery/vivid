import Foundation

extension PlayerViewModel {
    /// What a load asks for: the item, the file, the track picks and how to
    /// start. Kept as `lastLoadRequest`, so renewals, retries, seek reloads
    /// and quality changes repeat it.
    struct LoadRequest {
        let contentId: String
        let preferredFileId: Int?
        var preferredAudioTrackIndex: Int?
        let preferredSubtitleTrackIndex: Int?
        let preferredSidecarSubtitleTrackId: Int64?
        var startFromBeginning: Bool
        /// The Silo combined index of the subtitle. Unlike
        /// `preferredSubtitleTrackIndex`, it can also name external,
        /// downloaded and server-extracted subtitle rows.
        var preferredProtocolV3SubtitleIndex: Int? = nil
        /// Set for local playback of a completed download. The load is
        /// prepared by `OfflinePlaybackBuilder` instead of a server session,
        /// so a retry after an error stays offline.
        var offlineDownloadId: String? = nil
        /// An explicit quality for this load (a quality change in the
        /// player); wins over `PlayerSettings.preferredQuality` in the bridge.
        var preferredQualityOverride: String? = nil
        /// Set when `preferredQualityOverride` carries the current playback's
        /// quality forward rather than a new choice in the player: the load
        /// repeats this cap instead of working one out from the override.
        /// Nil means the override is a new choice (or there is none).
        var carriedBandwidthCap: CarriedBandwidthCap? = nil
        /// Continue Watching only: pick the server's last-used file before
        /// applying the profile's automatic quality preference.
        var prefersLastUsedVersion = false
        /// A reload of the same item whose subtitle indexes carry what Auto
        /// chose, so it stays on screen. The choice stays Auto's: switching
        /// audio afterwards still runs Auto again.
        var keepsAutomaticSubtitles = false

        /// The same request, resuming at the reload's own position. A Play
        /// from Beginning ignores any resume override, so a retry or seek
        /// reload of an item that has already played mustn't repeat it.
        func resumingInPlace() -> LoadRequest {
            var request = self
            request.startFromBeginning = false
            return request
        }

        /// A request for the same item with new file and track picks, keeping
        /// the viewer's quality choice for this playback. Recovery mustn't
        /// fall back to the saved preference just because the tracks or file
        /// changed.
        func copyForRecovery(
            preferredFileId: Int?,
            preferredAudioTrackIndex: Int?,
            preferredSubtitleTrackIndex: Int?,
            preferredSidecarSubtitleTrackId: Int64?,
            offlineDownloadId: String?,
            serverSubtitlesDisabled: Bool = false
        ) -> LoadRequest {
            var request = LoadRequest(
                contentId: contentId,
                preferredFileId: preferredFileId,
                preferredAudioTrackIndex: preferredAudioTrackIndex,
                preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
                preferredSidecarSubtitleTrackId: preferredSidecarSubtitleTrackId,
                startFromBeginning: false,
                offlineDownloadId: offlineDownloadId,
                preferredQualityOverride: preferredQualityOverride,
                carriedBandwidthCap: carriedBandwidthCap
            )
            // A sidecar picked after the last Silo plan asks the new session
            // for its combined index; keeping the old plan's index would pick
            // its embedded subtitle again. Local Off also goes with a burn-in,
            // so only an explicit server Off clears the server's index.
            if serverSubtitlesDisabled {
                request.preferredProtocolV3SubtitleIndex = nil
            } else if let preferredSidecarSubtitleTrackId,
                      SubtitleTrackIdSpace.isSidecar(preferredSidecarSubtitleTrackId) {
                request.preferredProtocolV3SubtitleIndex = SubtitleTrackIdSpace.sidecarIndex(
                    from: preferredSidecarSubtitleTrackId
                )
            } else {
                request.preferredProtocolV3SubtitleIndex = preferredProtocolV3SubtitleIndex
            }
            request.prefersLastUsedVersion = prefersLastUsedVersion
            return request
        }

        /// The request a renewal sends, taken from an adopted Silo plan. The
        /// player's track lists are short-lived and can already be empty when
        /// a failed source reports that its session has gone.
        func adoptingProtocolV3Intent(
            plan: PlaybackV3Plan,
            selectedVersion: FileVersion,
            activeQualityId: String,
            bandwidthCap: CarriedBandwidthCap = .savedSetting
        ) -> LoadRequest {
            // Same resolution order as `PlaybackV3Plan.selectedSubtitleInventoryItem`.
            // An `off` plan selects nothing, even if it still carries an old
            // identity.
            let isSubtitleOff = plan.subtitle.mode == PlaybackProtocolV3.SubtitleMode.off
            let selectedSubtitleIndex = isSubtitleOff ? nil : plan.selectedSubtitleCombinedIndex
            let selectedSubtitle = isSubtitleOff ? nil : plan.selectedSubtitleInventoryItem
            let embeddedFFmpegIndex: Int? = selectedSubtitle.flatMap { item in
                // A sidecar is the server's chosen file even when it was
                // extracted from an embedded stream. Arming both identities
                // would publish and select the same subtitle twice.
                if let embedded = plan.subtitle.embedded { return embedded.streamIndex }
                guard item.source == "embedded", item.delivery != "sidecar" else { return nil }
                return ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                    serverCombinedIndex: item.combinedIndex,
                    in: selectedVersion,
                    inventory: plan.subtitle.inventory
                )
            }
            let sidecarTrackId: Int64? = selectedSubtitle.flatMap { item in
                guard plan.subtitle.embedded == nil, item.delivery == "sidecar" else { return nil }
                return SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: item.combinedIndex)
            }
            var request = copyForRecovery(
                preferredFileId: plan.effectiveMediaFileId,
                preferredAudioTrackIndex: plan.selectedTracks.audio?.index,
                preferredSubtitleTrackIndex: embeddedFFmpegIndex,
                preferredSidecarSubtitleTrackId: sidecarTrackId,
                offlineDownloadId: offlineDownloadId
            )
            request.preferredProtocolV3SubtitleIndex = selectedSubtitleIndex
            request.preferredQualityOverride = activeQualityId
            // A renewal repeats this plan's quality, so it keeps the plan's cap.
            request.carriedBandwidthCap = bandwidthCap
            return request
        }
    }

    /// What started a `beginFreshLoad`. It decides whether starting the
    /// session has a time limit and how a failure is shown.
    enum LoadOrigin {
        /// The viewer picked an item: no time limit, Retry on failure.
        case userInitiated
        /// Autoplay from the Next Up postroll: time-limited, and a failure
        /// goes back to the postroll with `nextUpStartError`.
        case autoplay
        /// Automatic recovery: time-limited like autoplay (only a viewer's
        /// own pick has no limit). A failure stays on the player surface
        /// with a notice instead of using the postroll.
        case recovery
    }

    enum BeginFreshLoadError: Error {
        case startSessionTimeout
    }
}
