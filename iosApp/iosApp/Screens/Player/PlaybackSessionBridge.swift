import Foundation
import OSLog
#if os(tvOS)
import TVServices
#endif

/// The server side of one player's playback: starting a session, reporting
/// progress, replanning and stopping.
///
/// Silo sessions follow Protocol V3, where a server decision stays pending
/// until the player has opened its source (see `commitPendingProtocolV3Transition`).
/// Emby and Jellyfin sessions live in `EmbyPlayback` and `JellyfinPlayback`;
/// the bridge only orders their starts, reports and stops. The actor can be
/// re-entered at every `await`, so each method claims or checks the state it
/// needs before suspending.
actor PlaybackSessionBridge {
    // MARK: - Types

    /// The Protocol V3 attempt behind the current Silo session.
    private struct ActiveProtocolV3 {
        let playbackAttemptId: String
        var planAttemptId: String
        var planAttemptKey: String
        var attemptedPlanKeys: [String]
        var attemptCount: Int
        var clientQualityId: String
        /// True after the user picks an exact quality the plan advertised.
        /// Recovery replans keep that id rather than mapping it through the
        /// Settings quality ladder.
        var usesServerQualityPreference: Bool
        /// The bandwidth cap captured for this attempt. Every replan repeats
        /// it, or recovery would quietly widen the connection.
        var bandwidthCapKbps: Int?
        var snapshot: ApplePlaybackV3CapabilitySnapshot
        var serverFeatures: [String]
        /// Fixed for the attempt: the server restores the negotiated origin
        /// state on a replan anyway, so every replan repeats what the start
        /// negotiated. Changing it needs a new attempt, not a replan.
        let negotiatedAuthorizedMediaOrigins: Bool
        var plan: PlaybackV3Plan
    }

    /// Identifies one plan attempt, so a replan that suspended can tell
    /// whether a newer load or a stop replaced it in the meantime.
    private struct ProtocolV3AttemptIdentity: Equatable {
        let playbackAttemptId: String
        let planAttemptId: String
        let planAttemptKey: String

        init(_ active: ActiveProtocolV3) {
            playbackAttemptId = active.playbackAttemptId
            planAttemptId = active.planAttemptId
            planAttemptKey = active.planAttemptKey
        }
    }

    /// A start the server accepted, before the bridge adopts it.
    private struct StagedProtocolV3Start {
        let playbackAttemptId: String
        let clientQualityId: String
        let bandwidthCapKbps: Int?
        let snapshot: ApplePlaybackV3CapabilitySnapshot
        let serverFeatures: [String]
        let negotiatedAuthorizedMediaOrigins: Bool
        let plan: PlaybackV3Plan
        let sessionId: String
        let selectedVersion: FileVersion
        let session: PlaybackSessionResponse
    }

    /// A server decision stays provisional until the player proves it opened
    /// the matching source. The state it replaced is kept here, so a
    /// cancelled or failed load never publishes a session and plan that
    /// never played. A commit retires the replaced session exactly once.
    private struct PendingProtocolV3Transition {
        let priorSessionId: String?
        let priorSession: PlaybackSessionResponse?
        let priorProtocolV3: ActiveProtocolV3?
        let candidateSessionId: String
        let candidatePlanId: String
        let commitEvent: String?
        let commitDiagnostics: [String: String]
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

    private static let nearEndResumeSuppressionSeconds: Double = 5
    private static let pastEndResumeClampSeconds: Double = 0.25
    private static let orphanedSessionLogThreshold = 3
    /// Replans allowed in one attempt before recovery gives up.
    private static let protocolV3AttemptLimit = 8

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "Playback"
    )

    private var sessionId: String?
    private var currentSession: PlaybackSessionResponse?

    /// The last progress write. Each write waits for the one before it, and
    /// stops and Jellyfin replacements drain it, so writes reach the server
    /// in order.
    private var progressWriteTail: Task<PlaybackProgressReportResult, Never>?

    /// Silo progress failures since the last success, for the log. After
    /// `orphanedSessionLogThreshold` of them the session is logged once as
    /// possibly stale on the server.
    private var consecutiveProgressFailures = 0
    private var emittedOrphanedSessionWarning = false

    private var activeProtocolV3: ActiveProtocolV3?
    private var protocolV3FirstFramePlanIds: Set<String> = []
    private var pendingProtocolV3Transition: PendingProtocolV3Transition?

    // MARK: - Emby and Jellyfin sessions

    private var embyPlayback: EmbyPlayback?
    private var jellyfinPlayback: JellyfinPlayback?
    private var playingTracksGeneration: UInt64 = 0
    /// Replaced by every start and stop. A Jellyfin start that sees a newer
    /// value has been superseded and gives up.
    private var jellyfinStartAttempt = UUID()
    /// True while a Jellyfin start replaces the current playback or a stop
    /// retires it. Reports and other transitions wait for it to clear.
    private var jellyfinTransitionInProgress = false
    /// The playback being replaced or stopped, so a terminal watched write
    /// that waited on the transition still reaches its own item.
    private var jellyfinTransitionPlayback: JellyfinPlayback?
    private var jellyfinTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    private func waitForJellyfinTransition() async {
        while jellyfinTransitionInProgress {
            await withCheckedContinuation { jellyfinTransitionWaiters.append($0) }
        }
    }

    private func finishJellyfinTransition() {
        jellyfinTransitionInProgress = false
        jellyfinTransitionPlayback = nil
        let waiters = jellyfinTransitionWaiters
        jellyfinTransitionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func validateJellyfinStart(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard jellyfinStartAttempt == attempt else { throw CancellationError() }
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
        let jellyfinAttempt = UUID()
        jellyfinStartAttempt = jellyfinAttempt
        logger.info("Fetching watch detail for \(contentId, privacy: .public)")
        let watchDetail: WatchDetail
        var embyMetadata: EmbyPlayback.Metadata?
        var jellyfinMetadata: JellyfinPlayback.Metadata?
        switch MediaServerProvider.active {
        case .jellyfin:
            let metadata = try await JellyfinPlayback.loadMetadata(contentID: contentId)
            jellyfinMetadata = metadata
            watchDetail = metadata.detail
        case .emby:
            let metadata = try await EmbyPlayback.loadMetadata(contentID: contentId)
            embyMetadata = metadata
            watchDetail = metadata.detail
        case .silo:
            watchDetail = try await VividAPI.shared.watchDetail(contentId: contentId)
        }
        logger.info("Got \(watchDetail.versions.count) versions, type=\(watchDetail.type, privacy: .public)")

        guard !watchDetail.versions.isEmpty else {
            throw APIError.httpError(statusCode: 404)
        }

        // An explicit override (an in-player quality change, for example
        // back to Auto) wins over the saved setting.
        let playerSettings = PlayerSettings.shared
        let lastUsedQuality = prefersLastUsedVersion
            ? normalizedQualityPreference(watchDetail.userData?.lastResolution)
            : nil
        let preferredQuality = preferredQualityOverride.map { ApplePlaybackQuality.protocolV3QualityId($0) }
            ?? playerSettings.fallbackMode?.rawValue
            ?? lastUsedQuality
            ?? normalizedQualityPreference(playerSettings.preferredQuality)
        // A carried override repeats the cap its playback ran with; only a
        // fresh in-player choice takes its cap from the chosen tier.
        let bandwidthCapKbps = AppleQualityAxes.resolvedBitrateCap(
            qualityOverride: preferredQualityOverride,
            carriedCap: carriedBandwidthCap,
            fallbackBitrateKbps: playerSettings.maxBitrateKbps
        )

        let selectedVersion = initialVersion(
            in: watchDetail,
            preferredFileId: preferredFileId,
            prefersLastUsedVersion: prefersLastUsedVersion,
            preferredQuality: preferredQuality
        )
        // A pick, else the language picked earlier in this viewing, else
        // Settings > Playback > Audio Language.
        let audioTracks = selectedVersion.audioTracks ?? []
        let resolvedAudioTrackIndex = VividInitialAudioPreference.selectedOrdinal(
            manual: preferredAudioTrackIndex,
            tracks: audioTracks,
            preferredLanguage: VividInitialAudioPreference.preferredLanguage(
                viewing: viewingAudioLanguage,
                settings: playerSettings.audioLanguage,
                tracks: audioTracks
            )
        )
        let selectedAudioLanguage = resolvedAudioTrackIndex.flatMap { ordinal in
            audioTracks.indices.contains(ordinal) ? audioTracks[ordinal].language : nil
        }
        let subtitleIntent = Self.initialProtocolV3SubtitleIntent(
            version: selectedVersion,
            explicitFFmpegIndex: preferredSubtitleTrackIndex,
            explicitCombinedIndex: preferredProtocolV3SubtitleIndex,
            // Only the preferences the caller hands in. A server's remembered
            // subtitle mode or track never chooses subtitles: without
            // preferences the plan starts with none, and the player picks from
            // Settings > Subtitles once the file is open.
            preferredLanguage: initialSubtitlePreferences?.preferredLanguage,
            additionalPreferredLanguages: initialSubtitlePreferences?.additionalPreferredLanguages ?? [],
            mode: initialSubtitlePreferences == nil ? .off : initialSubtitlePreferences?.mode,
            showForced: initialSubtitlePreferences?.showForced ?? false,
            forcedOnly: initialSubtitlePreferences?.forcedOnly ?? false,
            preferAccessibilityTracks: initialSubtitlePreferences?.preferAccessibilityTracks ?? false,
            disableWhenNoLanguageMatch: initialSubtitlePreferences?.disableWhenNoLanguageMatch ?? false,
            trackSignature: initialSubtitlePreferences?.trackSignature,
            currentAudioLanguage: selectedAudioLanguage
        )
        let effectiveStartPosition = resolvedStartPosition(
            startFromBeginning: startFromBeginning,
            explicitResumePosition: Self.usableResumePosition(resumePosition),
            storedResumePosition: Self.usableResumePosition(watchDetail.userData?.positionSeconds),
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            allowNearEndResume: allowNearEndResume
        )
        logger.info(
            "Selected version fileId=\(selectedVersion.fileId, privacy: .public) resolution=\(selectedVersion.resolution ?? "unknown", privacy: .public) codec=\(selectedVersion.codecVideo ?? "unknown", privacy: .public) bitrate=\(selectedVersion.bitrate ?? 0)"
        )

        // The quality preference is the server's planning input. An explicit
        // override is the user's in-player choice, so it goes as it is rather
        // than as a rung worked out from the selected file.
        let resolvedQualityPreference = preferredQualityOverride != nil || PlaybackFallbackMode.matching(preferredQuality) != nil
            ? preferredQuality
            : requestedQualityPreference(
                preferredQuality: preferredQuality,
                selectedVersion: selectedVersion,
                hasManualSelection: preferredFileId != nil
                    || (prefersLastUsedVersion && selectedVersion.fileId == watchDetail.userData?.lastFileId)
            )
        let profileId = await TokenStore.shared.getProfileId()
        guard let profileId, !profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlaybackV3TerminalFailure(
                reason: "profile_required",
                message: "Select a profile before starting playback.",
                retryable: false
            )
        }
        // Emby and Jellyfin only: the server draws a bitmap pick into a
        // transcode. Silo's plan and its subtitle intent are left alone.
        let burnInSubtitleIndex = ServerSubtitleBurnIn.bitmapStreamIndex(serverBurnInSubtitleIndex, in: selectedVersion)

        if let jellyfinMetadata {
            try validateJellyfinStart(jellyfinAttempt)
            let (prepared, playback) = try await JellyfinPlayback.prepare(
                metadata: jellyfinMetadata, detail: watchDetail, version: selectedVersion,
                start: effectiveStartPosition ?? 0, audioOrdinal: resolvedAudioTrackIndex,
                subtitleIndex: subtitleIntent.ffmpegStreamIndex, bitrateKbps: bandwidthCapKbps,
                quality: resolvedQualityPreference, burnInSubtitleIndex: burnInSubtitleIndex
            )
            try await adoptJellyfinPlayback(playback, prepared: prepared, metadata: jellyfinMetadata, attempt: jellyfinAttempt)
            return prepared
        }
        if let embyMetadata {
            let (prepared, playback) = try await EmbyPlayback.prepare(
                metadata: embyMetadata, detail: watchDetail, version: selectedVersion,
                start: effectiveStartPosition ?? 0, audioOrdinal: resolvedAudioTrackIndex,
                subtitleIndex: subtitleIntent.ffmpegStreamIndex, bitrateKbps: bandwidthCapKbps,
                quality: resolvedQualityPreference, burnInSubtitleIndex: burnInSubtitleIndex
            )
            embyPlayback = playback
            adoptSession(prepared.session)
            return prepared
        }
        // Protocol V3 is Silo's only playback contract: `/api/v1/playback/start`
        // refuses any other `protocol_version`, so there's nothing to fall
        // back to.
        return try await startProtocolV3(
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            profileId: profileId,
            qualityPreference: resolvedQualityPreference,
            bandwidthCapKbps: bandwidthCapKbps,
            startPosition: effectiveStartPosition,
            // The pick, or the track Settings > Playback > Audio Language
            // chose above. The server's remembered audio never decides it.
            audioTrackIndex: resolvedAudioTrackIndex,
            subtitleTrackIndex: subtitleIntent.ffmpegStreamIndex,
            subtitleCombinedIndex: subtitleIntent.combinedIndex
        )
    }

    /// A finite, non-negative resume position, or nil.
    private static func usableResumePosition(_ position: Double?) -> Double? {
        guard let position, position.isFinite, position >= 0 else { return nil }
        return position
    }

    /// The version to ask the server for: the requested file, else the one
    /// last used (when the caller prefers it), else the best match for the
    /// quality preference.
    private func initialVersion(
        in watchDetail: WatchDetail,
        preferredFileId: Int?,
        prefersLastUsedVersion: Bool,
        preferredQuality: String?
    ) -> FileVersion {
        if let preferredFileId,
           let requested = watchDetail.versions.first(where: { $0.fileId == preferredFileId }) {
            logger.info("Using manually selected version fileId=\(requested.fileId, privacy: .public)")
            return requested
        }
        if prefersLastUsedVersion,
           let lastFileId = watchDetail.userData?.lastFileId,
           let lastUsed = watchDetail.versions.first(where: { $0.fileId == lastFileId }) {
            logger.info("Resuming last-used version fileId=\(lastUsed.fileId, privacy: .public)")
            return lastUsed
        }
        if let preferredFileId {
            logger.warning(
                "Requested fileId=\(preferredFileId, privacy: .public) is unavailable; falling back to automatic selection"
            )
        }
        return Self.selectVersion(
            from: watchDetail.versions,
            lastFileId: watchDetail.userData?.lastFileId,
            preferredQuality: preferredQuality
        )
    }

    /// Makes a prepared Jellyfin playback current, retiring the one it
    /// replaces. PlaybackInfo doesn't open a stream (AutoOpenLiveStream is
    /// false), so a candidate that loses is dropped locally: a Jellyfin
    /// Stopped report would end this client's current playback, not just the
    /// candidate.
    private func adoptJellyfinPlayback(
        _ playback: JellyfinPlayback,
        prepared: PreparedPlayback,
        metadata: JellyfinPlayback.Metadata,
        attempt: UUID
    ) async throws {
        try validateJellyfinStart(attempt)
        await waitForJellyfinTransition()
        try validateJellyfinStart(attempt)
        jellyfinTransitionInProgress = true
        jellyfinTransitionPlayback = jellyfinPlayback
        defer { finishJellyfinTransition() }

        // New progress waits on the transition, so this drains the last
        // write before the old playback stops.
        _ = await progressWriteTail?.value
        try validateJellyfinStart(attempt)
        try await metadata.connection.validate()
        try validateJellyfinStart(attempt)

        // Detach before retiring: a cancelled replacement must never leave
        // the bridge pointing at a playback that has already stopped.
        let previous = jellyfinPlayback
        jellyfinPlayback = nil
        sessionId = nil
        currentSession = nil
        if let previous {
            // Unstructured, so cancelling this start can't cut the stop short.
            let retirement = Task { try await previous.retireForReplacement() }
            do {
                try await retirement.value
            } catch {
                logger.warning("Jellyfin replacement stop failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
            }
            try validateJellyfinStart(attempt)
        }
        try await metadata.connection.validate()
        try validateJellyfinStart(attempt)
        jellyfinPlayback = playback
        adoptSession(prepared.session)
    }

    private func adoptSession(_ session: PlaybackSessionResponse) {
        sessionId = session.sessionId
        currentSession = session
        consecutiveProgressFailures = 0
        #if os(iOS) || os(tvOS)
        AppHealthMonitor.playMethodChanged(session.playMethod)
        DiagTrace.breadcrumb(.essential,
            category: .playback,
            tag: "PlaybackSession",
            message: "playback session adopted",
            attrs: [
                "session_id": .string(session.sessionId),
                "play_method": .string(session.playMethod),
            ]
        )
        #endif
    }

    /// The start position: 0 from the beginning, else the explicit or stored
    /// resume point. Against the shorter of the two duration hints, a stored
    /// resume within the last five seconds restarts from 0, and a transient
    /// resume (`allowNearEndResume`) at or past the end is pulled back just
    /// inside it.
    private func resolvedStartPosition(
        startFromBeginning: Bool,
        explicitResumePosition: Double?,
        storedResumePosition: Double?,
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        allowNearEndResume: Bool
    ) -> Double? {
        if startFromBeginning {
            return 0
        }
        guard let candidatePosition = explicitResumePosition ?? storedResumePosition else {
            return nil
        }
        let durationHint = [watchDetail.userData?.durationSeconds, selectedVersion.duration]
            .compactMap { value -> Double? in
                guard let value, value.isFinite, value > 0 else { return nil }
                return value
            }
            .min()
        guard let durationHint else {
            return candidatePosition
        }

        if allowNearEndResume {
            guard candidatePosition >= durationHint else {
                return candidatePosition
            }
            let clampedPosition = max(0, durationHint - Self.pastEndResumeClampSeconds)
            logger.warning(
                "Resume position \(candidatePosition, privacy: .public) reached/passed duration hint \(durationHint, privacy: .public); clamping transient resume to \(clampedPosition, privacy: .public)"
            )
            return clampedPosition
        }

        let nearEndCutoff = max(0, durationHint - Self.nearEndResumeSuppressionSeconds)
        guard candidatePosition >= nearEndCutoff else {
            return candidatePosition
        }
        logger.info(
            "Suppressing resume position \(candidatePosition, privacy: .public) near duration hint \(durationHint, privacy: .public); restarting from beginning"
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
        let resolvedSubtitleCombinedIndex = subtitleCombinedIndex ?? subtitleTrackIndex.flatMap {
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(ffmpegStreamIndex: $0, in: selectedVersion)
        }
        let staged = try await stageProtocolV3Start(
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            profileId: profileId,
            qualityPreference: qualityPreference,
            bandwidthCapKbps: bandwidthCapKbps,
            startPosition: startPosition,
            audioTrackIndex: audioTrackIndex,
            subtitleCombinedIndex: resolvedSubtitleCombinedIndex
        )
        return adoptProtocolV3Start(staged, watchDetail: watchDetail)
    }

    /// Asks the server for a plan and checks Vivid can play it. Every way
    /// out that doesn't return the plan retires the session it allocated.
    private func stageProtocolV3Start(
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        profileId: String,
        qualityPreference: String?,
        bandwidthCapKbps: Int?,
        startPosition: Double?,
        audioTrackIndex: Int?,
        subtitleCombinedIndex: Int?
    ) async throws -> StagedProtocolV3Start {
        let capability = try await PlaybackV3CapabilityGate.shared.requireNeutralProtocolV3()
        // Optional: a server that never advertises authorised media origins
        // doesn't get the token, and the attempt stays on the API origin.
        let requestsAuthorizedMediaOrigins = capability.authorizedMediaOrigins

        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        cmpLog("[CMP-OUTPUT] phase=start \(snapshot.outputDiagnosticsLogFields)")
        let playbackAttemptId = "apple:\(UUID().uuidString.lowercased())"
        let fileId = selectedVersion.fileId
        let request = PlaybackV3StartRequest(
            protocolVersion: PlaybackProtocolV3.version,
            clientFeatures: ApplePlaybackV3Capabilities.startFeatures(
                authorizedMediaOrigins: requestsAuthorizedMediaOrigins
            ),
            fileId: fileId,
            profileId: profileId,
            playbackAttemptId: playbackAttemptId,
            qualityPreference: protocolV3QualityPreference(qualityPreference),
            subtitleFidelityPreference: "preserve",
            progressPersistence: nil,
            startPosition: startPosition,
            audioTrackId: audioTrackIndex.flatMap {
                $0 >= 0 ? protocolV3TrackId(fileId: fileId, kind: "audio", index: $0) : nil
            },
            audioTrackIndex: audioTrackIndex.flatMap { $0 >= 0 ? $0 : nil },
            subtitleTrackId: subtitleCombinedIndex.flatMap {
                $0 >= 0 ? protocolV3TrackId(fileId: fileId, kind: "subtitle", index: $0) : nil
            },
            subtitleTrackIndex: subtitleCombinedIndex,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: bandwidthCapKbps,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )

        logger.info(
            "Starting protocol V3 attempt=\(playbackAttemptId, privacy: .public) fileId=\(fileId, privacy: .public)"
        )
        // Callers cancel this task on the autoplay start timeout and when the
        // player closes. The POST allocates a server session, so it runs
        // shielded from cancellation, and whatever it allocated after the
        // caller walked away is retired rather than left to the server's idle
        // timeout.
        let response = try await PlaybackCancellationShield.run {
            do {
                return try await VividAPI.shared.startPlaybackV3(request: request)
            } catch let error as HTTPError {
                guard case .network = error else { throw error }
                // One retry with the exact request and playback_attempt_id, so
                // an ambiguous first response can't allocate a second logical
                // attempt. It runs inside the shield so the reclaim below sees
                // the final outcome.
                return try await VividAPI.shared.startPlaybackV3(request: request)
            }
        } reclaim: { [self] abandoned in
            guard let orphaned = Self.allocatedSessionId(in: abandoned) else { return }
            await retireAbandonedSession(orphaned, reason: "cancelled_start")
        }

        switch response.validatedForApple() {
        case .terminal(let terminal):
            Task {
                await Self.reportTerminalStart(
                    playbackAttemptId: playbackAttemptId,
                    snapshot: snapshot,
                    terminal: terminal
                )
            }
            throw PlaybackV3TerminalFailure(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            if let allocatedSessionId {
                await retireAbandonedSession(allocatedSessionId, reason: "incompatible_start_response")
            }
            throw PlaybackV3TerminalFailure(
                reason: "invalid_playback_plan",
                message: "The server returned an incompatible protocol V3 playback plan.",
                retryable: false
            )
        case .playable(let plan, let resolvedSessionId):
            guard Self.keepsHeaderAuthenticatedMedia(response) else {
                await retireAbandonedSession(resolvedSessionId, reason: "start_without_header_authenticated_media")
                throw PlaybackV3TerminalFailure(
                    reason: "server_upgrade_required",
                    message: "This server did not honor authenticated media transport for the playback plan.",
                    retryable: false
                )
            }
            do {
                try ApplePlaybackV3PlanAdapter.validate(plan)
            } catch {
                await retireAbandonedSession(resolvedSessionId, reason: "unexecutable_start_plan")
                throw error
            }
            guard let effectiveVersion = watchDetail.versions.first(where: { $0.fileId == plan.effectiveMediaFileId }) else {
                await retireAbandonedSession(resolvedSessionId, reason: "start_effective_file_unavailable")
                throw PlaybackV3TerminalFailure(
                    reason: "effective_file_unavailable",
                    message: "The server selected a media version that is not present in the item response.",
                    retryable: false
                )
            }
            return StagedProtocolV3Start(
                playbackAttemptId: playbackAttemptId,
                clientQualityId: ApplePlaybackQuality.protocolV3QualityId(qualityPreference),
                bandwidthCapKbps: bandwidthCapKbps,
                snapshot: snapshot,
                serverFeatures: response.serverFeatures,
                // Negotiated only when Vivid asked and the server both
                // advertises and honours it; otherwise the plan's media URLs
                // must stay relative to the API and are checked as such.
                negotiatedAuthorizedMediaOrigins: requestsAuthorizedMediaOrigins
                    && response.serverFeatures.contains(PlaybackProtocolV3.authorizedMediaOriginsFeature),
                plan: plan,
                sessionId: resolvedSessionId,
                selectedVersion: effectiveVersion,
                session: ApplePlaybackV3PlanAdapter.playbackSession(
                    plan: plan,
                    sessionId: resolvedSessionId,
                    selectedVersion: effectiveVersion,
                    serverFeatures: response.serverFeatures
                )
            )
        }
    }

    private func adoptProtocolV3Start(
        _ staged: StagedProtocolV3Start,
        watchDetail: WatchDetail
    ) -> PreparedPlayback {
        stageProtocolV3Transition(
            candidateSessionId: staged.sessionId,
            candidatePlanId: staged.plan.planId
        )
        let planAttemptId = "apple-plan:\(UUID().uuidString.lowercased())"
        // Attempt keys belong to the server; the client only echoes them.
        let planAttemptKey = staged.plan.planAttemptKey
        let active = ActiveProtocolV3(
            playbackAttemptId: staged.playbackAttemptId,
            planAttemptId: planAttemptId,
            planAttemptKey: planAttemptKey,
            attemptedPlanKeys: [planAttemptKey],
            attemptCount: 1,
            clientQualityId: staged.clientQualityId,
            usesServerQualityPreference: false,
            bandwidthCapKbps: staged.bandwidthCapKbps,
            snapshot: staged.snapshot,
            serverFeatures: staged.serverFeatures,
            negotiatedAuthorizedMediaOrigins: staged.negotiatedAuthorizedMediaOrigins,
            plan: staged.plan
        )
        activeProtocolV3 = active
        protocolV3FirstFramePlanIds.removeAll()
        adoptSession(staged.session)
        logger.info(
            "Protocol V3 plan selected id=\(staged.plan.planId, privacy: .public) delivery=\(staged.plan.delivery, privacy: .public)"
        )
        return Self.preparedPlayback(
            active: active,
            watchDetail: watchDetail,
            selectedVersion: staged.selectedVersion,
            session: staged.session
        )
    }

    // MARK: - Protocol V3 replan

    /// Asks the server for the next plan after a failure, or for the same
    /// route with a changed track, quality, output or seek position. Returns
    /// nil without a Silo session, or for a seek re-anchor the server doesn't
    /// offer. Throws `CancellationError` when a newer load or a stop replaced
    /// the attempt while the request was out.
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
        guard var active = activeProtocolV3, let currentSessionId = sessionId else {
            return nil
        }
        // Worked out after the guard, because the operation depends on what
        // the server advertised for this attempt.
        let operation = operation ?? Self.replanOperation(
            forClassification: classification,
            serverFeatures: active.serverFeatures
        )
        let expectedAttempt = ProtocolV3AttemptIdentity(active)
        guard active.attemptCount < Self.protocolV3AttemptLimit else {
            throw await failReplan(
                active: active,
                sessionId: currentSessionId,
                reason: "attempt_limit_reached",
                message: "Playback recovery exhausted the protocol V3 route ladder."
            )
        }

        if classification == "output_route_changed" {
            active.snapshot = outputRouteSnapshot ?? ApplePlaybackV3Capabilities.snapshot()
            cmpLog("[CMP-OUTPUT] phase=route_change \(active.snapshot.outputDiagnosticsLogFields)")
        }

        let isSeekReanchor = operation == PlaybackProtocolV3.ReplanOperation.seekReanchor
        if isSeekReanchor, !active.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
            return nil
        }
        let isIntent = [
            PlaybackProtocolV3.ReplanOperation.trackChange,
            PlaybackProtocolV3.ReplanOperation.qualityChange,
            PlaybackProtocolV3.ReplanOperation.outputChange,
        ].contains(operation)
        // An intent (or a new output) starts the route ladder again; a failure
        // excludes every plan key tried so far; a seek re-anchor keeps the
        // current plan.
        let invalidatesIntent = isIntent || classification == "output_route_changed"
        let attemptedKeys = isSeekReanchor
            ? active.attemptedPlanKeys
            : invalidatesIntent
            ? []
            : Array(Set(active.attemptedPlanKeys + [active.planAttemptKey])).sorted()
        let selectedTracks = replanTracks(
            active: active,
            isSeekReanchor: isSeekReanchor,
            classification: classification,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex
        )
        let normalizedPosition = position.isFinite ? max(0, position) : 0

        let qualitySelection = qualityPreference.map {
            ApplePlaybackQuality.protocolV3Selection(
                requestedQualityId: $0,
                availableQualities: active.plan.availableQualities
            )
        }
        let requestedClientQualityId = qualitySelection?.clientQualityId ?? active.clientQualityId
        let requestedUsesServerQualityPreference = qualitySelection?.isServerOwned
            ?? active.usesServerQualityPreference
        let requestedQualityPreference = qualitySelection?.serverPreference
            ?? (requestedUsesServerQualityPreference
                ? requestedClientQualityId
                : protocolV3QualityPreference(requestedClientQualityId))
        // A quality pick brings its own cap, which may be none.
        let requestedBandwidthCapKbps: Int?
        if let qualitySelection {
            requestedBandwidthCapKbps = qualitySelection.bandwidthCapKbps
        } else {
            requestedBandwidthCapKbps = active.bandwidthCapKbps
        }

        #if os(iOS) || os(tvOS)
        // The server's route event below is the real record, but it only
        // exists if its POST succeeds and it lands in the server's telemetry,
        // not the user's diagnostics bundle. The user sees a replan as a
        // reload, so the bundle records that one happened, why and where,
        // without the free-text `message` the classification already sums up.
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "PlaybackSession",
            message: "protocol v3 replan requested",
            attrs: [
                "session_id": .string(currentSessionId),
                "reason": .string(classification),
                "play_method": .string(active.plan.delivery),
                "position_ms": .int(Self.diagnosticsPositionMilliseconds(normalizedPosition)),
            ]
        )
        #endif
        // Telemetry is best effort and mustn't hold up the route change with
        // its own round trip. The attempt is captured now, so a later replan
        // can't change which attempt the event names.
        let eventActive = active
        let eventName = isSeekReanchor
            ? "seek_reanchor_requested"
            : (invalidatesIntent ? "plan_invalidated" : "plan_failed")
        Task {
            await emitProtocolV3Event(
                active: eventActive,
                sessionId: currentSessionId,
                event: eventName,
                classification: classification,
                fallbackReason: nil,
                diagnostics: ["error_cause": String(message.prefix(512))]
            )
        }
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: currentSessionId) else {
            throw CancellationError()
        }

        let request = PlaybackV3ReplanRequest(
            protocolVersion: PlaybackProtocolV3.version,
            // Fixed for the attempt: a replan may neither add nor drop the
            // negotiated origin token, so it repeats the start's choice.
            clientFeatures: ApplePlaybackV3Capabilities.startFeatures(
                authorizedMediaOrigins: active.negotiatedAuthorizedMediaOrigins
            ),
            operation: operation,
            playbackAttemptId: active.playbackAttemptId,
            replanRequestId: "apple-replan:\(UUID().uuidString.lowercased())",
            failedPlanId: active.plan.planId,
            planAttemptId: active.planAttemptId,
            planAttemptKey: active.planAttemptKey,
            attemptedPlanKeys: attemptedKeys,
            attemptCount: invalidatesIntent ? 1 : active.attemptCount,
            qualityPreference: requestedQualityPreference,
            positionSeconds: normalizedPosition,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: requestedBandwidthCapKbps,
            selectedTracks: selectedTracks,
            failure: Self.replanFailure(operation: operation, classification: classification, message: message),
            // Vivid never changes a server plan locally, so it never has a
            // change to fold into the server's next attempt key.
            localMutations: [],
            clientCapabilities: active.snapshot.capabilities,
            clientPlaybackContext: active.snapshot.context
        )
        let response = try await VividAPI.shared.replanPlaybackV3(sessionId: currentSessionId, request: request)
        let validatedResponse = response.validatedForApple()
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: currentSessionId) else {
            discardStaleProtocolV3Response(validatedResponse)
            throw CancellationError()
        }

        let nextPlan: PlaybackV3Plan
        let nextSessionId: String
        switch validatedResponse {
        case .terminal(let terminal):
            await emitProtocolV3Terminal(
                active: active,
                sessionId: currentSessionId,
                reason: terminal.reason,
                message: terminal.message
            )
            throw PlaybackV3TerminalFailure(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            throw await failReplan(
                active: active,
                sessionId: currentSessionId,
                allocatedSessionId: allocatedSessionId,
                retireReason: "incompatible_replan_response",
                reason: "invalid_replan",
                message: "The server returned an incompatible protocol V3 replacement plan."
            )
        case .playable(let plan, let allocatedSessionId):
            nextPlan = plan
            nextSessionId = allocatedSessionId
        }

        guard Self.keepsHeaderAuthenticatedMedia(response) else {
            throw await failReplan(
                active: active,
                sessionId: currentSessionId,
                allocatedSessionId: nextSessionId,
                retireReason: "replan_without_header_authenticated_media",
                reason: "server_upgrade_required",
                message: "The server did not preserve authenticated media transport during replanning."
            )
        }
        do {
            try ApplePlaybackV3PlanAdapter.validate(nextPlan)
        } catch {
            await failReplan(
                active: active,
                sessionId: currentSessionId,
                allocatedSessionId: nextSessionId,
                retireReason: "unexecutable_replan_plan",
                reason: "invalid_replan",
                message: error.localizedDescription
            )
            throw error
        }
        let nextKey = nextPlan.planAttemptKey
        guard isSeekReanchor || !attemptedKeys.contains(nextKey) else {
            throw await failReplan(
                active: active,
                sessionId: currentSessionId,
                allocatedSessionId: nextSessionId,
                retireReason: "replan_loop_detected",
                reason: "replan_loop_detected",
                message: "The server returned a protocol V3 plan that already failed on this output route."
            )
        }
        guard let selectedVersion = watchDetail.versions.first(where: { $0.fileId == nextPlan.effectiveMediaFileId }) else {
            throw await failReplan(
                active: active,
                sessionId: currentSessionId,
                allocatedSessionId: nextSessionId,
                retireReason: "replan_effective_file_unavailable",
                reason: "effective_file_unavailable",
                message: "The replacement plan selected an unavailable media version."
            )
        }
        let nextSession = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: nextPlan,
            sessionId: nextSessionId,
            selectedVersion: selectedVersion,
            serverFeatures: response.serverFeatures
        )
        if isSeekReanchor {
            // A re-anchor moves the same plan to a new position. Anything
            // else changing means the server didn't do what was asked.
            guard nextSessionId == currentSessionId,
                  response.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature),
                  nextKey == active.planAttemptKey,
                  nextPlan.delivery == active.plan.delivery,
                  nextPlan.effectiveRecipe == active.plan.effectiveRecipe,
                  nextPlan.selectedTracks == active.plan.selectedTracks,
                  nextPlan.transformations == active.plan.transformations,
                  nextPlan.appliedQuirks == active.plan.appliedQuirks,
                  nextPlan.runtimeCorrections == active.plan.runtimeCorrections else {
                throw await failReplan(
                    active: active,
                    sessionId: currentSessionId,
                    allocatedSessionId: nextSessionId,
                    retireReason: "invalid_seek_reanchor_response",
                    reason: "invalid_seek_reanchor_response",
                    message: "The server changed the route or playback intent during a V3 seek re-anchor."
                )
            }
        } else {
            active.planAttemptId = "apple-plan:\(UUID().uuidString.lowercased())"
            active.planAttemptKey = nextKey
            active.attemptedPlanKeys = attemptedKeys + [nextKey]
            active.attemptCount = invalidatesIntent ? 1 : active.attemptCount + 1
        }
        active.serverFeatures = response.serverFeatures
        active.plan = nextPlan
        active.clientQualityId = requestedClientQualityId
        active.usesServerQualityPreference = requestedUsesServerQualityPreference
        active.bandwidthCapKbps = requestedBandwidthCapKbps
        stageProtocolV3Transition(
            candidateSessionId: nextSessionId,
            candidatePlanId: nextPlan.planId,
            commitEvent: isSeekReanchor ? "seek_reanchored" : nil,
            // The route event allowlist spells the seek target
            // `target_source_position_seconds`; `position_seconds` is dropped.
            commitDiagnostics: isSeekReanchor
                ? ["target_source_position_seconds": String(normalizedPosition)]
                : [:]
        )
        activeProtocolV3 = active
        adoptSession(nextSession)
        return Self.preparedPlayback(
            active: active,
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            session: nextSession
        )
    }

    /// The tracks a replan asks for. A seek re-anchor keeps the plan's
    /// tracks. Otherwise a valid audio pick replaces the plan's audio, and the
    /// subtitle changes only for a subtitle change, where a negative or
    /// missing index turns subtitles off.
    private func replanTracks(
        active: ActiveProtocolV3,
        isSeekReanchor: Bool,
        classification: String,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?
    ) -> PlaybackV3SelectedTracks {
        let current = active.plan.selectedTracks
        guard !isSeekReanchor else { return current }
        let fileId = active.plan.effectiveMediaFileId
        func track(_ kind: String, _ index: Int?) -> PlaybackV3TrackIdentity? {
            guard let index, index >= 0 else { return nil }
            return PlaybackV3TrackIdentity(id: protocolV3TrackId(fileId: fileId, kind: kind, index: index), index: index)
        }
        return PlaybackV3SelectedTracks(
            audio: track("audio", audioTrackIndex) ?? current.audio,
            subtitle: classification == "subtitle_track_changed"
                ? track("subtitle", subtitleTrackIndex)
                : current.subtitle
        )
    }

    /// Ends a replan that can't go on: retires the session it allocated
    /// (unless that's the current one), records the terminal route event and
    /// returns the failure to throw.
    @discardableResult
    private func failReplan(
        active: ActiveProtocolV3,
        sessionId currentSessionId: String,
        allocatedSessionId: String? = nil,
        retireReason: String? = nil,
        reason: String,
        message: String
    ) async -> PlaybackV3TerminalFailure {
        if let allocatedSessionId, let retireReason, allocatedSessionId != currentSessionId {
            await retireAbandonedSession(allocatedSessionId, reason: retireReason)
        }
        await emitProtocolV3Terminal(active: active, sessionId: currentSessionId, reason: reason, message: message)
        return PlaybackV3TerminalFailure(reason: reason, message: message, retryable: false)
    }

    private func isCurrentProtocolV3Attempt(
        _ expected: ProtocolV3AttemptIdentity,
        sessionId expectedSessionId: String
    ) -> Bool {
        guard !Task.isCancelled,
              sessionId == expectedSessionId,
              currentSession?.sessionId == expectedSessionId,
              let activeProtocolV3 else {
            return false
        }
        return ProtocolV3AttemptIdentity(activeProtocolV3) == expected
    }

    /// Retires a session a superseded replan allocated, unless it's the one
    /// still in use.
    private func discardStaleProtocolV3Response(_ response: PlaybackV3DecisionValidation) {
        let allocatedSessionId: String?
        switch response {
        case .playable(_, let responseSessionId):
            allocatedSessionId = responseSessionId
        case .incompatible(let responseSessionId):
            allocatedSessionId = responseSessionId
        case .terminal:
            allocatedSessionId = nil
        }
        guard let allocatedSessionId, allocatedSessionId != sessionId else { return }
        stopStaleSession(allocatedSessionId)
    }

    // MARK: - Protocol V3 transitions

    /// Records a server plan as pending until Vivid commits the matching load,
    /// keeping the last committed state for a rollback.
    private func stageProtocolV3Transition(
        candidateSessionId: String,
        candidatePlanId: String,
        commitEvent: String? = nil,
        commitDiagnostics: [String: String] = [:]
    ) {
        // A newer load replacing an uncommitted candidate first restores the
        // last committed state and retires the abandoned allocation. A replan
        // of that uncommitted candidate reuses its session, so that session is
        // about to be staged again; retiring it would delete the session the
        // engine is about to read from and strand playback retrying 404s.
        rollbackAnyPendingProtocolV3Transition(retainingSessionId: candidateSessionId)
        pendingProtocolV3Transition = PendingProtocolV3Transition(
            priorSessionId: sessionId,
            priorSession: currentSession,
            priorProtocolV3: activeProtocolV3,
            candidateSessionId: candidateSessionId,
            candidatePlanId: candidatePlanId,
            commitEvent: commitEvent,
            commitDiagnostics: commitDiagnostics
        )
    }

    /// Commits the server decision once Vivid's load has committed. False when
    /// a newer transition or a teardown already won.
    func commitPendingProtocolV3Transition(_ prepared: PreparedPlayback) -> Bool {
        guard let pending = currentPendingTransition(for: prepared) else { return false }
        pendingProtocolV3Transition = nil
        retirePriorSession(of: pending)
        if let event = pending.commitEvent, let activeProtocolV3 {
            // Route telemetry is best effort and mustn't let this actor be
            // re-entered between committing and returning to the player: a
            // teardown or newer load could run during the request and then
            // be followed by stale player work.
            let committedActive = activeProtocolV3
            let committedSessionId = pending.candidateSessionId
            let committedDiagnostics = pending.commitDiagnostics
            Task {
                await emitProtocolV3Event(
                    active: committedActive,
                    sessionId: committedSessionId,
                    event: event,
                    classification: nil,
                    fallbackReason: nil,
                    diagnostics: committedDiagnostics
                )
            }
        }
        return true
    }

    /// The committed session, only while it still belongs to the exact plan
    /// the player is recovering. The player can then rebuild the same plan
    /// with fresh request headers without moving the server's route ladder.
    func committedProtocolV3Session(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String
    ) -> PlaybackSessionResponse? {
        guard pendingProtocolV3Transition == nil,
              sessionId == expectedSessionId,
              currentSession?.sessionId == expectedSessionId,
              activeProtocolV3?.plan.planId == expectedPlanId else {
            return nil
        }
        return currentSession
    }

    /// Promotes a candidate Vivid couldn't open, only so the player can report
    /// that failed attempt and ask for the next route. This isn't a commit: it
    /// sends no success event, binds no realtime channel and can't report a
    /// first frame. The failed candidate still becomes the current attempt,
    /// because a V3 replan has to name the plan that actually failed.
    func promotePendingProtocolV3TransitionForRecovery(_ prepared: PreparedPlayback) -> Bool {
        guard let pending = currentPendingTransition(for: prepared) else { return false }
        pendingProtocolV3Transition = nil
        retirePriorSession(of: pending)
        return true
    }

    /// Restores the last committed state after a bad URL, a cancellation or a
    /// failed load, and retires a distinct candidate session. A same-session
    /// replan restores client state only; the server keeps its own attempt
    /// history for the next replan.
    func rollbackPendingProtocolV3Transition(_ prepared: PreparedPlayback) {
        guard pendingTransition(for: prepared) != nil else { return }
        rollbackAnyPendingProtocolV3Transition()
    }

    /// The pending transition, when it's for `prepared`.
    private func pendingTransition(for prepared: PreparedPlayback) -> PendingProtocolV3Transition? {
        guard let pending = pendingProtocolV3Transition,
              pending.candidateSessionId == prepared.session.sessionId,
              pending.candidatePlanId == prepared.protocolV3?.plan.planId else {
            return nil
        }
        return pending
    }

    /// The pending transition for `prepared`, when its candidate is still the
    /// bridge's current session and plan.
    private func currentPendingTransition(for prepared: PreparedPlayback) -> PendingProtocolV3Transition? {
        guard let pending = pendingTransition(for: prepared),
              sessionId == pending.candidateSessionId,
              activeProtocolV3?.plan.planId == pending.candidatePlanId else {
            return nil
        }
        return pending
    }

    /// Retires the session a committed or promoted transition replaced.
    private func retirePriorSession(of pending: PendingProtocolV3Transition) {
        if let priorSessionId = pending.priorSessionId, priorSessionId != pending.candidateSessionId {
            stopStaleSession(priorSessionId)
        }
    }

    /// `retainingSessionId` names a session the caller is about to stage
    /// again, which is left alive rather than retired as abandoned.
    private func rollbackAnyPendingProtocolV3Transition(retainingSessionId: String? = nil) {
        guard let pending = pendingProtocolV3Transition else { return }
        pendingProtocolV3Transition = nil
        sessionId = pending.priorSessionId
        currentSession = pending.priorSession
        activeProtocolV3 = pending.priorProtocolV3
        if Self.shouldRetireRolledBackCandidate(
            candidateSessionId: pending.candidateSessionId,
            priorSessionId: pending.priorSessionId,
            retainingSessionId: retainingSessionId
        ) {
            stopStaleSession(pending.candidateSessionId)
        }
    }

    /// Clean-up has to outlive the cancelled request that produced the stale
    /// session, so it runs in an unstructured task that doesn't inherit the
    /// caller's cancellation. It's best effort; the server's idle timeout is
    /// the last resort.
    private func stopStaleSession(_ staleSessionId: String) {
        Task {
            await self.retireAbandonedSession(staleSessionId, reason: "stale_allocation")
        }
    }

    /// Retires a session this client allocated but will never play. Nothing
    /// can recover a failure (the server reclaims idle sessions itself), but
    /// it costs the user a lingering session slot, so it's logged.
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
        guard let active = activeProtocolV3,
              let sessionId,
              sessionId == prepared.session.sessionId,
              active.plan.planId == prepared.protocolV3?.plan.planId else { return }
        for correction in active.plan.runtimeCorrections {
            await emitProtocolV3Event(
                active: active,
                sessionId: sessionId,
                event: "runtime_correction_applied",
                classification: nil,
                fallbackReason: nil,
                diagnostics: ["correction_id": correction, "correction_stage": "applied"]
            )
        }
    }

    /// Reports a plan's first frame once, then its runtime corrections as
    /// succeeded.
    func reportProtocolV3FirstFrame(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String,
        milliseconds: Int?
    ) async {
        guard let active = activeProtocolV3,
              let sessionId,
              sessionId == expectedSessionId,
              active.plan.planId == expectedPlanId,
              protocolV3FirstFramePlanIds.insert(active.plan.planId).inserted else { return }
        var diagnostics: [String: String] = [:]
        if let milliseconds { diagnostics["first_frame_ms"] = String(max(0, milliseconds)) }
        await emitProtocolV3Event(
            active: active,
            sessionId: sessionId,
            event: "first_frame",
            classification: nil,
            fallbackReason: nil,
            diagnostics: diagnostics
        )
        for correction in active.plan.runtimeCorrections {
            await emitProtocolV3Event(
                active: active,
                sessionId: sessionId,
                event: "runtime_correction_succeeded",
                classification: nil,
                fallbackReason: nil,
                diagnostics: ["correction_id": correction, "correction_stage": "succeeded"]
            )
        }
    }

    private func emitProtocolV3Event(
        active: ActiveProtocolV3,
        sessionId: String,
        event: String,
        classification: String?,
        fallbackReason: String?,
        diagnostics: [String: String]
    ) async {
        let event = PlaybackV3RouteEvent(
            protocolVersion: PlaybackProtocolV3.version,
            playbackAttemptId: active.playbackAttemptId,
            sessionId: sessionId,
            planId: active.plan.planId,
            planAttemptId: active.planAttemptId,
            planAttemptKey: active.planAttemptKey,
            event: event,
            failureClassification: classification,
            fallbackReason: fallbackReason,
            appliedQuirkIds: active.plan.appliedQuirks.map(\.id),
            quirkRegistryRevision: active.plan.appliedQuirks.first?.registryRevision,
            outputContextId: active.snapshot.outputContextId,
            diagnostics: diagnostics
        )
        do {
            try await VividAPI.shared.reportPlaybackRouteEventV3(event)
        } catch {
            logger.warning("Protocol V3 route event \(event.event, privacy: .public) failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
        }
    }

    private func emitProtocolV3Terminal(
        active: ActiveProtocolV3,
        sessionId: String,
        reason: String,
        message: String
    ) async {
        #if os(iOS) || os(tvOS)
        // Every dead end of the route ladder comes through here, so one
        // breadcrumb covers them all. `reason` is the server's stable token;
        // the prose `message` is left out on purpose.
        DiagTrace.breadcrumb(
            .essential,
            level: .error,
            category: .playback,
            tag: "PlaybackSession",
            message: "protocol v3 route exhausted",
            attrs: [
                "session_id": .string(sessionId),
                "reason": .string(reason),
                "play_method": .string(active.plan.delivery),
            ]
        )
        #endif
        await emitProtocolV3Event(
            active: active,
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
    /// Jellyfin and reports zero to Silo, answering `deferred`. A
    /// `completedContentId` makes the position eligible and marks that item
    /// watched once the position is written.
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
            try await VividAPI.shared.reportPlaybackProgress(
                sessionId: sid,
                report: ProgressReport(position: position, isPaused: isPaused)
            )
            consecutiveProgressFailures = 0
            emittedOrphanedSessionWarning = false
            return .success
        } catch {
            consecutiveProgressFailures += 1
            logger.warning(
                "reportProgress failed for session \(sid, privacy: .public) (consecutive=\(self.consecutiveProgressFailures)): \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
            if Self.isPlaybackSessionMissing(error) {
                emittedOrphanedSessionWarning = true
                logger.error("playback session \(sid, privacy: .public) no longer exists on server; renewal required")
                return .missingSession
            }
            if consecutiveProgressFailures >= Self.orphanedSessionLogThreshold, !emittedOrphanedSessionWarning {
                emittedOrphanedSessionWarning = true
                logger.error(
                    "playback session \(sid, privacy: .public) progress reporting has failed \(self.consecutiveProgressFailures) consecutive times; server-side session may be stale"
                )
            }
            return .transientFailure
        }
    }

    /// Saves an offline position to the server. False for an empty id, an
    /// unusable position or a failed request.
    func syncProgress(
        contentId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool
    ) async -> Bool {
        guard !contentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              position.isFinite,
              position >= 0 else {
            return false
        }
        do {
            try await VividAPI.shared.syncProgress(
                mediaItemId: contentId,
                position: position,
                duration: duration.isFinite && duration > 0 ? duration : 0,
                forceOverwrite: forceOverwrite
            )
            return true
        } catch {
            logger.warning(
                "syncProgress failed for \(contentId, privacy: .public) at \(position, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Stopping

    /// Retires the current session exactly once.
    ///
    /// The actor can be re-entered at each `await` below (the route event,
    /// the final progress and the DELETE). So the session id is claimed and
    /// every session-scoped value cleared before the first one: a second
    /// caller (a teardown racing an autoplay transition) then finds nothing
    /// to stop instead of sending a duplicate final report and DELETE, and
    /// the late clears can't wipe a new session adopted in the meantime.
    @discardableResult
    func stopSession(
        position: Double,
        isPaused: Bool,
        eligible: Bool,
        completedContentId: String? = nil,
        finalProgressAlreadyReported: Bool = false
    ) async -> PlaybackProgressReportResult {
        let stopAttempt = UUID()
        jellyfinStartAttempt = stopAttempt
        if jellyfinTransitionInProgress {
            await waitForJellyfinTransition()
            guard jellyfinStartAttempt == stopAttempt else { return .deferred }
        }
        guard let sid = sessionId else { return .transientFailure }
        let pendingProgress = progressWriteTail
        let eligible = eligible || completedContentId != nil

        if let playback = jellyfinPlayback {
            jellyfinTransitionInProgress = true
            jellyfinTransitionPlayback = playback
            defer { finishJellyfinTransition() }
            jellyfinPlayback = nil
            sessionId = nil
            currentSession = nil
            _ = await pendingProgress?.value
            guard eligible else {
                do {
                    try await playback.stopWithoutProgress()
                    return .deferred
                } catch {
                    return .transientFailure
                }
            }
            let stopResult: PlaybackProgressReportResult
            do {
                try await playback.report(position: position, isPaused: isPaused, stopping: true)
                stopResult = .success
            } catch {
                logger.warning("Jellyfin stop report failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
                stopResult = .transientFailure
            }
            return await writeJellyfinCompletion(after: stopResult, contentId: completedContentId, playback: playback)
        }

        if let playback = embyPlayback {
            embyPlayback = nil
            sessionId = nil
            currentSession = nil
            _ = await pendingProgress?.value
            do {
                guard eligible else {
                    try await playback.stopWithoutProgress()
                    return .deferred
                }
                try await playback.report(position: position, isPaused: isPaused, stopping: true)
            } catch {
                return .transientFailure
            }
            return await writeCompletion(after: .success, contentId: completedContentId, playback: playback)
        }

        let stoppingProtocolV3 = activeProtocolV3
        let supersededSessionId = pendingProtocolV3Transition?.priorSessionId
        sessionId = nil
        currentSession = nil
        activeProtocolV3 = nil
        pendingProtocolV3Transition = nil
        protocolV3FirstFramePlanIds.removeAll()
        consecutiveProgressFailures = 0
        emittedOrphanedSessionWarning = false

        _ = await pendingProgress?.value
        if let supersededSessionId, supersededSessionId != sid {
            stopStaleSession(supersededSessionId)
        }
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(.essential,
            category: .playback,
            tag: "PlaybackSession",
            message: "playback session stopped",
            attrs: [
                "session_id": .string(sid),
                // The attribute registry has no float type, so the position
                // goes in whole milliseconds.
                "position_ms": .int(Self.diagnosticsPositionMilliseconds(position)),
            ]
        )
        #endif

        if let active = stoppingProtocolV3 {
            await emitProtocolV3Event(
                active: active,
                sessionId: sid,
                event: "stopped",
                classification: nil,
                fallbackReason: nil,
                diagnostics: ["target_source_position_seconds": String(position.isFinite ? max(0, position) : 0)]
            )
        }

        var finalProgressResult: PlaybackProgressReportResult = finalProgressAlreadyReported ? .success : .transientFailure
        if !finalProgressAlreadyReported, position.isFinite, position >= 0 {
            do {
                try await VividAPI.shared.reportPlaybackProgress(
                    sessionId: sid,
                    report: ProgressReport(position: eligible ? position : 0, isPaused: isPaused)
                )
                finalProgressResult = eligible ? .success : .deferred
            } catch {
                finalProgressResult = Self.isPlaybackSessionMissing(error) ? .missingSession : .transientFailure
                logger.warning(
                    "final stop-session progress report failed for \(sid, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
            }
        }

        do {
            try await VividAPI.shared.stopPlayback(sessionId: sid)
        } catch {
            // Best effort: the server ends idle sessions itself, but a missed
            // DELETE holds the slot longer, so failures are logged.
            logger.error(
                "stop-session DELETE failed for \(sid, privacy: .public); server-side session may linger until idle timeout: \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }

        #if os(tvOS)
        // Progress has moved, so the Top Shelf fetches again.
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
        return await writeCompletion(after: finalProgressResult, contentId: completedContentId, playback: nil)
    }

    // MARK: - Helpers

    private func normalizedQualityPreference(_ quality: String?) -> String? {
        let normalized = ApplePlaybackQuality.normalizeStoredId(quality)
        return normalized == ApplePlaybackQuality.autoId ? nil : normalized
    }

    /// The quality preference a start or replan sends: a ladder rung goes as
    /// its resolution alone, anything else as its server id.
    private func protocolV3QualityPreference(_ quality: String?) -> String {
        let serverId = ApplePlaybackQuality.protocolV3QualityId(quality)
        if ApplePlaybackQuality.requestOptions.contains(where: { $0.id == serverId }) {
            return AppleQualityAxes.split(serverId).resolution
        }
        return serverId
    }

    private func protocolV3TrackId(fileId: Int, kind: String, index: Int) -> String {
        "file:\(fileId):\(kind):\(index)"
    }

    /// With a manual or last-used version, the request asks for that file's
    /// own resolution; otherwise for the preference as it is.
    private func requestedQualityPreference(
        preferredQuality: String?,
        selectedVersion: FileVersion,
        hasManualSelection: Bool
    ) -> String? {
        guard hasManualSelection else {
            return preferredQuality
        }
        return selectedVersion.resolution ?? preferredQuality ?? "original"
    }
}

// MARK: - Rules

extension PlaybackSessionBridge {
    /// Resolves "Auto" before the first V3 request. The player otherwise
    /// applies the same rules only after opening the file, which could show a
    /// default or forced track while the server's plan still has subtitles
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
        let none = InitialProtocolV3SubtitleIntent(ffmpegStreamIndex: nil, combinedIndex: nil)
        if let explicitCombinedIndex {
            return InitialProtocolV3SubtitleIntent(
                ffmpegStreamIndex: explicitFFmpegIndex.flatMap { $0 >= 0 ? $0 : nil },
                combinedIndex: explicitCombinedIndex >= 0 ? explicitCombinedIndex : nil
            )
        }
        if let explicitFFmpegIndex {
            guard explicitFFmpegIndex >= 0 else { return none }
            return InitialProtocolV3SubtitleIntent(
                ffmpegStreamIndex: explicitFFmpegIndex,
                combinedIndex: ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                    ffmpegStreamIndex: explicitFFmpegIndex,
                    in: version
                )
            )
        }

        let candidates = SubtitleTrackCandidates.playerTracks(from: version.subtitleTracks ?? [])
        let resolution = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: preferredLanguage,
            additionalPreferredLanguages: additionalPreferredLanguages,
            mode: mode,
            showForced: showForced,
            forcedOnly: forcedOnly,
            preferAccessibilityTracks: preferAccessibilityTracks,
            disableWhenNoLanguageMatch: disableWhenNoLanguageMatch,
            trackSignature: trackSignature,
            availableSubtitles: candidates,
            currentAudioLanguage: currentAudioLanguage
        ))
        let selected: PlayerTrack?
        switch resolution {
        case .select(let track):
            selected = track
        case .disable:
            selected = nil
        case .noChange:
            // Leaving the player alone means its demuxer keeps the media's
            // default track, and the sidecar route also promotes a forced
            // one. That choice is fixed into the plan up front.
            selected = candidates.first(where: { $0.isDefault }) ?? candidates.first(where: { $0.isForced })
        }
        guard let selected else { return none }
        return InitialProtocolV3SubtitleIntent(
            ffmpegStreamIndex: selected.ffIndex,
            combinedIndex: ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(for: selected, in: version)
        )
    }

    /// The session a start or replan decision allocated, if any. A terminal
    /// outcome allocates nothing; a playable plan and an incompatible one can
    /// both carry a live session that needs retiring.
    static func allocatedSessionId(in response: PlaybackV3DecisionResponse) -> String? {
        switch response.validatedForApple() {
        case .playable(_, let allocated):
            allocated
        case .incompatible(let allocated):
            allocated
        case .terminal:
            nil
        }
    }

    /// Maps a failure or intent classification onto the protocol's replan
    /// operation. A track or quality change is an intent, not a failure, and
    /// carries no `failure` block.
    ///
    /// This overload predates `output_change_v1` and keeps an output route
    /// change on `failure_recovery`. Prefer the `serverFeatures` overload:
    /// only it can tell whether the server offers the intent operation.
    static func replanOperation(forClassification classification: String) -> String {
        switch classification {
        case "audio_track_changed", "subtitle_track_changed":
            PlaybackProtocolV3.ReplanOperation.trackChange
        case "quality_changed":
            PlaybackProtocolV3.ReplanOperation.qualityChange
        default:
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        }
    }

    /// A new output route is an intent, not a failed recipe: the device never
    /// rejected the plan, the display it was chosen for changed.
    /// `output_change` means exactly that and keeps the previous route
    /// eligible, where `failure_recovery` excludes the current plan key and
    /// forces a different route even when the new output could still play it.
    ///
    /// The operation only exists on a server advertising `output_change_v1`;
    /// an older one refuses it, so `failure_recovery` stays the fallback.
    static func replanOperation(
        forClassification classification: String,
        serverFeatures: [String]
    ) -> String {
        if classification == "output_route_changed",
           serverFeatures.contains(PlaybackProtocolV3.outputChangeFeature) {
            return PlaybackProtocolV3.ReplanOperation.outputChange
        }
        return replanOperation(forClassification: classification)
    }

    /// AVAudioSession posts route changes for configuration the player makes
    /// itself (choosing a multichannel layout, for example). A V3 route replan
    /// is only warranted when the output identity the plan was chosen for
    /// actually changed.
    static func isMaterialOutputRouteChange(
        activeOutputContextId: String?,
        observedOutputContextId: String?
    ) -> Bool {
        activeOutputContextId != observedOutputContextId
    }

    static func supportsNeutralProtocolV3(_ capability: PlaybackV3CapabilityResponse) -> Bool {
        capability.enabled
            && capability.protocolVersions.contains(PlaybackProtocolV3.version)
            && capability.features.contains(PlaybackProtocolV3.planFeature)
            && capability.features.contains(PlaybackProtocolV3.neutralContractFeature)
            && (capability.nativeApiMajor == 2 || capability.features.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature))
    }

    /// A server without the capability route answers 404 or 405.
    static func isMissingProtocolV3Capability(_ error: Error) -> Bool {
        guard let httpError = error as? HTTPError, case .http(let statusCode, _) = httpError else {
            return false
        }
        return statusCode == 404 || statusCode == 405
    }

    /// A decision is only usable when its media stays header-authenticated:
    /// native API 2 always is, older servers must say so.
    private static func keepsHeaderAuthenticatedMedia(_ response: PlaybackV3DecisionResponse) -> Bool {
        response.nativeApiMajor == 2
            || response.serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature)
    }

    static func terminalStartRouteEvent(
        playbackAttemptId: String,
        snapshot: ApplePlaybackV3CapabilitySnapshot,
        terminal: PlaybackV3Terminal
    ) -> PlaybackV3RouteEvent {
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
        let event = terminalStartRouteEvent(
            playbackAttemptId: playbackAttemptId,
            snapshot: snapshot,
            terminal: terminal
        )
        do {
            try await VividAPI.shared.reportPlaybackRouteEventV3(event)
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
                category: "Playback"
            ).warning(
                "Protocol V3 terminal-start route event failed: \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }
    }

    /// The `failure` block a replan sends: none for an intent or a seek
    /// re-anchor (the server refuses an `output_change` that carries one),
    /// otherwise the classification and the first 512 characters of the
    /// message.
    static func replanFailure(
        operation: String,
        classification: String,
        message: String
    ) -> PlaybackV3Failure? {
        switch operation {
        case PlaybackProtocolV3.ReplanOperation.trackChange,
             PlaybackProtocolV3.ReplanOperation.qualityChange,
             PlaybackProtocolV3.ReplanOperation.outputChange,
             PlaybackProtocolV3.ReplanOperation.seekReanchor:
            nil
        default:
            PlaybackV3Failure(
                classification: classification,
                message: String(message.prefix(512)),
                decoderName: nil
            )
        }
    }

    /// A rolled-back candidate is retired only when nothing else still owns
    /// it: not the committed session it replaced, and not a transition about
    /// to stage the same session again (a replan of an uncommitted start
    /// reuses the start's session).
    static func shouldRetireRolledBackCandidate(
        candidateSessionId: String,
        priorSessionId: String?,
        retainingSessionId: String?
    ) -> Bool {
        candidateSessionId != priorSessionId && candidateSessionId != retainingSessionId
    }

    /// A position in seconds as whole, non-negative milliseconds for the
    /// `playback.position_ms` diagnostics attribute. Non-finite and negative
    /// values become zero.
    static func diagnosticsPositionMilliseconds(_ position: Double) -> Int {
        let seconds = position.isFinite ? max(0, position) : 0
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds < Double(Int.max) else { return Int.max }
        return Int(milliseconds)
    }

    /// Silo's answer for a session it no longer has: 404 with the
    /// `playback_session_not_found` code or that message in the body.
    static func isPlaybackSessionMissing(_ error: Error) -> Bool {
        guard let httpError = error as? HTTPError, case .http(404, let body) = httpError else {
            return false
        }
        return httpError.serverErrorCode == "playback_session_not_found"
            || (body ?? "").contains("Playback session not found")
    }

    /// The best version for the preferred quality. The server does the
    /// compatibility filtering from the capability snapshot and may answer
    /// with a different `effective_media_file_id`; this only decides which
    /// version the request asks for. Order: the best-ranked version within
    /// the preferred quality, else the last-used one, else the best-ranked.
    static func selectVersion(
        from versions: [FileVersion],
        lastFileId: Int?,
        preferredQuality: String?
    ) -> FileVersion {
        let ranked = versions.sorted {
            score(for: $0, preferredQuality: preferredQuality) > score(for: $1, preferredQuality: preferredQuality)
        }
        if let preferredQuality,
           let matchingQuality = ranked.first(where: { qualityMatches($0.resolution, preferredQuality: preferredQuality) }) {
            return matchingQuality
        }
        if let lastFileId, let lastUsed = versions.first(where: { $0.fileId == lastFileId }) {
            return lastUsed
        }
        return ranked.first ?? versions[0]
    }

    /// The Protocol V3 half of a `PreparedPlayback`, from the active attempt.
    private static func preparedPlayback(
        active: ActiveProtocolV3,
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse
    ) -> PreparedPlayback {
        PreparedPlayback(
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            session: session,
            activeQualityId: ApplePlaybackQuality.activeProtocolV3QualityId(
                requestedQualityId: active.clientQualityId,
                availableQualities: active.plan.availableQualities
            ),
            bandwidthCap: .inEffect(active.bandwidthCapKbps),
            protocolV3: PreparedPlaybackV3(
                playbackAttemptId: active.playbackAttemptId,
                planAttemptId: active.planAttemptId,
                planAttemptKey: active.planAttemptKey,
                outputContextId: active.snapshot.outputContextId,
                serverFeatures: active.serverFeatures,
                negotiatedAuthorizedMediaOrigins: active.negotiatedAuthorizedMediaOrigins,
                plan: active.plan
            )
        )
    }

    private static func score(for version: FileVersion, preferredQuality: String?) -> Int {
        var score = resolutionRank(version.resolution) * 10
        if let preferredQuality {
            if preferredQuality == "original" {
                score += 5
            } else if qualityMatches(version.resolution, preferredQuality: preferredQuality) {
                score += 100
            } else if resolutionRank(version.resolution) > resolutionRank(preferredQuality) {
                score -= 50
            }
        }
        return score
    }

    private static func qualityMatches(_ resolution: String?, preferredQuality: String) -> Bool {
        let versionRank = resolutionRank(resolution)
        if preferredQuality == ApplePlaybackQuality.originalId {
            return versionRank > 0
        }
        return versionRank > 0 && versionRank <= resolutionRank(preferredQuality)
    }

    private static func resolutionRank(_ value: String?) -> Int {
        guard let value = value?.lowercased() else { return 0 }
        if value.contains("2160") || value.contains("4k") { return 4 }
        if value.contains("1080") { return 3 }
        if value.contains("720") { return 2 }
        if value.contains("480") { return 1 }
        return 0
    }
}
