import Foundation
import OSLog

/// Silo's realtime channel: commands from the server or an administrator,
/// events about the playing file, and the transient notices they show.
extension PlayerViewModel {
    // MARK: - Events

    @MainActor
    func handleRealtimeEvent(_ event: PlaybackRealtimeEventEnvelope) async {
        guard event.sessionId == activePlaybackSessionId else { return }
        switch event.name {
        case .markersUpdated:
            // Server marker updates must not replace the selected file's markers.
            break
        case .chapterThumbnailReady:
            break
        case .subtitleReady:
            offerReadySiloSubtitle(event.payload)
        case .subtitleTranslationStarted, .subtitleTranslationCues,
             .subtitleTranslationCompleted, .subtitleTranslationFailed:
            // Silo sends these only to the session that asked for a live
            // translation, which Vivid doesn't do.
            break
        case .unknown(let raw):
            Self.logger.debug("[CMP-RT] ignoring unknown realtime event \(raw, privacy: .public)")
        }
    }

    /// Silo says when it has finished making a subtitle for the playing file
    /// (AI transcription or translation), with the place the next plan will
    /// list it. It's offered as a row straight away and fetched only when
    /// chosen, like the plan's own stored subtitles.
    @MainActor
    func offerReadySiloSubtitle(_ payload: PlaybackRealtimePayload) {
        guard let request = lazySubtitleSidecarRequest, let plan = activePreparedProtocolV3?.plan,
              let item = Self.readySiloSubtitle(payload, fileID: plan.effectiveMediaFileId),
              offerSiloSidecar(item, request: request, nativeApiMajor: plan.nativeApiMajor) else { return }
        adoptVividInventory()
    }

    /// The stored subtitle a `subtitle_ready` event names for this file, or
    /// nil when the event names none. An older Silo sends no `track`.
    static func readySiloSubtitle(_ payload: PlaybackRealtimePayload, fileID: Int) -> PlaybackV3SubtitleInventoryItem? {
        guard payload.int(forKeys: "file_id") == fileID, let track = payload["track"],
              case .object = track, let data = try? JSONEncoder().encode(track) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let item = try? decoder.decode(PlaybackV3SubtitleInventoryItem.self, from: data),
              item.source == "downloaded" else { return nil }
        return item
    }

    // MARK: - Commands

    /// Carries out a command, or throws the reason it can't. Commands an
    /// administrator issued also say so on screen.
    @MainActor
    func handleRealtimeCommand(_ command: PlaybackRealtimeCommandEnvelope) async throws {
        let byAdmin = isAdminIssued(command)
        switch command.name {
        case .pause:
            vividPlaybackController.pause()
            if byAdmin { showAdminPlaybackNotice(paused: true) }
        case .unpause:
            vividPlaybackController.play()
            if byAdmin { showAdminPlaybackNotice(paused: false) }
        case .playPause:
            let wasPaused = vividPlaybackController.isPaused
            if wasPaused {
                vividPlaybackController.play()
            } else {
                vividPlaybackController.pause()
            }
            if byAdmin { showAdminPlaybackNotice(paused: !wasPaused) }
        case .seek:
            guard !isLoading else {
                throw PlaybackRealtimeCommandExecutionError.playerNotReady
            }
            guard let position = command.payload.number(forKeys: "position", "position_seconds", "seconds") else {
                throw PlaybackRealtimeCommandExecutionError.missingSeekPosition
            }
            applyRemoteSeek(to: position)
            if byAdmin {
                showNotice(
                    title: String(localized: "Playback changed by admin"),
                    message: String(localized: "An administrator changed the playback position."),
                    tone: .warning,
                    duration: 5
                )
            }
        case .displayMessage:
            showNotice(
                title: command.payload.string(forKeys: "title")
                    ?? (byAdmin ? String(localized: "Message from admin") : String(localized: "Playback notice")),
                message: command.payload.string(forKeys: "message")
                    ?? String(localized: "A server message was received."),
                tone: byAdmin ? .warning : .info,
                duration: byAdmin ? 10 : 8
            )
        case .serverRestarting:
            showNotice(
                title: command.payload.string(forKeys: "title") ?? String(localized: "Server restarting"),
                message: command.payload.string(forKeys: "message")
                    ?? String(localized: "Playback may end shortly while the server restarts."),
                tone: .warning,
                duration: 10
            )
        case .serverShuttingDown:
            showNotice(
                title: command.payload.string(forKeys: "title") ?? String(localized: "Server shutting down"),
                message: command.payload.string(forKeys: "message")
                    ?? String(localized: "Playback may end shortly while the server shuts down."),
                tone: .warning,
                duration: 10
            )
        case .stop, .terminate:
            vividPlaybackController.pause()
            guard byAdmin else {
                requestRemoteDismiss()
                return
            }
            // A short notice, then the player closes.
            let isTerminate = command.name == .terminate
            showNotice(
                title: command.payload.string(forKeys: "title")
                    ?? (isTerminate ? String(localized: "Session ended by admin") : String(localized: "Playback stopped by admin")),
                message: command.payload.string(forKeys: "message")
                    ?? (isTerminate
                        ? String(localized: "An administrator ended this playback session.")
                        : String(localized: "An administrator stopped this playback session.")),
                tone: .warning,
                duration: 1.2
            )
            requestRemoteDismiss(after: 0.8)
        case .setVolume, .playMedia, .setAudioTrack, .setSubtitleTrack:
            throw PlaybackRealtimeCommandExecutionError.unsupportedCommand
        }
    }

    private func isAdminIssued(_ command: PlaybackRealtimeCommandEnvelope) -> Bool {
        command.issuedBy?.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "admin"
    }

    /// The notice for an administrator pausing or resuming this session.
    private func showAdminPlaybackNotice(paused: Bool) {
        showNotice(
            title: paused ? String(localized: "Playback paused by admin") : String(localized: "Playback resumed by admin"),
            message: paused
                ? String(localized: "An administrator paused this session.")
                : String(localized: "An administrator resumed this session."),
            tone: paused ? .warning : .info,
            duration: 6
        )
    }

    @MainActor
    private func applyRemoteSeek(to seconds: Double) {
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        let cappedTarget = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        Self.logger.info(
            "[CMP-SEEK] remote seek requested seconds=\(seconds, privacy: .public) capped=\(cappedTarget, privacy: .public) duration=\(self.duration, privacy: .public)"
        )
        commitSeek(to: cappedTarget, source: "remoteCommand")
    }

    // MARK: - Notices

    /// Shows a transient notice, replacing any notice already up.
    @MainActor
    func showNotice(
        title: String,
        message: String,
        tone: PlayerNoticeTone,
        duration: TimeInterval
    ) {
        let notice = PlayerNotice(title: title, message: message, tone: tone)
        activeNotice = notice
        noticeDismissTask?.cancel()
        noticeDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.activeNotice?.id == notice.id else { return }
            self.activeNotice = nil
            self.noticeDismissTask = nil
        }
    }

    /// Asks the player screen to close, after `delay` seconds. A notice shown
    /// just before stays up until then; with no delay it goes at once.
    @MainActor
    private func requestRemoteDismiss(after delay: TimeInterval = 0) {
        noticeDismissTask?.cancel()
        remoteDismissTask?.cancel()
        remoteDismissTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.noticeDismissTask = nil
            if delay <= 0 {
                self.activeNotice = nil
            }
            self.remoteDismissToken = UUID()
            self.remoteDismissTask = nil
        }
    }
}
