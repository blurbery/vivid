import Foundation
import OSLog
#if os(tvOS)
import TVServices
#endif

/// The server half of one player's playback: it starts the session, reports
/// progress, asks for new plans and stops.
///
/// Silo speaks Protocol V3, where a server decision stays provisional until
/// the player has actually opened its source (see
/// `commitPendingProtocolV3Transition`). Emby and Jellyfin sessions live in
/// `EmbyPlayback` and `JellyfinPlayback`, and the bridge only puts their
/// starts, reports and stops in order. Any `await` lets another call into the
/// actor, so every method claims or rechecks the state it relies on before it
/// suspends.
actor PlaybackSessionBridge {
    // MARK: - Types

    /// The Protocol V3 attempt the current Silo session belongs to.
    private struct SiloAttempt {
        let playbackAttemptId: String
        var planAttemptId: String
        var planAttemptKey: String
        /// Every plan key this intent has tried, which a failure replan
        /// excludes.
        var triedPlanKeys: [String]
        var attemptCount: Int
        var clientQualityId: String
        /// Set once the viewer picks one of the plan's own qualities. Recovery
        /// replans then repeat that id instead of mapping it through the
        /// Settings quality ladder.
        var qualityIsServerOwned: Bool
        /// The bandwidth cap this attempt started with. Every replan sends it
        /// again, or recovery would quietly lift the limit.
        var bandwidthCapKbps: Int?
        var snapshot: ApplePlaybackV3CapabilitySnapshot
        var serverFeatures: [String]
        /// Settled by the start: the server restores the negotiated origin
        /// state on a replan anyway, so every replan repeats it. Changing it
        /// takes a new attempt.
        let negotiatedAuthorizedMediaOrigins: Bool
        var plan: PlaybackV3Plan

        /// Enough to tell whether a replan that suspended has since been
        /// overtaken by a newer load or a stop.
        var stamp: AttemptStamp {
            AttemptStamp(playback: playbackAttemptId, plan: planAttemptId, key: planAttemptKey)
        }
    }

    private struct AttemptStamp: Equatable {
        let playback: String
        let plan: String
        let key: String
    }

    /// A start the server accepted, waiting to be adopted.
    private struct AcceptedStart {
        let attempt: SiloAttempt
        let sessionId: String
        let version: FileVersion
        let session: PlaybackSessionResponse
        /// The receiver's stream, for an AirPlay receiver attempt.
        var receiverStream: AirPlayReceiverStream?
    }

    /// A server decision the player hasn't proved it can open yet, with the
    /// state it replaced. A cancelled or failed load can then put that state
    /// back without ever publishing a session and plan that never played,
    /// and a commit retires the replaced session exactly once.
    private struct PendingDecision {
        let priorSessionId: String?
        let previousSession: PlaybackSessionResponse?
        let priorAttempt: SiloAttempt?
        let candidateSession: String
        let candidatePlan: String
        let commitEvent: String?
        let commitAttributes: [String: String]
    }

    struct InitialProtocolV3SubtitleIntent: Equatable {
        let ffmpegStreamIndex: Int?
        let combinedIndex: Int?
    }

    struct InitialProtocolV3SubtitlePreferences: Equatable {
        let preferredLanguage: String?
        let additionalPreferredLanguages: [String]
        let mode: SubtitleMode?
        let showForced: Bool
        let forcedOnly: Bool
        let preferAccessibilityTracks: Bool
        let disableWhenNoLanguageMatch: Bool
        let trackSignature: SubtitleTrackSignature?
    }

    // MARK: - State

    /// A stored resume point this close to the end starts the item again.
    private static let nearEndRestartWindow: Double = 5
    /// How far inside the end a transient resume at or past it is moved.
    private static let pastEndBackoff: Double = 0.25
    /// Failed Silo progress writes in a row before the session is logged as
    /// possibly stale.
    private static let staleSessionFailureCount = 3
    /// Plans one intent may try, its first included: seven fallback replans
    /// in a row before recovery gives up. A replan that changes the intent
    /// (a track change, say) starts the count again, and seek re-anchors
    /// don't count.
    private static let planAttemptLimit = 8

    private static let playbackLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "Playback"
    )
    private let logger = PlaybackSessionBridge.playbackLog

    private var sessionId: String?
    private var currentSession: PlaybackSessionResponse?

    /// The most recent progress write. Each write waits for the one before
    /// it, and stops and Jellyfin replacements wait for this one, so the
    /// server sees writes in order.
    private var progressWriteTail: Task<PlaybackProgressReportResult, Never>?

    /// Failed Silo progress writes since the last success. Past
    /// `staleSessionFailureCount` the session is logged once as possibly
    /// gone on the server.
    private var consecutiveProgressFailures = 0
    private var emittedOrphanedSessionWarning = false

    private var activeProtocolV3: SiloAttempt?
    private var protocolV3FirstFramePlanIds: Set<String> = []
    private var pendingProtocolV3Transition: PendingDecision?

    // MARK: - Emby and Jellyfin sessions

    private var embyPlayback: EmbyPlayback?
    /// The plan of the Silo AirPlay receiver attempt, while one is live.
    private var airPlayReceiverPlanId: String?
    #if os(iOS)
    /// AirPlay receiver sessions prepared but not yet committed, by server
    /// session id.
    private var preparedAirPlayReceivers: [String: PreparedAirPlayReceiver] = [:]
    #endif
    private var jellyfinPlayback: JellyfinPlayback?
    private var playingTracksGeneration: UInt64 = 0
    /// Every start and stop replaces this. A Jellyfin start that finds a
    /// different value has been overtaken and stops.
    private var jellyfinStartAttempt = UUID()
    /// True while a Jellyfin start is replacing the current playback or a
    /// stop is retiring it. Reports and other starts and stops wait until it
    /// clears.
    private var jellyfinTransitionInProgress = false
    /// The playback being replaced or stopped, so a terminal watched write
    /// that waited for the transition still reaches the item it was for.
    private var jellyfinTransitionPlayback: JellyfinPlayback?
    private var jellyfinTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    /// The Jellyfin playback a progress report has gone out for, which is
    /// the one with a play session to stop at a position. One that never
    /// reported is stopped without saving a position.
    private weak var reportedJellyfinPlayback: JellyfinPlayback?

    /// Returns once no Jellyfin start or stop is under way.
    private func waitForJellyfinTransition() async {
        while jellyfinTransitionInProgress {
            await withCheckedContinuation { jellyfinTransitionWaiters.append($0) }
        }
    }

    /// Ends the current Jellyfin transition and lets everyone waiting on it
    /// carry on.
    private func finishJellyfinTransition() {
        jellyfinTransitionInProgress = false
        jellyfinTransitionPlayback = nil
        let released = jellyfinTransitionWaiters
        jellyfinTransitionWaiters = []
        for waiter in released {
            waiter.resume()
        }
    }

    /// Throws `CancellationError` once the task is cancelled or a newer
    /// start or stop has replaced `attempt`.
    private func validateJellyfinStart(_ attempt: UUID) throws {
        if Task.isCancelled || attempt != jellyfinStartAttempt {
            throw CancellationError()
        }
    }

    func reportNativePlaybackStarted(_ prepared: PreparedPlayback) async {
        if jellyfinTransitionInProgress { await waitForJellyfinTransition() }
        if let playback = jellyfinPlayback, playback.playSessionID == prepared.session.sessionId {
            try? await playback.ping()
            return
        }
        guard let playback = embyPlayback, playback.playSessionID == prepared.session.sessionId else { return }
        try? await playback.ping()
    }

    /// The tracks playing in an Emby or Jellyfin session, for its progress
    /// reports. Silo and downloads report positions only. Updates can arrive
    /// out of order, so an older `generation` never replaces a newer one.
    func updatePlayingTracks(_ tracks: MediaServerPlayingTracks, sessionID: String, generation: UInt64) async {
        guard generation > playingTracksGeneration else { return }
        playingTracksGeneration = generation
        if let playback = jellyfinPlayback, playback.playSessionID == sessionID {
            await playback.update(playingTracks: tracks)
        } else if let playback = embyPlayback, playback.playSessionID == sessionID {
            await playback.update(playingTracks: tracks)
        }
    }

    /// The Emby session's stream with fresh credentials, or nil once the
    /// session has changed or the sign-in no longer validates.
    func embyStreamRequest(sessionID: String) async -> StreamRequest? {
        guard let playback = embyPlayback, playback.playSessionID == sessionID else { return nil }
        do {
            try await playback.connection.validate()
            return playback.stream
        } catch {
            return nil
        }
    }

    /// The Jellyfin session's stream with fresh credentials, or nil once the
    /// session has changed or the sign-in no longer validates.
    func jellyfinStreamRequest(sessionID: String) async -> StreamRequest? {
        guard let playback = jellyfinPlayback, playback.playSessionID == sessionID else { return nil }
        do {
            try await playback.connection.validate()
            return playback.stream
        } catch {
            return nil
        }
    }

    // MARK: - Starting

    func startSession(
        contentId: String,
        preferredFileId: Int? = nil,
        preferredAudioTrackIndex: Int? = nil,
        viewingAudioLanguage: String? = nil,
        preferredSubtitleTrackIndex: Int? = nil,
        preferredProtocolV3SubtitleIndex: Int? = nil,
        initialSubtitlePreferences: InitialProtocolV3SubtitlePreferences? = nil,
        startFromBeginning: Bool,
        resumePosition: Double? = nil,
        allowNearEndResume: Bool = false,
        prefersLastUsedVersion: Bool = false,
        preferredQualityOverride: String? = nil,
        carriedBandwidthCap: CarriedBandwidthCap? = nil,
        serverBurnInSubtitleIndex: Int? = nil
    ) async throws -> PreparedPlayback {
        // A newer start or a stop replaces this token, which is how a
        // Jellyfin start still in progress finds out it has lost.
        let attempt = UUID()
        jellyfinStartAttempt = attempt
        logger.info("Fetching watch detail for \(contentId, privacy: .public)")

        let detail: WatchDetail
        var embyMetadata: EmbyPlayback.Metadata?
        var jellyfinMetadata: JellyfinPlayback.Metadata?
        switch MediaServerProvider.active {
        case .silo:
            detail = try await VividAPI.shared.watchDetail(contentId: contentId)
        case .emby:
            let loaded = try await EmbyPlayback.loadMetadata(contentID: contentId)
            embyMetadata = loaded
            detail = loaded.detail
        case .jellyfin:
            let loaded = try await JellyfinPlayback.loadMetadata(contentID: contentId)
            jellyfinMetadata = loaded
            detail = loaded.detail
        }
        logger.info("Got \(detail.versions.count) versions, type=\(detail.type, privacy: .public)")
        if detail.versions.isEmpty {
            throw APIError.httpError(statusCode: 404)
        }

        // An explicit choice made in the player (going back to Auto, say)
        // beats the saved setting.
        let settings = PlayerSettings.shared
        let rememberedQuality = prefersLastUsedVersion
            ? normalizedQualityPreference(detail.userData?.lastResolution)
            : nil
        let quality = preferredQualityOverride.map { ApplePlaybackQuality.protocolV3QualityId($0) }
            ?? settings.fallbackMode?.rawValue
            ?? rememberedQuality
            ?? normalizedQualityPreference(settings.preferredQuality)
        // A carried choice repeats the cap its playback ran with. Only a
        // fresh choice in the player takes its cap from the chosen tier.
        let bitrateCap = AppleQualityAxes.resolvedBitrateCap(
            qualityOverride: preferredQualityOverride,
            carriedCap: carriedBandwidthCap,
            fallbackBitrateKbps: settings.maxBitrateKbps
        )
        let version = initialVersion(
            in: detail,
            preferredFileId: preferredFileId,
            prefersLastUsedVersion: prefersLastUsedVersion,
            preferredQuality: quality
        )

        // The viewer's pick, else the language chosen earlier in this
        // viewing, else Settings > Playback > Audio Language.
        let audioTracks = version.audioTracks ?? []
        let audioLanguagePreference = VividInitialAudioPreference.preferredLanguage(
            viewing: viewingAudioLanguage,
            settings: settings.audioLanguage,
            tracks: audioTracks
        )
        let audioOrdinal = VividInitialAudioPreference.selectedOrdinal(
            manual: preferredAudioTrackIndex,
            tracks: audioTracks,
            preferredLanguage: audioLanguagePreference
        )
        let startingAudioLanguage = audioOrdinal.flatMap { ordinal in
            audioTracks.indices.contains(ordinal) ? audioTracks[ordinal].language : nil
        }

        // Only preferences the caller passes in choose subtitles. A server's
        // remembered subtitle mode or track never does: with no preferences
        // the plan starts without subtitles and the player picks from
        // Settings > Subtitles once the file is open.
        let subtitlePrefs = initialSubtitlePreferences
        let subtitles = Self.initialProtocolV3SubtitleIntent(
            version: version,
            explicitFFmpegIndex: preferredSubtitleTrackIndex,
            explicitCombinedIndex: preferredProtocolV3SubtitleIndex,
            preferredLanguage: subtitlePrefs?.preferredLanguage,
            additionalPreferredLanguages: subtitlePrefs?.additionalPreferredLanguages ?? [],
            mode: subtitlePrefs == nil ? .off : subtitlePrefs?.mode,
            showForced: subtitlePrefs?.showForced ?? false,
            forcedOnly: subtitlePrefs?.forcedOnly ?? false,
            preferAccessibilityTracks: subtitlePrefs?.preferAccessibilityTracks ?? false,
            disableWhenNoLanguageMatch: subtitlePrefs?.disableWhenNoLanguageMatch ?? false,
            trackSignature: subtitlePrefs?.trackSignature,
            currentAudioLanguage: startingAudioLanguage
        )
        let startAt = resolvedStartPosition(
            startFromBeginning: startFromBeginning,
            explicitResumePosition: Self.usableResumePosition(resumePosition),
            storedResumePosition: Self.usableResumePosition(detail.userData?.positionSeconds),
            watchDetail: detail,
            selectedVersion: version,
            allowNearEndResume: allowNearEndResume
        )
        logger.info(
            "Selected version fileId=\(version.fileId, privacy: .public) resolution=\(version.resolution ?? "unknown", privacy: .public) codec=\(version.codecVideo ?? "unknown", privacy: .public) bitrate=\(version.bitrate ?? 0)"
        )

        // The server plans from this quality. An explicit choice in the player
        // goes as it is, not as a rung worked out from the chosen file.
        let sendsQualityAsIs = preferredQualityOverride != nil || PlaybackFallbackMode.matching(quality) != nil
        let fileWasChosen = preferredFileId != nil
            || (prefersLastUsedVersion && version.fileId == detail.userData?.lastFileId)
        let planningQuality = sendsQualityAsIs
            ? quality
            : requestedQualityPreference(preferredQuality: quality, selectedVersion: version, hasManualSelection: fileWasChosen)

        let profileId = await TokenStore.shared.getProfileId() ?? ""
        if profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PlaybackV3TerminalFailure(
                reason: "profile_required",
                message: "Select a profile before starting playback.",
                retryable: false
            )
        }
        // Emby and Jellyfin only: the server draws a chosen bitmap subtitle
        // into a transcode. Silo's plan and subtitle intent don't use it.
        let burnIn = ServerSubtitleBurnIn.bitmapStreamIndex(serverBurnInSubtitleIndex, in: version)

        if let jellyfinMetadata {
            try validateJellyfinStart(attempt)
            let (prepared, playback) = try await JellyfinPlayback.prepare(
                metadata: jellyfinMetadata, detail: detail, version: version,
                start: startAt ?? 0, audioOrdinal: audioOrdinal,
                subtitleIndex: subtitles.ffmpegStreamIndex, bitrateKbps: bitrateCap,
                quality: planningQuality, burnInSubtitleIndex: burnIn
            )
            try await adoptJellyfinPlayback(playback, prepared: prepared, metadata: jellyfinMetadata, attempt: attempt)
            return prepared
        }
        if let embyMetadata {
            let (prepared, playback) = try await EmbyPlayback.prepare(
                metadata: embyMetadata, detail: detail, version: version,
                start: startAt ?? 0, audioOrdinal: audioOrdinal,
                subtitleIndex: subtitles.ffmpegStreamIndex, bitrateKbps: bitrateCap,
                quality: planningQuality, burnInSubtitleIndex: burnIn
            )
            embyPlayback = playback
            adoptSession(prepared.session)
            return prepared
        }
        // Silo only plays through Protocol V3: `/api/v1/playback/start`
        // turns down every other `protocol_version`, so there's no older
        // path to fall back on. The audio is the viewer's pick or the
        // Settings language chosen above, never the server's remembered one.
        return try await startProtocolV3(
            watchDetail: detail,
            selectedVersion: version,
            profileId: profileId,
            qualityPreference: planningQuality,
            bandwidthCapKbps: bitrateCap,
            startPosition: startAt,
            audioTrackIndex: audioOrdinal,
            subtitleTrackIndex: subtitles.ffmpegStreamIndex,
            subtitleCombinedIndex: subtitles.combinedIndex
        )
    }

    /// The position if it's finite and not negative, otherwise nil.
    private static func usableResumePosition(_ position: Double?) -> Double? {
        position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// The version the request asks for: the file asked for, else the one
    /// used last time (when the caller wants that), else the best fit for
    /// the quality preference.
    private func initialVersion(
        in detail: WatchDetail,
        preferredFileId: Int?,
        prefersLastUsedVersion: Bool,
        preferredQuality: String?
    ) -> FileVersion {
        let versions = detail.versions
        let lastFileId = detail.userData?.lastFileId
        if let wanted = preferredFileId, let chosen = versions.first(where: { $0.fileId == wanted }) {
            logger.info("Using manually selected version fileId=\(chosen.fileId, privacy: .public)")
            return chosen
        }
        if prefersLastUsedVersion, let lastFileId, let previous = versions.first(where: { $0.fileId == lastFileId }) {
            logger.info("Resuming last-used version fileId=\(previous.fileId, privacy: .public)")
            return previous
        }
        if let wanted = preferredFileId {
            logger.warning("Requested fileId=\(wanted, privacy: .public) is unavailable; falling back to automatic selection")
        }
        return Self.selectVersion(from: versions, lastFileId: lastFileId, preferredQuality: preferredQuality)
    }

    /// Makes a prepared Jellyfin playback the current one and retires the
    /// one it replaces. PlaybackInfo doesn't open a stream
    /// (AutoOpenLiveStream is false), so a candidate that loses is simply
    /// dropped: a Jellyfin Stopped report would end this client's current
    /// playback, not just the candidate.
    ///
    /// `retiringAt` stops the outgoing playback at that position rather than
    /// its last report, for an AirPlay hand-off that moves on from where
    /// Lucid is right now. A playback that never reported still stops
    /// without a position, so it saves no resume point.
    private func adoptJellyfinPlayback(
        _ playback: JellyfinPlayback,
        prepared: PreparedPlayback,
        metadata: JellyfinPlayback.Metadata,
        attempt: UUID,
        retiringAt position: Double? = nil
    ) async throws {
        try validateJellyfinStart(attempt)
        await waitForJellyfinTransition()
        try validateJellyfinStart(attempt)

        jellyfinTransitionInProgress = true
        jellyfinTransitionPlayback = jellyfinPlayback
        defer { finishJellyfinTransition() }

        /// Re-checks the sign-in, then that this start is still wanted.
        func confirmSignIn() async throws {
            try await metadata.connection.validate()
            try validateJellyfinStart(attempt)
        }

        // New progress waits for the transition, so this lets the last write
        // land before the old playback stops.
        _ = await progressWriteTail?.value
        try validateJellyfinStart(attempt)
        try await confirmSignIn()

        // Let go of the old playback before retiring it, so a cancelled
        // replacement can never leave the bridge holding one that's stopped.
        let outgoing = jellyfinPlayback
        jellyfinPlayback = nil
        sessionId = nil
        currentSession = nil
        if let outgoing {
            // A separate task, so cancelling this start can't cut the stop
            // short.
            let stopsAtPosition = position != nil && outgoing === reportedJellyfinPlayback
            let stop = Task {
                if stopsAtPosition, let position {
                    try await outgoing.report(position: position, isPaused: true, stopping: true)
                } else {
                    try await outgoing.retireForReplacement()
                }
            }
            if case .failure(let error) = await stop.result {
                logger.warning("Jellyfin replacement stop failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
            }
            try validateJellyfinStart(attempt)
        }
        try await confirmSignIn()
        jellyfinPlayback = playback
        adoptSession(prepared.session)
    }

    private func adoptSession(_ session: PlaybackSessionResponse) {
        sessionId = session.sessionId
        currentSession = session
        consecutiveProgressFailures = 0
        #if os(iOS) || os(tvOS)
        AppHealthMonitor.playMethodChanged(session.playMethod)
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "PlaybackSession",
            message: "playback session adopted",
            attrs: ["session_id": .string(session.sessionId), "play_method": .string(session.playMethod)]
        )
        #endif
    }

    /// Where playback starts: 0 when starting over, otherwise the explicit or
    /// stored resume point. Measured against the shorter of the two duration
    /// hints, a resume point in the last five seconds starts again from 0,
    /// unless `allowNearEndResume` is set, in which case a point at or past
    /// the end is moved just inside it.
    private func resolvedStartPosition(
        startFromBeginning: Bool,
        explicitResumePosition: Double?,
        storedResumePosition: Double?,
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        allowNearEndResume: Bool
    ) -> Double? {
        if startFromBeginning { return 0 }
        guard let wanted = explicitResumePosition ?? storedResumePosition else { return nil }
        let hints: [Double?] = [watchDetail.userData?.durationSeconds, selectedVersion.duration]
        guard let length = hints.compactMap({ $0 }).filter({ $0.isFinite && $0 > 0 }).min() else {
            return wanted
        }

        if allowNearEndResume {
            if wanted < length { return wanted }
            let inside = max(0, length - Self.pastEndBackoff)
            logger.warning(
                "Resume position \(wanted, privacy: .public) reached/passed duration hint \(length, privacy: .public); clamping transient resume to \(inside, privacy: .public)"
            )
            return inside
        }

        if wanted < max(0, length - Self.nearEndRestartWindow) { return wanted }
        logger.info(
            "Suppressing resume position \(wanted, privacy: .public) near duration hint \(length, privacy: .public); restarting from beginning"
        )
        return 0
    }

    // MARK: - Protocol V3 start

    private func startProtocolV3(
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        profileId: String,
        qualityPreference: String?,
        bandwidthCapKbps: Int?,
        startPosition: Double?,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?,
        subtitleCombinedIndex: Int? = nil
    ) async throws -> PreparedPlayback {
        let combinedIndex = subtitleCombinedIndex ?? subtitleTrackIndex.flatMap {
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(ffmpegStreamIndex: $0, in: selectedVersion)
        }
        let accepted = try await requestStartPlan(
            detail: watchDetail,
            version: selectedVersion,
            profileId: profileId,
            quality: qualityPreference,
            bandwidthCapKbps: bandwidthCapKbps,
            startPosition: startPosition,
            audioIndex: audioTrackIndex,
            subtitleCombinedIndex: combinedIndex
        )

        holdPendingDecision(candidateSession: accepted.sessionId, candidatePlan: accepted.attempt.plan.planId)
        activeProtocolV3 = accepted.attempt
        protocolV3FirstFramePlanIds.removeAll()
        adoptSession(accepted.session)
        let plan = accepted.attempt.plan
        logger.info("Protocol V3 plan selected id=\(plan.planId, privacy: .public) delivery=\(plan.delivery, privacy: .public)")
        return Self.preparedPlayback(
            from: accepted.attempt,
            detail: watchDetail,
            version: accepted.version,
            session: accepted.session
        )
    }

    /// Asks Silo for a starting plan and checks Vivid can play it. Every
    /// path out that doesn't hand the plan back retires the session the
    /// server allocated.
    ///
    /// With `airPlayReceiverServerURL` (iPhone and iPad) the attempt is for
    /// an AirPlay receiver instead: it declares the receiver's capabilities
    /// and no header-authenticated media, so Silo signs the plan's URLs with
    /// a session-scoped stream reference, and the plan is checked as one the
    /// receiver can fetch by itself.
    private func requestStartPlan(
        detail: WatchDetail,
        version: FileVersion,
        profileId: String,
        quality: String?,
        bandwidthCapKbps: Int?,
        startPosition: Double?,
        audioIndex: Int?,
        subtitleCombinedIndex: Int?,
        airPlayReceiverServerURL: String? = nil
    ) async throws -> AcceptedStart {
        let capability = try await PlaybackV3CapabilityGate.shared.requireNeutralProtocolV3()
        #if os(iOS)
        let receiverServerURL = airPlayReceiverServerURL
        #else
        let receiverServerURL: String? = nil
        #endif
        // Optional. A server that never advertises authorised media origins
        // isn't sent the token, and the attempt stays on the API origin. A
        // receiver attempt never asks: it only applies to header-authenticated
        // media.
        let asksForMediaOrigins = receiverServerURL == nil && capability.authorizedMediaOrigins

        #if os(iOS)
        let snapshot = receiverServerURL == nil
            ? ApplePlaybackV3Capabilities.snapshot() : SiloAirPlayReceiver.snapshot()
        let clientFeatures = receiverServerURL == nil
            ? ApplePlaybackV3Capabilities.startFeatures(authorizedMediaOrigins: asksForMediaOrigins)
            : SiloAirPlayReceiver.startFeatures
        #else
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        let clientFeatures = ApplePlaybackV3Capabilities.startFeatures(authorizedMediaOrigins: asksForMediaOrigins)
        #endif
        cmpLog("[CMP-OUTPUT] phase=start \(snapshot.outputDiagnosticsLogFields)")
        let playbackAttemptId = "apple:\(UUID().uuidString.lowercased())"
        let fileId = version.fileId
        let audio = audioIndex.flatMap { $0 < 0 ? nil : $0 }
        let request = PlaybackV3StartRequest(
            protocolVersion: PlaybackProtocolV3.version,
            clientFeatures: clientFeatures,
            fileId: fileId,
            profileId: profileId,
            playbackAttemptId: playbackAttemptId,
            qualityPreference: serverQualityPreference(quality),
            subtitleFidelityPreference: "preserve",
            progressPersistence: nil,
            startPosition: startPosition,
            audioTrackId: audio.map { Self.trackIdentifier(fileId: fileId, kind: "audio", index: $0) },
            audioTrackIndex: audio,
            subtitleTrackId: subtitleCombinedIndex.flatMap {
                $0 < 0 ? nil : Self.trackIdentifier(fileId: fileId, kind: "subtitle", index: $0)
            },
            subtitleTrackIndex: subtitleCombinedIndex,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: bandwidthCapKbps,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )

        logger.info("Starting protocol V3 attempt=\(playbackAttemptId, privacy: .public) fileId=\(fileId, privacy: .public)")
        // The caller cancels this task when an autoplay start times out and
        // when the player closes. The POST allocates a server session, so it
        // runs shielded from cancellation, and anything it allocated after
        // the caller left is retired rather than left for the server's idle
        // timeout.
        let response = try await PlaybackCancellationShield.run {
            do {
                return try await VividAPI.shared.startPlaybackV3(request: request)
            } catch HTTPError.network {
                // One more try with the identical request and
                // playback_attempt_id, so an unclear first answer can't
                // create a second logical attempt. It stays inside the shield
                // so the reclaim below sees how it really ended.
                return try await VividAPI.shared.startPlaybackV3(request: request)
            }
        } reclaim: { [self] abandoned in
            if let leftover = Self.allocatedSessionId(in: abandoned) {
                await retireAbandonedSession(leftover, reason: "cancelled_start")
            }
        }

        let plan: PlaybackV3Plan
        let allocated: String
        switch response.validatedForApple() {
        case .terminal(let terminal):
            Task {
                await Self.reportTerminalStart(playbackAttemptId: playbackAttemptId, snapshot: snapshot, terminal: terminal)
            }
            throw PlaybackV3TerminalFailure(reason: terminal.reason, message: terminal.message, retryable: terminal.retryable)
        case .incompatible(let leftover):
            if let leftover {
                await retireAbandonedSession(leftover, reason: "incompatible_start_response")
            }
            throw Self.unrecoverable("invalid_playback_plan", "The server returned an incompatible protocol V3 playback plan.")
        case .playable(let playablePlan, let sessionId):
            plan = playablePlan
            allocated = sessionId
        }

        guard Self.carriesHeaderMedia(response) else {
            await retireAbandonedSession(allocated, reason: "start_without_header_authenticated_media")
            throw Self.unrecoverable(
                "server_upgrade_required",
                "This server did not honor authenticated media transport for the playback plan."
            )
        }
        let receiverStream: AirPlayReceiverStream?
        /// The plan as the bridge keeps it. A receiver plan's signed stream
        /// references stay only in `receiverStream`.
        let storedPlan: PlaybackV3Plan
        do {
            #if os(iOS)
            if let receiverServerURL {
                // Only the v2 delivery routes take the stream reference
                // without headers.
                guard let apiBase = SiloAirPlayReceiver.apiBase(
                    serverURL: receiverServerURL,
                    nativeApiMajor: plan.nativeApiMajor
                ) else { throw SiloAirPlayReceiverError.unsupportedAPIBase }
                receiverStream = try SiloAirPlayReceiver.receiverStream(plan: plan, sessionId: allocated, apiBase: apiBase)
                storedPlan = try Self.planWithoutStreamReferences(plan)
            } else {
                try ApplePlaybackV3PlanAdapter.validate(plan)
                receiverStream = nil
                storedPlan = plan
            }
            #else
            try ApplePlaybackV3PlanAdapter.validate(plan)
            receiverStream = nil
            storedPlan = plan
            #endif
        } catch {
            await retireAbandonedSession(
                allocated,
                reason: receiverServerURL == nil ? "unexecutable_start_plan" : "unexecutable_airplay_receiver_plan"
            )
            throw error
        }
        guard let effective = detail.versions.first(where: { $0.fileId == plan.effectiveMediaFileId }) else {
            await retireAbandonedSession(allocated, reason: "start_effective_file_unavailable")
            throw Self.unrecoverable(
                "effective_file_unavailable",
                "The server selected a media version that is not present in the item response."
            )
        }

        // The server owns plan keys; the client only repeats them back.
        let key = plan.planAttemptKey
        let attempt = SiloAttempt(
            playbackAttemptId: playbackAttemptId,
            planAttemptId: Self.newPlanAttemptId(),
            planAttemptKey: key,
            triedPlanKeys: [key],
            attemptCount: 1,
            clientQualityId: ApplePlaybackQuality.protocolV3QualityId(quality),
            qualityIsServerOwned: false,
            bandwidthCapKbps: bandwidthCapKbps,
            snapshot: snapshot,
            serverFeatures: response.serverFeatures,
            // Only when Vivid asked and the server both advertises and honours
            // it. Otherwise the plan's media URLs have to stay relative to the
            // API, and are checked that way.
            negotiatedAuthorizedMediaOrigins: asksForMediaOrigins
                && response.serverFeatures.contains(PlaybackProtocolV3.authorizedMediaOriginsFeature),
            plan: storedPlan
        )
        let session = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: storedPlan,
            sessionId: allocated,
            selectedVersion: effective,
            serverFeatures: response.serverFeatures
        )
        return AcceptedStart(
            attempt: attempt,
            sessionId: allocated,
            version: effective,
            session: session,
            receiverStream: receiverStream
        )
    }

    // MARK: - Protocol V3 replan

    /// Asks Silo for the next plan after a failure, or for the same route
    /// with a different track, quality, output or seek position. Returns nil
    /// with no Silo session, or for a seek re-anchor the server doesn't
    /// offer. Throws `CancellationError` when a newer load or a stop took
    /// over while the request was out.
    func replanProtocolV3(
        watchDetail: WatchDetail,
        position: Double,
        classification: String,
        message: String,
        operation: String? = nil,
        qualityPreference: String? = nil,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil,
        outputRouteSnapshot: ApplePlaybackV3CapabilitySnapshot? = nil
    ) async throws -> PreparedPlayback? {
        guard var attempt = activeProtocolV3, let liveSessionId = sessionId else { return nil }
        // Settled only now, because the operation depends on what the server
        // advertised for this attempt.
        let operation = operation
            ?? Self.replanOperation(forClassification: classification, serverFeatures: attempt.serverFeatures)
        let stamp = attempt.stamp
        if attempt.attemptCount >= Self.planAttemptLimit {
            throw await endReplan(
                attempt,
                sessionId: liveSessionId,
                reason: "attempt_limit_reached",
                message: "Playback recovery exhausted the protocol V3 route ladder."
            )
        }

        let outputChanged = classification == "output_route_changed"
        if outputChanged {
            attempt.snapshot = outputRouteSnapshot ?? ApplePlaybackV3Capabilities.snapshot()
            cmpLog("[CMP-OUTPUT] phase=route_change \(attempt.snapshot.outputDiagnosticsLogFields)")
        }

        let isSeekReanchor = operation == PlaybackProtocolV3.ReplanOperation.seekReanchor
        if isSeekReanchor, !attempt.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
            return nil
        }
        let intentOperations: Set<String> = [
            PlaybackProtocolV3.ReplanOperation.trackChange,
            PlaybackProtocolV3.ReplanOperation.qualityChange,
            PlaybackProtocolV3.ReplanOperation.outputChange,
        ]
        // A new intent (or a new output) starts the route ladder over, a
        // failure rules out every plan key tried so far, and a seek re-anchor
        // stays on the current plan.
        let restartsLadder = intentOperations.contains(operation) || outputChanged
        let excludedKeys: [String]
        if isSeekReanchor {
            excludedKeys = attempt.triedPlanKeys
        } else if restartsLadder {
            excludedKeys = []
        } else {
            excludedKeys = Set(attempt.triedPlanKeys + [attempt.planAttemptKey]).sorted()
        }
        let tracks = requestedTracks(
            for: attempt,
            keepingPlanTracks: isSeekReanchor,
            classification: classification,
            audioIndex: audioTrackIndex,
            subtitleIndex: subtitleTrackIndex
        )
        let target = position.isFinite ? max(0, position) : 0

        let pick = qualityPreference.map {
            ApplePlaybackQuality.protocolV3Selection(requestedQualityId: $0, availableQualities: attempt.plan.availableQualities)
        }
        let clientQualityId = pick?.clientQualityId ?? attempt.clientQualityId
        let serverOwnsQuality = pick?.isServerOwned ?? attempt.qualityIsServerOwned
        let qualityForServer = pick?.serverPreference
            ?? (serverOwnsQuality ? clientQualityId : serverQualityPreference(clientQualityId))
        // A quality pick comes with its own cap, which can be none at all.
        let bandwidthCap: Int? = if let pick { pick.bandwidthCapKbps } else { attempt.bandwidthCapKbps }

        #if os(iOS) || os(tvOS)
        // The server's route event below is the real record, but it only
        // exists if its POST succeeds, and it lands in the server's telemetry
        // rather than the viewer's diagnostics. The viewer sees a replan as a
        // reload, so the diagnostics note that one happened, why and where,
        // leaving out the free-text message the classification already sums
        // up.
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "PlaybackSession",
            message: "protocol v3 replan requested",
            attrs: [
                "session_id": .string(liveSessionId),
                "reason": .string(classification),
                "play_method": .string(attempt.plan.delivery),
                "position_ms": .int(Self.diagnosticsPositionMilliseconds(target)),
            ]
        )
        #endif
        // Telemetry is best effort and mustn't hold up the route change with
        // a round trip of its own. The attempt is copied now, so a later
        // replan can't change which attempt the event names.
        let attemptForEvent = attempt
        let eventName = isSeekReanchor
            ? "seek_reanchor_requested"
            : restartsLadder ? "plan_invalidated" : "plan_failed"
        Task {
            await emitProtocolV3Event(
                active: attemptForEvent,
                sessionId: liveSessionId,
                event: eventName,
                classification: classification,
                fallbackReason: nil,
                diagnostics: ["error_cause": String(message.prefix(512))]
            )
        }
        guard isStillCurrent(stamp, sessionId: liveSessionId) else { throw CancellationError() }

        let request = PlaybackV3ReplanRequest(
            protocolVersion: PlaybackProtocolV3.version,
            // A replan can't add or drop the negotiated origin token, so it
            // repeats what the start chose.
            clientFeatures: ApplePlaybackV3Capabilities.startFeatures(authorizedMediaOrigins: attempt.negotiatedAuthorizedMediaOrigins),
            operation: operation,
            playbackAttemptId: attempt.playbackAttemptId,
            replanRequestId: "apple-replan:\(UUID().uuidString.lowercased())",
            failedPlanId: attempt.plan.planId,
            planAttemptId: attempt.planAttemptId,
            planAttemptKey: attempt.planAttemptKey,
            attemptedPlanKeys: excludedKeys,
            attemptCount: restartsLadder ? 1 : attempt.attemptCount,
            qualityPreference: qualityForServer,
            positionSeconds: target,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: bandwidthCap,
            selectedTracks: tracks,
            failure: Self.replanFailure(operation: operation, classification: classification, message: message),
            // Vivid never alters a server plan locally, so there's never a
            // change to fold into the server's next attempt key.
            localMutations: [],
            clientCapabilities: attempt.snapshot.capabilities,
            clientPlaybackContext: attempt.snapshot.context
        )
        let response = try await VividAPI.shared.replanPlaybackV3(sessionId: liveSessionId, request: request)
        let decision = response.validatedForApple()
        guard isStillCurrent(stamp, sessionId: liveSessionId) else {
            retireSupersededAllocation(decision)
            throw CancellationError()
        }

        let nextPlan: PlaybackV3Plan
        let nextSessionId: String
        switch decision {
        case .terminal(let terminal):
            await emitProtocolV3Terminal(active: attempt, sessionId: liveSessionId, reason: terminal.reason, message: terminal.message)
            throw PlaybackV3TerminalFailure(reason: terminal.reason, message: terminal.message, retryable: terminal.retryable)
        case .incompatible(let leftover):
            throw await endReplan(
                attempt,
                sessionId: liveSessionId,
                retiring: leftover,
                retireReason: "incompatible_replan_response",
                reason: "invalid_replan",
                message: "The server returned an incompatible protocol V3 replacement plan."
            )
        case .playable(let playablePlan, let allocated):
            nextPlan = playablePlan
            nextSessionId = allocated
        }

        guard Self.carriesHeaderMedia(response) else {
            throw await endReplan(
                attempt,
                sessionId: liveSessionId,
                retiring: nextSessionId,
                retireReason: "replan_without_header_authenticated_media",
                reason: "server_upgrade_required",
                message: "The server did not preserve authenticated media transport during replanning."
            )
        }
        do {
            try ApplePlaybackV3PlanAdapter.validate(nextPlan)
        } catch {
            await endReplan(
                attempt,
                sessionId: liveSessionId,
                retiring: nextSessionId,
                retireReason: "unexecutable_replan_plan",
                reason: "invalid_replan",
                message: error.localizedDescription
            )
            throw error
        }
        let nextKey = nextPlan.planAttemptKey
        if !isSeekReanchor, excludedKeys.contains(nextKey) {
            throw await endReplan(
                attempt,
                sessionId: liveSessionId,
                retiring: nextSessionId,
                retireReason: "replan_loop_detected",
                reason: "replan_loop_detected",
                message: "The server returned a protocol V3 plan that already failed on this output route."
            )
        }
        guard let nextVersion = watchDetail.versions.first(where: { $0.fileId == nextPlan.effectiveMediaFileId }) else {
            throw await endReplan(
                attempt,
                sessionId: liveSessionId,
                retiring: nextSessionId,
                retireReason: "replan_effective_file_unavailable",
                reason: "effective_file_unavailable",
                message: "The replacement plan selected an unavailable media version."
            )
        }
        let nextSession = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: nextPlan,
            sessionId: nextSessionId,
            selectedVersion: nextVersion,
            serverFeatures: response.serverFeatures
        )

        if isSeekReanchor {
            // A re-anchor moves the same plan to a new position. If anything
            // else changed, the server didn't do what it was asked.
            let faithful = nextSessionId == liveSessionId
                && response.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature)
                && nextKey == attempt.planAttemptKey
                && Self.keepsRoute(of: attempt.plan, in: nextPlan)
            if !faithful {
                throw await endReplan(
                    attempt,
                    sessionId: liveSessionId,
                    retiring: nextSessionId,
                    retireReason: "invalid_seek_reanchor_response",
                    reason: "invalid_seek_reanchor_response",
                    message: "The server changed the route or playback intent during a V3 seek re-anchor."
                )
            }
        } else {
            attempt.planAttemptId = Self.newPlanAttemptId()
            attempt.planAttemptKey = nextKey
            attempt.triedPlanKeys = excludedKeys + [nextKey]
            attempt.attemptCount = restartsLadder ? 1 : attempt.attemptCount + 1
        }
        attempt.serverFeatures = response.serverFeatures
        attempt.plan = nextPlan
        attempt.clientQualityId = clientQualityId
        attempt.qualityIsServerOwned = serverOwnsQuality
        attempt.bandwidthCapKbps = bandwidthCap

        // The route event allowlist names the seek target
        // `target_source_position_seconds`; `position_seconds` would be
        // dropped.
        holdPendingDecision(
            candidateSession: nextSessionId,
            candidatePlan: nextPlan.planId,
            commitEvent: isSeekReanchor ? "seek_reanchored" : nil,
            commitAttributes: isSeekReanchor ? ["target_source_position_seconds": String(target)] : [:]
        )
        activeProtocolV3 = attempt
        adoptSession(nextSession)
        return Self.preparedPlayback(from: attempt, detail: watchDetail, version: nextVersion, session: nextSession)
    }

    /// True when a re-anchor's plan keeps the route and intent of the plan
    /// it moved.
    private static func keepsRoute(of current: PlaybackV3Plan, in next: PlaybackV3Plan) -> Bool {
        next.delivery == current.delivery
            && next.effectiveRecipe == current.effectiveRecipe
            && next.selectedTracks == current.selectedTracks
            && next.transformations == current.transformations
            && next.appliedQuirks == current.appliedQuirks
            && next.runtimeCorrections == current.runtimeCorrections
    }

    /// The tracks a replan asks for. A seek re-anchor keeps the plan's
    /// tracks. Otherwise a valid audio index replaces the plan's audio, and
    /// the subtitle only changes for a subtitle change, where a missing or
    /// negative index turns subtitles off.
    private func requestedTracks(
        for attempt: SiloAttempt,
        keepingPlanTracks: Bool,
        classification: String,
        audioIndex: Int?,
        subtitleIndex: Int?
    ) -> PlaybackV3SelectedTracks {
        let planTracks = attempt.plan.selectedTracks
        if keepingPlanTracks { return planTracks }
        let fileId = attempt.plan.effectiveMediaFileId
        let identity = { (kind: String, index: Int?) -> PlaybackV3TrackIdentity? in
            guard let index, index >= 0 else { return nil }
            return PlaybackV3TrackIdentity(id: Self.trackIdentifier(fileId: fileId, kind: kind, index: index), index: index)
        }
        let subtitle = classification == "subtitle_track_changed"
            ? identity("subtitle", subtitleIndex)
            : planTracks.subtitle
        return PlaybackV3SelectedTracks(audio: identity("audio", audioIndex) ?? planTracks.audio, subtitle: subtitle)
    }

    /// Ends a replan that can't carry on: retires the session it allocated
    /// (unless that's the live one), records the terminal route event and
    /// hands back the failure to throw.
    @discardableResult
    private func endReplan(
        _ attempt: SiloAttempt,
        sessionId liveSessionId: String,
        retiring allocated: String? = nil,
        retireReason: String? = nil,
        reason: String,
        message: String
    ) async -> PlaybackV3TerminalFailure {
        if let allocated, let retireReason, allocated != liveSessionId {
            await retireAbandonedSession(allocated, reason: retireReason)
        }
        await emitProtocolV3Terminal(active: attempt, sessionId: liveSessionId, reason: reason, message: message)
        return Self.unrecoverable(reason, message)
    }

    /// False once the task is cancelled, the session has changed or a newer
    /// attempt has replaced the one `stamp` names.
    private func isStillCurrent(_ stamp: AttemptStamp, sessionId expected: String) -> Bool {
        guard !Task.isCancelled, sessionId == expected, currentSession?.sessionId == expected else { return false }
        return activeProtocolV3?.stamp == stamp
    }

    /// Retires a session that an overtaken replan allocated, unless it's the
    /// one still in use.
    private func retireSupersededAllocation(_ decision: PlaybackV3DecisionValidation) {
        let allocated: String? = switch decision {
        case .playable(_, let id): id
        case .incompatible(let id): id
        case .terminal: nil
        }
        if let allocated, allocated != sessionId {
            stopStaleSession(allocated)
        }
    }

    // MARK: - Protocol V3 transitions

    /// Holds a server decision as pending until Vivid commits the matching
    /// load, remembering the committed state in case it has to roll back.
    private func holdPendingDecision(
        candidateSession: String,
        candidatePlan: String,
        commitEvent: String? = nil,
        commitAttributes: [String: String] = [:]
    ) {
        // A newer load replacing a candidate that never committed first puts
        // the committed state back and retires the abandoned allocation. A
        // replan of that same uncommitted candidate reuses its session, which
        // is about to be held again; retiring it would delete the session the
        // engine is about to read and leave playback retrying 404s.
        rollbackAnyPendingProtocolV3Transition(retainingSessionId: candidateSession)
        pendingProtocolV3Transition = PendingDecision(
            priorSessionId: sessionId,
            previousSession: currentSession,
            priorAttempt: activeProtocolV3,
            candidateSession: candidateSession,
            candidatePlan: candidatePlan,
            commitEvent: commitEvent,
            commitAttributes: commitAttributes
        )
    }

    /// Commits the server decision once Vivid's load has committed. False
    /// when a newer decision or a teardown got there first.
    func commitPendingProtocolV3Transition(_ prepared: PreparedPlayback) -> Bool {
        guard let pending = livePendingDecision(for: prepared) else { return false }
        pendingProtocolV3Transition = nil
        retireReplacedSession(of: pending)
        guard let event = pending.commitEvent, let committed = activeProtocolV3 else { return true }
        // Route telemetry is best effort, and awaiting it here would let a
        // teardown or a newer load into the actor between committing and
        // answering the player, which would then act on stale state.
        Task {
            await emitProtocolV3Event(
                active: committed,
                sessionId: pending.candidateSession,
                event: event,
                classification: nil,
                fallbackReason: nil,
                diagnostics: pending.commitAttributes
            )
        }
        return true
    }

    /// The committed session, but only while it still belongs to the exact
    /// plan the player is recovering, so the player can rebuild that plan
    /// with fresh request headers without moving the server's route ladder.
    func committedProtocolV3Session(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String
    ) -> PlaybackSessionResponse? {
        let matches = pendingProtocolV3Transition == nil
            && sessionId == expectedSessionId
            && currentSession?.sessionId == expectedSessionId
            && activeProtocolV3?.plan.planId == expectedPlanId
        return matches ? currentSession : nil
    }

    /// Promotes a candidate Vivid couldn't open, only so the player can report
    /// that failed attempt and ask for the next route. It isn't a commit: no
    /// success event, no realtime binding and no first frame. The failed
    /// candidate does become the current attempt, because a V3 replan has to
    /// name the plan that actually failed.
    func promotePendingProtocolV3TransitionForRecovery(_ prepared: PreparedPlayback) -> Bool {
        guard let pending = livePendingDecision(for: prepared) else { return false }
        pendingProtocolV3Transition = nil
        retireReplacedSession(of: pending)
        return true
    }

    /// Puts back the last committed state after a bad URL, a cancellation or
    /// a failed load, and retires a separate candidate session. A replan on
    /// the same session only restores client state; the server keeps its own
    /// attempt history for the next replan.
    func rollbackPendingProtocolV3Transition(_ prepared: PreparedPlayback) {
        if pendingDecision(for: prepared) != nil {
            rollbackAnyPendingProtocolV3Transition()
        }
    }

    /// The pending decision, if it's the one for `prepared`.
    private func pendingDecision(for prepared: PreparedPlayback) -> PendingDecision? {
        guard let pending = pendingProtocolV3Transition,
              prepared.session.sessionId == pending.candidateSession,
              prepared.protocolV3?.plan.planId == pending.candidatePlan else {
            return nil
        }
        return pending
    }

    /// The pending decision for `prepared`, while its candidate is still the
    /// bridge's session and plan.
    private func livePendingDecision(for prepared: PreparedPlayback) -> PendingDecision? {
        guard let pending = pendingDecision(for: prepared),
              pending.candidateSession == sessionId,
              pending.candidatePlan == activeProtocolV3?.plan.planId else {
            return nil
        }
        return pending
    }

    /// Retires the session a committed or promoted decision replaced.
    private func retireReplacedSession(of pending: PendingDecision) {
        guard let prior = pending.priorSessionId, prior != pending.candidateSession else { return }
        stopStaleSession(prior)
    }

    /// `retainingSessionId` names a session the caller is about to hold
    /// again, which stays alive instead of being retired as abandoned.
    private func rollbackAnyPendingProtocolV3Transition(retainingSessionId: String? = nil) {
        guard let pending = pendingProtocolV3Transition else { return }
        pendingProtocolV3Transition = nil
        sessionId = pending.priorSessionId
        currentSession = pending.previousSession
        activeProtocolV3 = pending.priorAttempt
        let retire = Self.shouldRetireRolledBackCandidate(
            candidateSessionId: pending.candidateSession,
            priorSessionId: pending.priorSessionId,
            retainingSessionId: retainingSessionId
        )
        if retire {
            stopStaleSession(pending.candidateSession)
        }
    }

    /// The clean-up has to outlive the cancelled request that left the
    /// session behind, so it runs in its own task without the caller's
    /// cancellation. It's best effort; the server's idle timeout is the
    /// backstop.
    private func stopStaleSession(_ staleSessionId: String) {
        Task {
            await self.retireAbandonedSession(staleSessionId, reason: "stale_allocation")
        }
    }

    /// Retires a session this client allocated but will never play. Nothing
    /// can recover a failure here (the server reclaims idle sessions itself),
    /// but a lingering session holds one of the viewer's slots, so it's
    /// logged.
    private func retireAbandonedSession(_ abandonedSessionId: String, reason: String) async {
        do {
            try await VividAPI.shared.stopPlayback(sessionId: abandonedSessionId)
        } catch {
            logger.error(
                "abandoned-session stop failed for \(abandonedSessionId, privacy: .public) (\(reason, privacy: .public)); server-side session may linger until idle timeout: \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }
    }

    // MARK: - Protocol V3 route events

    func reportProtocolV3PlanExecutionStarted(_ prepared: PreparedPlayback) async {
        guard let attempt = activeProtocolV3,
              let liveSessionId = sessionId,
              liveSessionId == prepared.session.sessionId,
              attempt.plan.planId == prepared.protocolV3?.plan.planId else { return }
        await reportRuntimeCorrections(of: attempt, sessionId: liveSessionId, stage: "applied")
    }

    /// Reports a plan's first frame, once per plan, and then its runtime
    /// corrections as succeeded.
    func reportProtocolV3FirstFrame(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String,
        milliseconds: Int?
    ) async {
        guard let attempt = activeProtocolV3,
              let liveSessionId = sessionId,
              liveSessionId == expectedSessionId,
              attempt.plan.planId == expectedPlanId,
              protocolV3FirstFramePlanIds.insert(attempt.plan.planId).inserted else { return }
        let diagnostics = milliseconds.map { ["first_frame_ms": String(max(0, $0))] } ?? [:]
        await emitProtocolV3Event(
            active: attempt,
            sessionId: liveSessionId,
            event: "first_frame",
            classification: nil,
            fallbackReason: nil,
            diagnostics: diagnostics
        )
        await reportRuntimeCorrections(of: attempt, sessionId: liveSessionId, stage: "succeeded")
    }

    /// One `runtime_correction_<stage>` event per correction in the plan.
    private func reportRuntimeCorrections(of attempt: SiloAttempt, sessionId: String, stage: String) async {
        for correction in attempt.plan.runtimeCorrections {
            await emitProtocolV3Event(
                active: attempt,
                sessionId: sessionId,
                event: "runtime_correction_\(stage)",
                classification: nil,
                fallbackReason: nil,
                diagnostics: ["correction_id": correction, "correction_stage": stage]
            )
        }
    }

    private func emitProtocolV3Event(
        active attempt: SiloAttempt,
        sessionId: String,
        event: String,
        classification: String?,
        fallbackReason: String?,
        diagnostics: [String: String]
    ) async {
        let routeEvent = PlaybackV3RouteEvent(
            protocolVersion: PlaybackProtocolV3.version,
            playbackAttemptId: attempt.playbackAttemptId,
            sessionId: sessionId,
            planId: attempt.plan.planId,
            planAttemptId: attempt.planAttemptId,
            planAttemptKey: attempt.planAttemptKey,
            event: event,
            failureClassification: classification,
            fallbackReason: fallbackReason,
            appliedQuirkIds: attempt.plan.appliedQuirks.map(\.id),
            quirkRegistryRevision: attempt.plan.appliedQuirks.first?.registryRevision,
            outputContextId: attempt.snapshot.outputContextId,
            diagnostics: diagnostics
        )
        do {
            try await VividAPI.shared.reportPlaybackRouteEventV3(routeEvent)
        } catch {
            logger.warning("Protocol V3 route event \(routeEvent.event, privacy: .public) failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
        }
    }

    private func emitProtocolV3Terminal(
        active attempt: SiloAttempt,
        sessionId: String,
        reason: String,
        message: String
    ) async {
        #if os(iOS) || os(tvOS)
        // Every dead end of the route ladder passes through here, so this one
        // breadcrumb covers them all. `reason` is the server's stable token;
        // the prose `message` is deliberately left out.
        DiagTrace.breadcrumb(
            .essential,
            level: .error,
            category: .playback,
            tag: "PlaybackSession",
            message: "protocol v3 route exhausted",
            attrs: [
                "session_id": .string(sessionId),
                "reason": .string(reason),
                "play_method": .string(attempt.plan.delivery),
            ]
        )
        #endif
        await emitProtocolV3Event(
            active: attempt,
            sessionId: sessionId,
            event: "terminal",
            classification: nil,
            fallbackReason: reason,
            diagnostics: ["error_cause": String(message.prefix(512))]
        )
    }

    // MARK: - Progress

    /// Proves the Silo session still accepts this sign-in by reporting
    /// progress. Throws `CancellationError` when the session changed (or for
    /// Emby, Jellyfin or an unusable position) and a URL error when the
    /// report failed.
    func refreshPlaybackAuthentication(sessionId expectedSession: String, position: Double, isPaused: Bool) async throws {
        guard sessionId == expectedSession, embyPlayback == nil, jellyfinPlayback == nil,
              position.isFinite, position >= 0 else { throw CancellationError() }
        let result = await reportProgress(position: position, isPaused: isPaused, eligible: position > 0)
        guard result == .success || result == .deferred else { throw URLError(.cannotConnectToHost) }
        guard sessionId == expectedSession else { throw CancellationError() }
    }

    /// Reports the position to the current session, after any earlier write.
    /// An ineligible position (before the first frame) only pings Emby and
    /// Jellyfin and reports zero to Silo; Silo answers `deferred` only when
    /// that zero write succeeds. A `completedContentId` makes the position
    /// eligible and marks that item watched: Emby and Jellyfin only after a
    /// successful report, Silo whatever the position write returned.
    func reportProgress(position: Double, isPaused: Bool, eligible: Bool, completedContentId: String? = nil) async -> PlaybackProgressReportResult {
        if jellyfinTransitionInProgress {
            let expectedSession = sessionId
            let completingPlayback = jellyfinTransitionPlayback
            await waitForJellyfinTransition()
            // A sample from the old stream must not become the new stream's position.
            if expectedSession == nil || sessionId != expectedSession {
                // A terminal watched write still belongs to the captured account and item.
                if let completedContentId, let completingPlayback {
                    return await writeJellyfinCompletion(after: .deferred, contentId: completedContentId, playback: completingPlayback)
                }
                return .deferred
            }
        }
        guard let sid = sessionId, position.isFinite, position >= 0 else { return .transientFailure }
        let emby = embyPlayback
        let jellyfin = jellyfinPlayback
        let eligible = eligible || completedContentId != nil
        let prior = progressWriteTail
        let write = Task { [self] in
            _ = await prior?.value
            if let playback = jellyfin {
                guard eligible else {
                    do {
                        try await playback.ping()
                        return PlaybackProgressReportResult.deferred
                    } catch {
                        return .transientFailure
                    }
                }
                do {
                    try await playback.report(position: position, isPaused: isPaused)
                    self.reportedJellyfinPlayback = playback
                    return await writeJellyfinCompletion(after: .success, contentId: completedContentId, playback: playback)
                } catch {
                    return .transientFailure
                }
            }
            if let playback = emby {
                guard eligible else {
                    do {
                        try await playback.ping()
                        return PlaybackProgressReportResult.deferred
                    } catch {
                        return .transientFailure
                    }
                }
                do {
                    try await playback.report(position: position, isPaused: isPaused)
                    return await writeCompletion(after: .success, contentId: completedContentId, playback: playback)
                } catch {
                    return .transientFailure
                }
            }
            let result = await writeSiloProgress(sessionId: sid, position: eligible ? position : 0, isPaused: isPaused)
            return await writeCompletion(
                after: !eligible && result == .success ? .deferred : result,
                contentId: completedContentId,
                playback: nil
            )
        }
        progressWriteTail = write
        return await write.value
    }

    /// Marks `contentId` watched on Emby (with `playback`) or Silo. Ordered
    /// after the position writes, Stop included, so a server's resume rules
    /// can't undo Vivid's credits or percentage completion decision. A failed
    /// write turns `result` into `transientFailure`, keeping `missingSession`.
    private func writeCompletion(after result: PlaybackProgressReportResult,
                                 contentId: String?, playback: EmbyPlayback?) async -> PlaybackProgressReportResult {
        guard let contentId else { return result }
        do {
            if let playback {
                let connection = await playback.connection
                guard let userID = connection.userID else { return .transientFailure }
                let item = try await connection.object(
                    "GET", "/Users/\(EmbyConnection.id(userID))/Items/\(EmbyConnection.id(contentId))"
                )
                // Emby's played action can bump play counts, so it's only
                // sent when the position or Stop write left the item unwatched.
                if (item["UserData"] as? [String: Any])?["Played"] as? Bool != true {
                    _ = try await connection.request(
                        "POST", "/Users/\(EmbyConnection.id(userID))/PlayedItems/\(EmbyConnection.id(contentId))"
                    )
                }
                await MDBListSyncStore.shared.completedWatch(contentID: contentId, expected: connection.identity)
                await SimklSyncStore.shared.completedWatch(contentID: contentId, expected: connection.identity)
            } else {
                try await VividAPI.shared.setWatched(contentId: contentId, played: true)
            }
            return result
        } catch {
            logger.warning("Watched completion write failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
            return result == .missingSession ? .missingSession : .transientFailure
        }
    }

    /// `writeCompletion` for Jellyfin, which has its own played routes.
    private func writeJellyfinCompletion(after result: PlaybackProgressReportResult,
                                         contentId: String?, playback: JellyfinPlayback?) async -> PlaybackProgressReportResult {
        guard let contentId else { return result }
        do {
            if let playback {
                let connection = await playback.connection
                guard connection.userID != nil else { return .transientFailure }
                let item = try await connection.object("GET", "/Items/\(JellyfinConnection.id(contentId))")
                // Jellyfin's played action can bump play counts, so it's only
                // sent when the position or Stop write left the item unwatched.
                if (item["UserData"] as? [String: Any])?["Played"] as? Bool != true {
                    _ = try await connection.request("POST", "/UserPlayedItems/\(JellyfinConnection.id(contentId))")
                }
                await MDBListSyncStore.shared.completedWatch(contentID: contentId, expected: connection.identity)
                await SimklSyncStore.shared.completedWatch(contentID: contentId, expected: connection.identity)
            } else {
                try await VividAPI.shared.setWatched(contentId: contentId, played: true)
            }
            return result
        } catch {
            logger.warning("Watched completion write failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
            return result == .missingSession ? .missingSession : .transientFailure
        }
    }

    private func writeSiloProgress(sessionId sid: String, position: Double, isPaused: Bool) async -> PlaybackProgressReportResult {
        do {
            try await VividAPI.shared.reportPlaybackProgress(sessionId: sid, report: ProgressReport(position: position, isPaused: isPaused))
        } catch {
            return noteSiloProgressFailure(error, sessionId: sid)
        }
        consecutiveProgressFailures = 0
        emittedOrphanedSessionWarning = false
        return .success
    }

    /// Counts and logs a failed Silo progress write, and says whether the
    /// session is gone or the failure may pass.
    private func noteSiloProgressFailure(_ error: Error, sessionId sid: String) -> PlaybackProgressReportResult {
        consecutiveProgressFailures += 1
        logger.warning(
            "reportProgress failed for session \(sid, privacy: .public) (consecutive=\(self.consecutiveProgressFailures)): \(MediaLogRedactor.sanitize(error), privacy: .public)"
        )
        if Self.isPlaybackSessionMissing(error) {
            emittedOrphanedSessionWarning = true
            logger.error("playback session \(sid, privacy: .public) no longer exists on server; renewal required")
            return .missingSession
        }
        let shouldWarn = !emittedOrphanedSessionWarning && consecutiveProgressFailures >= Self.staleSessionFailureCount
        if shouldWarn {
            emittedOrphanedSessionWarning = true
            logger.error(
                "playback session \(sid, privacy: .public) progress reporting has failed \(self.consecutiveProgressFailures) consecutive times; server-side session may be stale"
            )
        }
        return .transientFailure
    }

    /// Sends a position recorded offline to the server. False for a blank
    /// id, an unusable position or a request that failed.
    func syncProgress(
        contentId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool
    ) async -> Bool {
        let hasContent = !contentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent, position.isFinite, position >= 0 else { return false }
        let knownDuration = duration.isFinite && duration > 0 ? duration : 0
        do {
            try await VividAPI.shared.syncProgress(
                mediaItemId: contentId,
                position: position,
                duration: knownDuration,
                forceOverwrite: forceOverwrite
            )
        } catch {
            logger.warning(
                "syncProgress failed for \(contentId, privacy: .public) at \(position, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
            return false
        }
        return true
    }

    // MARK: - AirPlay receiver sessions (iPhone and iPad)

    #if os(iOS)
    /// Lasting reasons a receiver session can't be prepared. Unlike a
    /// cancellation or a network failure, retrying won't help.
    enum AirPlayReceiverUnavailable: Error {
        /// The load on screen has no Jellyfin, Emby or Silo session to hand off.
        case noLiveProvider
        /// The server answered without a session id for the receiver.
        case noReceiverSession
        /// The Silo plan came back without a stream a receiver can fetch.
        case noReceiverStream
    }

    /// A receiver session started and checked on the server but not yet
    /// live: nothing it would replace has been touched. Each remembers the
    /// live playback it was prepared to replace, and is only committed while
    /// that's still the live one.
    private enum PreparedAirPlayReceiver {
        case jellyfin(JellyfinPlayback, PreparedPlayback, JellyfinPlayback.Metadata, replacing: JellyfinPlayback)
        case emby(EmbyPlayback, PreparedPlayback, replacing: EmbyPlayback)
        case silo(AcceptedStart, replacing: AttemptStamp)
    }

    /// Prepares a session for an AirPlay receiver: the same title, version
    /// and tracks (and `qualityId`, or the live session's quality), whose
    /// stream the receiver fetches by itself. The live session (the phone's,
    /// or an earlier receiver session) is left as it is until
    /// `commitAirPlayReceiverSession`.
    ///
    /// The returned stream's URL carries its own credential and isn't kept
    /// anywhere in the bridge; prepared sessions are found again by
    /// `serverSessionId`.
    func prepareAirPlayReceiverSession(
        detail: WatchDetail,
        version: FileVersion,
        audioOrdinal: Int?,
        subtitleStreamIndex: Int?,
        qualityId: String?,
        bitrateKbps: Int?,
        position: Double
    ) async throws -> AirPlayReceiverStream {
        let position = position.isFinite ? max(0, position) : 0
        let subtitle = subtitleStreamIndex.flatMap { $0 < 0 ? nil : $0 }
        if let live = jellyfinPlayback {
            let metadata = try await JellyfinPlayback.loadMetadata(contentID: detail.contentId)
            let (stream, prepared, playback) = try await JellyfinPlayback.prepareAirPlayReceiver(
                metadata: metadata, detail: metadata.detail, version: version, audioOrdinal: audioOrdinal,
                subtitleIndex: subtitle, bitrateKbps: bitrateKbps, position: position
            )
            guard let key = stream.serverSessionId else { throw AirPlayReceiverUnavailable.noReceiverSession }
            preparedAirPlayReceivers[key] = .jellyfin(playback, prepared, metadata, replacing: live)
            return stream
        }
        if let live = embyPlayback {
            let metadata = try await EmbyPlayback.loadMetadata(contentID: detail.contentId)
            let (stream, prepared, playback) = try await EmbyPlayback.prepareAirPlayReceiver(
                metadata: metadata, detail: metadata.detail, version: version, audioOrdinal: audioOrdinal,
                subtitleIndex: subtitle, bitrateKbps: bitrateKbps, position: position
            )
            guard let key = stream.serverSessionId else {
                try? await playback.stopWithoutProgress()
                throw AirPlayReceiverUnavailable.noReceiverSession
            }
            preparedAirPlayReceivers[key] = .emby(playback, prepared, replacing: live)
            return stream
        }
        if let live = activeProtocolV3 {
            return try await prepareSiloAirPlayReceiver(
                live: live, detail: detail, version: version, audioOrdinal: audioOrdinal,
                subtitleStreamIndex: subtitle, qualityId: qualityId, bitrateKbps: bitrateKbps, position: position
            )
        }
        throw AirPlayReceiverUnavailable.noLiveProvider
    }

    /// Makes a prepared receiver session the live one: the live session is
    /// retired at `position` and the receiver session takes progress and the
    /// final stop from here on. Anything that isn't `.committed` has also
    /// abandoned the prepared session.
    func commitAirPlayReceiverSession(_ stream: AirPlayReceiverStream, position: Double) async -> AirPlayReceiverCommit {
        let position = position.isFinite ? max(0, position) : 0
        guard let key = stream.serverSessionId,
              let prepared = preparedAirPlayReceivers.removeValue(forKey: key) else { return .refused }
        switch prepared {
        case .jellyfin(let playback, let preparedPlayback, let metadata, let replacing):
            return await commitJellyfinAirPlayReceiver(
                playback, prepared: preparedPlayback, metadata: metadata, replacing: replacing, position: position
            )
        case .emby(let playback, let preparedPlayback, let replacing):
            return await commitEmbyAirPlayReceiver(playback, prepared: preparedPlayback, replacing: replacing, position: position)
        case .silo(let accepted, let replacing):
            return await commitSiloAirPlayReceiver(accepted, replacing: replacing, position: position)
        }
    }

    /// Ends a prepared receiver session that won't be committed. A Jellyfin
    /// one needs nothing: PlaybackInfo opened no stream, and a Stopped report
    /// would end this device's live playback instead.
    func abandonAirPlayReceiverSession(_ stream: AirPlayReceiverStream) async {
        guard let key = stream.serverSessionId,
              let prepared = preparedAirPlayReceivers.removeValue(forKey: key) else { return }
        await abandon(prepared, sessionId: key, reason: "airplay_receiver_released")
    }

    private func abandon(_ prepared: PreparedAirPlayReceiver, sessionId: String, reason: String) async {
        switch prepared {
        case .jellyfin:
            break
        case .emby(let playback, _, _):
            try? await playback.stopWithoutProgress()
        case .silo:
            await retireAbandonedSession(sessionId, reason: reason)
        }
    }

    /// Abandons every prepared receiver session, for a stop: nothing
    /// prepared may become live after it.
    private func abandonPreparedAirPlayReceivers() {
        let prepared = preparedAirPlayReceivers
        preparedAirPlayReceivers.removeAll()
        guard !prepared.isEmpty else { return }
        Task {
            for (sessionId, receiver) in prepared {
                await self.abandon(receiver, sessionId: sessionId, reason: "airplay_receiver_stopped")
            }
        }
    }

    /// The receiver has started playing: a Silo receiver attempt reports its
    /// first frame against its own plan.
    func reportAirPlayReceiverStarted() async {
        guard let planId = airPlayReceiverPlanId, let attempt = activeProtocolV3,
              attempt.plan.planId == planId, let liveSessionId = sessionId else { return }
        await reportProtocolV3FirstFrame(planId: planId, sessionId: liveSessionId, milliseconds: nil)
    }

    /// Jellyfin keeps one play session per device, so the live one stops
    /// before the receiver's first report.
    private func commitJellyfinAirPlayReceiver(
        _ playback: JellyfinPlayback, prepared: PreparedPlayback, metadata: JellyfinPlayback.Metadata,
        replacing: JellyfinPlayback, position: Double
    ) async -> AirPlayReceiverCommit {
        guard jellyfinPlayback === replacing else { return .refused }
        // The current token, not a new one: a commit mustn't cancel a start
        // in progress, and any start or stop that begins meanwhile replaces
        // it and so overtakes the commit.
        let attempt = jellyfinStartAttempt
        do {
            try await adoptJellyfinPlayback(playback, prepared: prepared, metadata: metadata, attempt: attempt,
                                            retiringAt: position)
        } catch {
            // Overtaken by a stop or another start, which own what happens
            // next. Otherwise the sign-in failed, after the live playback was
            // retired if nothing is live now.
            if jellyfinStartAttempt != attempt { return .refused }
            return jellyfinPlayback == nil && sessionId == nil ? .failed : .refused
        }
        airPlayReceiverPlanId = nil
        // Chained like any progress write, so a tick can't send a second
        // start report alongside this one.
        let earlierWrite = progressWriteTail
        let log = self.logger
        let firstReport = Task { () -> PlaybackProgressReportResult in
            _ = await earlierWrite?.value
            do {
                try await playback.report(position: position, isPaused: false)
                self.reportedJellyfinPlayback = playback
            } catch {
                log.warning("Jellyfin AirPlay receiver start report failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
            }
            return .success
        }
        progressWriteTail = firstReport
        _ = await firstReport.value
        logger.info("AirPlay receiver session committed (Jellyfin)")
        return .committed
    }

    /// The receiver becomes live before the outgoing playback is retired, so
    /// a stop at any point after this reaches it. The retirement and the
    /// receiver's first report run as one progress write, so no report can
    /// land between them.
    private func commitEmbyAirPlayReceiver(
        _ playback: EmbyPlayback, prepared: PreparedPlayback, replacing: EmbyPlayback, position: Double
    ) async -> AirPlayReceiverCommit {
        // The current token: a commit mustn't cancel a start in progress, and
        // a start or stop that begins meanwhile overtakes it.
        let attempt = jellyfinStartAttempt
        guard let outgoing = embyPlayback, outgoing === replacing else {
            try? await playback.stopWithoutProgress()
            return .refused
        }
        let earlierWrite = progressWriteTail
        _ = await earlierWrite?.value
        // A stop or another start took over while the last write finished.
        guard jellyfinStartAttempt == attempt, embyPlayback === outgoing else {
            try? await playback.stopWithoutProgress()
            return .refused
        }
        embyPlayback = playback
        airPlayReceiverPlanId = nil
        adoptSession(prepared.session)
        let log = self.logger
        let handover = Task { () -> PlaybackProgressReportResult in
            do {
                // Its stop also ends its encoding.
                try await outgoing.report(position: position, isPaused: true, stopping: true)
            } catch {
                log.warning("Emby AirPlay hand-off stop failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
            }
            do {
                try await playback.report(position: position, isPaused: false)
            } catch {
                log.warning("Emby AirPlay receiver start report failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
            }
            return .success
        }
        progressWriteTail = handover
        _ = await handover.value
        logger.info("AirPlay receiver session committed (Emby)")
        return .committed
    }

    /// Starts and checks the receiver attempt, which a refusal (a stream
    /// limit, a plan the receiver can't fetch) leaves the live attempt
    /// untouched by. The receiver attempt is never replanned.
    private func prepareSiloAirPlayReceiver(
        live: SiloAttempt, detail: WatchDetail, version: FileVersion, audioOrdinal: Int?, subtitleStreamIndex: Int?,
        qualityId: String?, bitrateKbps: Int?, position: Double
    ) async throws -> AirPlayReceiverStream {
        let serverURL = await VividAPI.shared.currentServerUrl()
        guard SiloAirPlayReceiver.apiBase(serverURL: serverURL, nativeApiMajor: live.plan.nativeApiMajor) != nil else {
            throw SiloAirPlayReceiverError.unsupportedAPIBase
        }
        let profileId = await TokenStore.shared.getProfileId() ?? ""
        let combinedSubtitle = subtitleStreamIndex.flatMap {
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(ffmpegStreamIndex: $0, in: version)
        }
        func requestReceiverPlan(subtitle: Int?) async throws -> AcceptedStart {
            try await requestStartPlan(
                detail: detail,
                version: version,
                profileId: profileId,
                quality: qualityId ?? live.clientQualityId,
                bandwidthCapKbps: qualityId == nil ? live.bandwidthCapKbps : bitrateKbps,
                startPosition: position,
                audioIndex: audioOrdinal,
                subtitleCombinedIndex: subtitle,
                airPlayReceiverServerURL: serverURL
            )
        }
        let accepted: AcceptedStart
        do {
            accepted = try await requestReceiverPlan(subtitle: combinedSubtitle)
        } catch let failure as PlaybackV3TerminalFailure
            where failure.reason == "subtitle_burn_in_source_unsupported" && combinedSubtitle != nil {
            // A subtitle the server can't burn in (a downloaded or external
            // file) is left off rather than refusing the hand-off.
            accepted = try await requestReceiverPlan(subtitle: nil)
        }
        guard let stream = accepted.receiverStream, stream.serverSessionId == accepted.sessionId else {
            await retireAbandonedSession(accepted.sessionId, reason: "airplay_receiver_without_stream")
            throw AirPlayReceiverUnavailable.noReceiverStream
        }
        // The stored copy keeps no URL with a stream reference in it.
        var stored = accepted
        stored.receiverStream = nil
        preparedAirPlayReceivers[accepted.sessionId] = .silo(stored, replacing: live.stamp)
        return stream
    }

    /// The receiver attempt becomes live, then the attempt it replaces is
    /// retired through its stop path.
    private func commitSiloAirPlayReceiver(
        _ accepted: AcceptedStart, replacing: AttemptStamp, position: Double
    ) async -> AirPlayReceiverCommit {
        guard let replaced = activeProtocolV3, replaced.stamp == replacing, let replacedSessionId = sessionId,
              pendingProtocolV3Transition == nil else {
            await retireAbandonedSession(accepted.sessionId, reason: "airplay_receiver_overtaken")
            return .refused
        }
        activeProtocolV3 = accepted.attempt
        protocolV3FirstFramePlanIds.removeAll()
        airPlayReceiverPlanId = accepted.attempt.plan.planId
        let replacedWrite = progressWriteTail
        adoptSession(accepted.session)
        logger.info("AirPlay receiver session committed (Silo) plan=\(accepted.attempt.plan.planId, privacy: .public)")
        await retireProtocolV3Session(replaced, sessionId: replacedSessionId, position: position, after: replacedWrite)
        return .committed
    }

    /// The Silo stop path for an attempt that's no longer the live one: its
    /// `stopped` event, a final position and the DELETE.
    private func retireProtocolV3Session(
        _ attempt: SiloAttempt,
        sessionId retiredSessionId: String,
        position: Double,
        after earlierWrite: Task<PlaybackProgressReportResult, Never>?
    ) async {
        _ = await earlierWrite?.value
        await emitProtocolV3Event(
            active: attempt,
            sessionId: retiredSessionId,
            event: "stopped",
            classification: nil,
            fallbackReason: nil,
            diagnostics: ["target_source_position_seconds": String(position)]
        )
        do {
            try await VividAPI.shared.reportPlaybackProgress(
                sessionId: retiredSessionId,
                report: ProgressReport(position: position, isPaused: true)
            )
        } catch {
            logger.warning(
                "AirPlay hand-off final progress failed for \(retiredSessionId, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }
        await retireAbandonedSession(retiredSessionId, reason: "airplay_handoff")
    }

    /// A receiver plan as the bridge keeps it, with every signed stream
    /// reference (`st`) taken out of its URLs: only the receiver needs them,
    /// and session state reaches logs and errors. Internal for its test.
    static func planWithoutStreamReferences(_ plan: PlaybackV3Plan) throws -> PlaybackV3Plan {
        func strip(_ value: Any) -> Any {
            switch value {
            case let text as String:
                return text.contains("st=") ? SiloAirPlayReceiver.strippingStreamReference(text) : text
            case let list as [Any]:
                return list.map(strip)
            case let object as [String: Any]:
                return object.mapValues(strip)
            default:
                return value
            }
        }
        let encoded = try JSONEncoder().encode(plan)
        let stripped = strip(try JSONSerialization.jsonObject(with: encoded))
        return try JSONDecoder().decode(PlaybackV3Plan.self, from: JSONSerialization.data(withJSONObject: stripped))
    }
    #endif

    // MARK: - Stopping

    /// Retires the current session, exactly once.
    ///
    /// The actor can be re-entered at each `await` below (the route event,
    /// the final progress write and the DELETE), so the session id is taken
    /// and every session value cleared before the first of them. A second
    /// caller (a teardown racing an autoplay hand-over, say) then finds
    /// nothing to stop rather than sending a second final report and DELETE,
    /// and clearing late can't wipe out a new session adopted meanwhile.
    @discardableResult
    func stopSession(
        position: Double,
        isPaused: Bool,
        eligible: Bool,
        completedContentId: String? = nil,
        finalProgressAlreadyReported: Bool = false
    ) async -> PlaybackProgressReportResult {
        // Taking a new token also tells any Jellyfin start still running
        // that it has been overtaken.
        let stopToken = UUID()
        jellyfinStartAttempt = stopToken
        #if os(iOS)
        abandonPreparedAirPlayReceivers()
        #endif
        if jellyfinTransitionInProgress {
            await waitForJellyfinTransition()
            if jellyfinStartAttempt != stopToken { return .deferred }
        }
        guard let sid = sessionId else { return .transientFailure }
        let earlierWrite = progressWriteTail
        let reportsPosition = eligible || completedContentId != nil

        if let playback = jellyfinPlayback {
            jellyfinTransitionInProgress = true
            jellyfinTransitionPlayback = playback
            defer { finishJellyfinTransition() }
            jellyfinPlayback = nil
            sessionId = nil
            currentSession = nil
            _ = await earlierWrite?.value
            if !reportsPosition {
                do {
                    try await playback.stopWithoutProgress()
                } catch {
                    return .transientFailure
                }
                return .deferred
            }
            var outcome = PlaybackProgressReportResult.success
            do {
                try await playback.report(position: position, isPaused: isPaused, stopping: true)
            } catch {
                logger.warning("Jellyfin stop report failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
                outcome = .transientFailure
            }
            return await writeJellyfinCompletion(after: outcome, contentId: completedContentId, playback: playback)
        }

        if let playback = embyPlayback {
            embyPlayback = nil
            sessionId = nil
            currentSession = nil
            _ = await earlierWrite?.value
            do {
                if !reportsPosition {
                    try await playback.stopWithoutProgress()
                    return .deferred
                }
                try await playback.report(position: position, isPaused: isPaused, stopping: true)
            } catch {
                return .transientFailure
            }
            return await writeCompletion(after: .success, contentId: completedContentId, playback: playback)
        }

        // Silo. Everything session-scoped is cleared before the first await.
        let stoppingAttempt = activeProtocolV3
        let replacedSessionId = pendingProtocolV3Transition?.priorSessionId
        sessionId = nil
        currentSession = nil
        activeProtocolV3 = nil
        airPlayReceiverPlanId = nil
        pendingProtocolV3Transition = nil
        protocolV3FirstFramePlanIds.removeAll()
        consecutiveProgressFailures = 0
        emittedOrphanedSessionWarning = false

        _ = await earlierWrite?.value
        if let replacedSessionId, replacedSessionId != sid {
            stopStaleSession(replacedSessionId)
        }
        #if os(iOS) || os(tvOS)
        // Diagnostics attributes have no float type, so the position goes in
        // whole milliseconds.
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "PlaybackSession",
            message: "playback session stopped",
            attrs: ["session_id": .string(sid), "position_ms": .int(Self.diagnosticsPositionMilliseconds(position))]
        )
        #endif

        if let stoppingAttempt {
            let stoppedAt = position.isFinite ? max(0, position) : 0
            await emitProtocolV3Event(
                active: stoppingAttempt,
                sessionId: sid,
                event: "stopped",
                classification: nil,
                fallbackReason: nil,
                diagnostics: ["target_source_position_seconds": String(stoppedAt)]
            )
        }

        var finalWrite: PlaybackProgressReportResult = finalProgressAlreadyReported ? .success : .transientFailure
        if !finalProgressAlreadyReported, position.isFinite, position >= 0 {
            let report = ProgressReport(position: reportsPosition ? position : 0, isPaused: isPaused)
            do {
                try await VividAPI.shared.reportPlaybackProgress(sessionId: sid, report: report)
                finalWrite = reportsPosition ? .success : .deferred
            } catch {
                finalWrite = Self.isPlaybackSessionMissing(error) ? .missingSession : .transientFailure
                logger.warning(
                    "final stop-session progress report failed for \(sid, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
            }
        }

        do {
            try await VividAPI.shared.stopPlayback(sessionId: sid)
        } catch {
            // Best effort. The server ends idle sessions on its own, but a
            // missed DELETE holds the slot for longer, so it's logged.
            logger.error(
                "stop-session DELETE failed for \(sid, privacy: .public); server-side session may linger until idle timeout: \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }

        #if os(tvOS)
        // The position moved, so the Top Shelf reloads.
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
        return await writeCompletion(after: finalWrite, contentId: completedContentId, playback: nil)
    }

    // MARK: - Helpers

    /// A saved quality id, or nil for Auto.
    private func normalizedQualityPreference(_ quality: String?) -> String? {
        let stored = ApplePlaybackQuality.normalizeStoredId(quality)
        if stored == ApplePlaybackQuality.autoId { return nil }
        return stored
    }

    /// What a start or replan sends as its quality preference: a rung of the
    /// ladder as its resolution alone, anything else as its server id.
    private func serverQualityPreference(_ quality: String?) -> String {
        let id = ApplePlaybackQuality.protocolV3QualityId(quality)
        let isLadderRung = ApplePlaybackQuality.requestOptions.contains { $0.id == id }
        return isLadderRung ? AppleQualityAxes.split(id).resolution : id
    }

    private static func trackIdentifier(fileId: Int, kind: String, index: Int) -> String {
        "file:\(fileId):\(kind):\(index)"
    }

    private static func newPlanAttemptId() -> String {
        "apple-plan:\(UUID().uuidString.lowercased())"
    }

    private static func unrecoverable(_ reason: String, _ message: String) -> PlaybackV3TerminalFailure {
        PlaybackV3TerminalFailure(reason: reason, message: message, retryable: false)
    }

    /// With a file picked by hand or reused from last time, the request asks
    /// for that file's own resolution; otherwise the preference goes as it
    /// is.
    private func requestedQualityPreference(
        preferredQuality: String?,
        selectedVersion: FileVersion,
        hasManualSelection: Bool
    ) -> String? {
        hasManualSelection ? (selectedVersion.resolution ?? preferredQuality ?? "original") : preferredQuality
    }
}

// MARK: - Rules

extension PlaybackSessionBridge {
    /// Works out "Auto" before the first V3 request. Otherwise the player
    /// would only apply these rules after opening the file, and could show a
    /// default or forced track while the server's plan still had subtitles
    /// off.
    static func initialProtocolV3SubtitleIntent(
        version: FileVersion,
        explicitFFmpegIndex: Int?,
        explicitCombinedIndex: Int?,
        preferredLanguage: String?,
        additionalPreferredLanguages: [String] = [],
        mode: SubtitleMode?,
        showForced: Bool,
        forcedOnly: Bool = false,
        preferAccessibilityTracks: Bool = false,
        disableWhenNoLanguageMatch: Bool = false,
        trackSignature: SubtitleTrackSignature?,
        currentAudioLanguage: String?
    ) -> InitialProtocolV3SubtitleIntent {
        let subtitlesOff = InitialProtocolV3SubtitleIntent(ffmpegStreamIndex: nil, combinedIndex: nil)
        func nonNegative(_ index: Int?) -> Int? { index.flatMap { $0 < 0 ? nil : $0 } }

        if let explicitCombinedIndex {
            return InitialProtocolV3SubtitleIntent(
                ffmpegStreamIndex: nonNegative(explicitFFmpegIndex),
                combinedIndex: nonNegative(explicitCombinedIndex)
            )
        }
        if let explicitFFmpegIndex {
            if explicitFFmpegIndex < 0 { return subtitlesOff }
            let combined = ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(ffmpegStreamIndex: explicitFFmpegIndex, in: version)
            return InitialProtocolV3SubtitleIntent(ffmpegStreamIndex: explicitFFmpegIndex, combinedIndex: combined)
        }

        let tracks = SubtitleTrackCandidates.playerTracks(from: version.subtitleTracks ?? [])
        let decision = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: preferredLanguage,
            additionalPreferredLanguages: additionalPreferredLanguages,
            mode: mode,
            showForced: showForced,
            forcedOnly: forcedOnly,
            preferAccessibilityTracks: preferAccessibilityTracks,
            disableWhenNoLanguageMatch: disableWhenNoLanguageMatch,
            trackSignature: trackSignature,
            availableSubtitles: tracks,
            currentAudioLanguage: currentAudioLanguage
        ))
        let chosen: PlayerTrack? = switch decision {
        case .select(let track): track
        case .disable: nil
        // Left alone, the player's demuxer keeps the media's default track,
        // and the sidecar route also promotes a forced one, so that choice is
        // written into the plan from the start.
        case .noChange: tracks.first(where: { $0.isDefault }) ?? tracks.first(where: { $0.isForced })
        }
        guard let chosen else { return subtitlesOff }
        return InitialProtocolV3SubtitleIntent(
            ffmpegStreamIndex: chosen.ffIndex,
            combinedIndex: ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(for: chosen, in: version)
        )
    }

    /// The session a start or replan decision allocated, if any. A terminal
    /// answer allocates nothing; both a playable and an incompatible plan
    /// can come with a live session that needs retiring.
    static func allocatedSessionId(in response: PlaybackV3DecisionResponse) -> String? {
        let decision = response.validatedForApple()
        if case .playable(_, let id) = decision { return id }
        if case .incompatible(let id) = decision { return id }
        return nil
    }

    /// The protocol operation for a failure or intent classification. A
    /// track or quality change is an intent, not a failure, and sends no
    /// `failure` block.
    ///
    /// This version is older than `output_change_v1` and leaves an output
    /// route change on `failure_recovery`. Use the `serverFeatures` version
    /// where possible: only it can tell whether the server offers the intent
    /// operation.
    static func replanOperation(forClassification classification: String) -> String {
        if classification == "quality_changed" {
            return PlaybackProtocolV3.ReplanOperation.qualityChange
        }
        if ["audio_track_changed", "subtitle_track_changed"].contains(classification) {
            return PlaybackProtocolV3.ReplanOperation.trackChange
        }
        return PlaybackProtocolV3.ReplanOperation.failureRecovery
    }

    /// A new output route is an intent, not a failed recipe: the device
    /// never turned the plan down, the display it was chosen for changed.
    /// `output_change` says exactly that and keeps the previous route
    /// eligible, where `failure_recovery` rules out the current plan key and
    /// forces another route even if the new output could still play it.
    ///
    /// Only a server advertising `output_change_v1` has the operation; an
    /// older one refuses it, so `failure_recovery` remains the fallback.
    static func replanOperation(
        forClassification classification: String,
        serverFeatures: [String]
    ) -> String {
        let offersOutputChange = serverFeatures.contains(PlaybackProtocolV3.outputChangeFeature)
        guard classification == "output_route_changed", offersOutputChange else {
            return replanOperation(forClassification: classification)
        }
        return PlaybackProtocolV3.ReplanOperation.outputChange
    }

    /// AVAudioSession posts route changes for settings the player makes
    /// itself, such as choosing a multichannel layout. A V3 route replan is
    /// only called for when the output the plan was chosen for really
    /// changed.
    static func isMaterialOutputRouteChange(
        activeOutputContextId: String?,
        observedOutputContextId: String?
    ) -> Bool {
        observedOutputContextId != activeOutputContextId
    }

    static func supportsNeutralProtocolV3(_ capability: PlaybackV3CapabilityResponse) -> Bool {
        guard capability.enabled, capability.protocolVersions.contains(PlaybackProtocolV3.version) else { return false }
        let requiredFeatures = [PlaybackProtocolV3.planFeature, PlaybackProtocolV3.neutralContractFeature]
        guard requiredFeatures.allSatisfy({ capability.features.contains($0) }) else { return false }
        return capability.nativeApiMajor == 2
            || capability.features.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature)
    }

    /// A server without the capability route answers 404 or 405.
    static func isMissingProtocolV3Capability(_ error: Error) -> Bool {
        guard case .http(let status, _)? = error as? HTTPError else { return false }
        return [404, 405].contains(status)
    }

    /// A decision can only be used if its media stays header-authenticated:
    /// native API 2 always does, and older servers have to say so.
    private static func carriesHeaderMedia(_ response: PlaybackV3DecisionResponse) -> Bool {
        if response.nativeApiMajor == 2 { return true }
        return response.serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature)
    }

    static func terminalStartRouteEvent(
        playbackAttemptId: String,
        snapshot: ApplePlaybackV3CapabilitySnapshot,
        terminal: PlaybackV3Terminal
    ) -> PlaybackV3RouteEvent {
        // A start that ended before any session or plan existed names only
        // the attempt and the output.
        PlaybackV3RouteEvent(
            protocolVersion: PlaybackProtocolV3.version,
            playbackAttemptId: playbackAttemptId,
            sessionId: nil,
            planId: nil,
            planAttemptId: nil,
            planAttemptKey: nil,
            event: "terminal",
            failureClassification: nil,
            fallbackReason: terminal.reason,
            appliedQuirkIds: [],
            quirkRegistryRevision: nil,
            outputContextId: snapshot.outputContextId,
            diagnostics: ["error_cause": String(terminal.message.prefix(256))]
        )
    }

    static func reportTerminalStart(
        playbackAttemptId: String,
        snapshot: ApplePlaybackV3CapabilitySnapshot,
        terminal: PlaybackV3Terminal
    ) async {
        let event = terminalStartRouteEvent(playbackAttemptId: playbackAttemptId, snapshot: snapshot, terminal: terminal)
        do {
            try await VividAPI.shared.reportPlaybackRouteEventV3(event)
        } catch {
            playbackLog.warning(
                "Protocol V3 terminal-start route event failed: \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }
    }

    /// The `failure` block a replan sends: none for an intent or a seek
    /// re-anchor (the server turns down an `output_change` that has one),
    /// otherwise the classification and the message's first 512 characters.
    static func replanFailure(
        operation: String,
        classification: String,
        message: String
    ) -> PlaybackV3Failure? {
        let operationsWithoutFailure: Set<String> = [
            PlaybackProtocolV3.ReplanOperation.trackChange,
            PlaybackProtocolV3.ReplanOperation.qualityChange,
            PlaybackProtocolV3.ReplanOperation.outputChange,
            PlaybackProtocolV3.ReplanOperation.seekReanchor,
        ]
        if operationsWithoutFailure.contains(operation) { return nil }
        return PlaybackV3Failure(classification: classification, message: String(message.prefix(512)), decoderName: nil)
    }

    /// A rolled-back candidate is only retired when nothing else still owns
    /// it: neither the committed session it replaced, nor a decision about to
    /// hold the same session again (a replan of a start that never committed
    /// reuses the start's session).
    static func shouldRetireRolledBackCandidate(
        candidateSessionId: String,
        priorSessionId: String?,
        retainingSessionId: String?
    ) -> Bool {
        ![priorSessionId, retainingSessionId].contains(candidateSessionId)
    }

    /// Seconds as whole, non-negative milliseconds for the
    /// `playback.position_ms` diagnostics attribute. Infinite, NaN and
    /// negative values give zero.
    static func diagnosticsPositionMilliseconds(_ position: Double) -> Int {
        guard position.isFinite, position > 0 else { return 0 }
        let milliseconds = (position * 1000).rounded()
        return milliseconds < Double(Int.max) ? Int(milliseconds) : Int.max
    }

    /// How Silo answers for a session it no longer has: a 404 carrying the
    /// `playback_session_not_found` code, or that message in its body.
    static func isPlaybackSessionMissing(_ error: Error) -> Bool {
        guard let httpError = error as? HTTPError, case .http(404, let body) = httpError else { return false }
        if httpError.serverErrorCode == "playback_session_not_found" { return true }
        return body?.contains("Playback session not found") == true
    }

    /// The version that best fits the preferred quality. The server filters
    /// for compatibility using the capability snapshot and may answer with a
    /// different `effective_media_file_id`; this only picks the version the
    /// request names. In order: the highest-ranked version within the
    /// preferred quality, then the one used last, then the highest-ranked.
    static func selectVersion(
        from versions: [FileVersion],
        lastFileId: Int?,
        preferredQuality: String?
    ) -> FileVersion {
        let byRank = versions.sorted { rank($0, for: preferredQuality) > rank($1, for: preferredQuality) }
        if let preferredQuality, let fit = byRank.first(where: { fits($0.resolution, within: preferredQuality) }) {
            return fit
        }
        if let lastFileId, let previous = versions.first(where: { $0.fileId == lastFileId }) {
            return previous
        }
        return byRank.first ?? versions[0]
    }

    /// The `PreparedPlayback` handed to the player for an attempt's plan.
    private static func preparedPlayback(
        from attempt: SiloAttempt,
        detail: WatchDetail,
        version: FileVersion,
        session: PlaybackSessionResponse
    ) -> PreparedPlayback {
        let activeQuality = ApplePlaybackQuality.activeProtocolV3QualityId(
            requestedQualityId: attempt.clientQualityId,
            availableQualities: attempt.plan.availableQualities
        )
        let planPart = PreparedPlaybackV3(
            playbackAttemptId: attempt.playbackAttemptId,
            planAttemptId: attempt.planAttemptId,
            planAttemptKey: attempt.planAttemptKey,
            outputContextId: attempt.snapshot.outputContextId,
            serverFeatures: attempt.serverFeatures,
            negotiatedAuthorizedMediaOrigins: attempt.negotiatedAuthorizedMediaOrigins,
            plan: attempt.plan
        )
        return PreparedPlayback(
            watchDetail: detail,
            selectedVersion: version,
            session: session,
            activeQualityId: activeQuality,
            bandwidthCap: .inEffect(attempt.bandwidthCapKbps),
            protocolV3: planPart
        )
    }

    /// Ten points per resolution tier, then +5 for everything when the
    /// preference is Original, +100 for a version within the preference, or
    /// -50 for one above it.
    private static func rank(_ version: FileVersion, for preferredQuality: String?) -> Int {
        let tier = resolutionTier(version.resolution)
        guard let preferredQuality else { return tier * 10 }
        if preferredQuality == "original" { return tier * 10 + 5 }
        if fits(version.resolution, within: preferredQuality) { return tier * 10 + 100 }
        if tier > resolutionTier(preferredQuality) { return tier * 10 - 50 }
        return tier * 10
    }

    /// Whether a resolution is known and no higher than the preference.
    /// Original accepts any known resolution.
    private static func fits(_ resolution: String?, within preferredQuality: String) -> Bool {
        let tier = resolutionTier(resolution)
        guard tier > 0 else { return false }
        return preferredQuality == ApplePlaybackQuality.originalId || tier <= resolutionTier(preferredQuality)
    }

    /// 4 for 2160p or 4K, 3 for 1080p, 2 for 720p, 1 for 480p, 0 otherwise.
    private static func resolutionTier(_ value: String?) -> Int {
        guard let text = value?.lowercased() else { return 0 }
        let tiers: [(markers: [String], tier: Int)] = [(["2160", "4k"], 4), (["1080"], 3), (["720"], 2), (["480"], 1)]
        return tiers.first { entry in entry.markers.contains { text.contains($0) } }?.tier ?? 0
    }
}
