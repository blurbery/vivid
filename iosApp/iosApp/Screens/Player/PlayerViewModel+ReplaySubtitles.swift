import Foundation
import OSLog

/// The rules for replay subtitles: skipping back a little with subtitles
/// off shows them until playback is back where the skip started. Pure: no
/// I/O and no actor isolation.
enum ReplaySubtitles {
    /// A skip further back than this is navigation, not a missed line.
    static let maximumSkipBack: Double = 60
    /// A skip shorter than this has nothing to replay, such as one pressed
    /// at the very start of the item.
    static let minimumSkipBack: Double = 1
    /// How long the subtitles stay once playback is back where the skip
    /// started, so a line that was being spoken there isn't cut short.
    static let trailingSeconds: Double = 2

    /// One replay: the track shown, what to go back to, and where it ends.
    struct Session: Equatable {
        /// The track shown for the replay.
        let trackID: Int64
        /// The viewer's own selection, put back when the replay ends: a
        /// forced track, or nil for Off.
        let restoreTrackID: Int64?
        /// The furthest source time a skip of this replay started from.
        /// Repeat skips are measured against it.
        var originTime: Double
        /// The source time the replay ends after: `originTime`, kept short
        /// of the end of the item.
        var endTime: Double

        init(trackID: Int64, restoreTrackID: Int64?, originTime: Double? = nil, endTime: Double) {
            self.trackID = trackID
            self.restoreTrackID = restoreTrackID
            self.originTime = originTime ?? endTime
            self.endTime = endTime
        }
    }

    /// Whether a skip from `origin` back to `target` starts a replay.
    static func startsReplay(from origin: Double, to target: Double) -> Bool {
        guard origin.isFinite, target.isFinite else { return false }
        let distance = origin - target
        return distance >= minimumSkipBack && distance <= maximumSkipBack
    }

    /// Whether playback at `time` is past the replay.
    static func hasEnded(_ session: Session, at time: Double) -> Bool {
        time.isFinite && time >= session.endTime + trailingSeconds
    }

    /// Whether a replay may take over from the viewer's selection: Off, or a
    /// forced track, which shows foreign dialogue and signs only.
    static func canReplace(_ selected: PlayerTrack?) -> Bool {
        guard let selected else { return true }
        return SubtitleAutoResolver.isForced(selected)
    }

    /// The languages to look for, best first: the subtitle languages from
    /// Settings > Subtitles (or the device's caption settings), then the
    /// device's languages, then the language being spoken.
    static func languages(
        preferred: [String?],
        device: [String],
        audio: String?
    ) -> [String] {
        var result: [String] = []
        for language in preferred + device.map(Optional.some) + [audio] {
            guard let language = usableLanguage(language),
                  !result.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) else { continue }
            result.append(language)
        }
        return result
    }

    /// The full-dialogue track to show: the first language in `languages`
    /// that has one, then a track whose language isn't tagged, which a file
    /// with a single subtitle often leaves out. Never a forced track, and
    /// never a language the viewer didn't ask for.
    static func track(
        in candidates: [PlayerTrack],
        languages: [String],
        preferAccessibility: Bool
    ) -> PlayerTrack? {
        let fullDialogue = candidates.filter { !SubtitleAutoResolver.isForced($0) }
        guard !fullDialogue.isEmpty else { return nil }
        // One language at a time: the resolver ranks the kind of track above
        // the order of its languages, and here the order has to win.
        for language in languages {
            let pick = SubtitleAutoResolver.resolve(.init(
                preferredLanguage: language,
                mode: .always,
                showForced: false,
                preferAccessibilityTracks: preferAccessibility,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil,
                availableSubtitles: fullDialogue,
                currentAudioLanguage: nil
            ))
            if case .select(let track) = pick { return track }
        }
        return fullDialogue.first { usableLanguage($0.lang) == nil }
    }

    /// The trimmed language, or nil when it's blank or names no language.
    private static func usableLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !["und", "mis", "mul", "zxx"].contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }
}

/// Replay subtitles in the player.
///
/// The replay's track is selected like any other, so it draws, syncs and
/// styles as usual. It isn't the viewer's choice though: nothing here marks
/// a pick, and reloads, reports to the server and the next episode read
/// `viewerSubtitleId`, the selection without the replay.
extension PlayerViewModel {
    /// The viewer's own subtitle selection: `selectedSubtitleId`, or what it
    /// goes back to while a replay is showing its track.
    var viewerSubtitleId: Int64? {
        if let session = replaySubtitleSession, session.trackID == selectedSubtitleId {
            return session.restoreTrackID
        }
        return selectedSubtitleId
    }

    /// Whether `trackID` is the primary subtitle: the one showing, or the
    /// one a replay puts back when it ends. Neither can be the secondary.
    func isPrimarySubtitle(_ trackID: Int64) -> Bool {
        trackID == selectedSubtitleId || trackID == viewerSubtitleId
    }

    /// Called once a burst of skip presses has seeked. A net skip back
    /// starts a replay, or keeps the one that's showing.
    func replaySubtitlesAfterSkip(from origin: Double, to target: Double, seekReloadsPlayback: Bool) {
        guard target < origin else { return }
        if var session = replaySubtitleSession, session.trackID == selectedSubtitleId {
            if seekReloadsPlayback {
                // The reload starts from the viewer's own selection.
                endReplaySubtitles(restoringSelection: true, reason: "seek_reload")
                return
            }
            // Skipping back again keeps the subtitles up to the furthest
            // point playback had reached, within the same limit as one skip.
            let originTime = max(session.originTime, origin)
            guard settings.replaySubtitlesOnSkipBack,
                  ReplaySubtitles.startsReplay(from: originTime, to: target) else {
                endReplaySubtitles(restoringSelection: true, reason: "skip_limit")
                return
            }
            session.originTime = originTime
            session.endTime = replayEndTime(originTime)
            replaySubtitleSession = session
            return
        }
        replaySubtitleSession = nil
        guard settings.replaySubtitlesOnSkipBack,
              !seekReloadsPlayback,
              ReplaySubtitles.startsReplay(from: origin, to: target),
              let track = replaySubtitleTrackIfAllowed() else { return }

        Self.logger.info(
            "[CMP-SUB] replay subtitles start trackId=\(track.trackId, privacy: .public) origin=\(origin, privacy: .public) target=\(target, privacy: .public)"
        )
        // Off that the engine already shows is settled. Left pending, the
        // next track list would apply it again and end the replay.
        pendingSubtitleFfIndex = nil
        // The replay isn't a pick, so a Silo subtitle file remembered for
        // this title stays remembered.
        let rememberedPick = localExternalSubtitlePick
        replaySubtitleSession = ReplaySubtitles.Session(
            trackID: track.trackId, restoreTrackID: selectedSubtitleId,
            originTime: origin, endTime: replayEndTime(origin))
        selectedSubtitleId = track.trackId
        applySubtitleTrackSelection(track.trackId, reason: "replay_subtitles")
        localExternalSubtitlePick = rememberedPick
    }

    /// Where a replay from `origin` ends. Kept short of the end of the
    /// item, where no later time report would arrive to end it.
    private func replayEndTime(_ origin: Double) -> Double {
        duration > 0 ? min(origin, max(0, duration - ReplaySubtitles.trailingSeconds)) : origin
    }

    /// Ends the replay once playback is back past where the skip started.
    func updateReplaySubtitles(at time: Double) {
        guard let session = replaySubtitleSession else { return }
        // One started while a receiver stream was being prepared ends on
        // the first time report after the hand-off engages, so Lucid
        // doesn't take the title back with subtitles the viewer didn't
        // choose.
        if vividPlaybackController.isAirPlayHandOffEngaged {
            endReplaySubtitles(restoringSelection: true, reason: "airplay")
            return
        }
        guard ReplaySubtitles.hasEnded(session, at: time) else { return }
        endReplaySubtitles(restoringSelection: true, reason: "caught_up")
    }

    /// Ends the replay. With `restoringSelection` the viewer's own selection
    /// goes back, unless something else has changed the subtitle since.
    /// Without it the replay is only forgotten: a pick or a new load now
    /// owns the selection.
    func endReplaySubtitles(restoringSelection: Bool, reason: String) {
        guard let session = replaySubtitleSession else { return }
        replaySubtitleSession = nil
        guard restoringSelection, !isDisposed, selectedSubtitleId == session.trackID else { return }
        // A forced track that has since left the list goes back to Off.
        let restored = session.restoreTrackID.flatMap { id in
            subtitleTracks.contains { $0.trackId == id && isSelectableSubtitle($0) } ? id : nil
        }
        Self.logger.info(
            "[CMP-SUB] replay subtitles end reason=\(reason, privacy: .public) restored=\(restored.map(String.init) ?? "off", privacy: .public)"
        )
        selectedSubtitleId = restored
        applySubtitleTrackSelection(restored, reason: "replay_subtitles_end")
        // A second subtitle is only offered beside a main one.
        if restored == nil, selectedSecondarySubtitleId != nil {
            selectedSecondarySubtitleId = nil
            applySecondarySubtitleTrackSelection(nil)
        }
    }

    /// The track a replay would show now, or nil when it mustn't start:
    /// full subtitles are already on, the server draws the subtitles, a
    /// subtitle change is still waiting on the load, or the title has no
    /// full-dialogue track in a language the viewer reads.
    private func replaySubtitleTrackIfAllowed() -> PlayerTrack? {
        guard !isDisposed, !hasReachedEndOfFile, isVividLoadEstablished,
              // An AirPlay receiver only shows the server's subtitles.
              !vividPlaybackController.isAirPlayHandOffEngaged,
              // A subtitle the server draws in changes only with a reload.
              serverTranscodeSubtitles?.burnedIndex == nil,
              !isServerBurnInRow(selectedSubtitleId),
              pendingSidecarSubtitleTrackId == nil,
              pendingServerRenderedSubtitleTrackId == nil,
              // A Silo replan or quality change is about to replace the
              // stream, which starts again from the viewer's own selection.
              protocolV3ReplanTask == nil, !isQualitySwitching else { return nil }

        let engineSelection = vividPlaybackController.engine.activeSubtitleTrackIndex
        let selected: PlayerTrack?
        if let selectedSubtitleId {
            guard pendingSubtitleFfIndex == nil,
                  let track = subtitleTracks.first(where: { $0.trackId == selectedSubtitleId }) else { return nil }
            selected = track
        } else {
            // Off has to be what's showing, not a selection still on its way.
            guard engineSelection == nil, (pendingSubtitleFfIndex ?? -1) < 0 else { return nil }
            selected = nil
        }
        guard ReplaySubtitles.canReplace(selected) else { return nil }

        // Only a track the engine already holds can show straight away. A
        // Silo subtitle file that hasn't been fetched would arrive late, and
        // a burn-in row needs a reload. An OpenSubtitles file keeps its own
        // delay, which only applies while it's the viewer's pick.
        let candidates = subtitleTracks.filter { track in
            track.trackId != selectedSecondarySubtitleId
                && !isServerBurnInRow(track.trackId)
                && !openSubtitleIDs.contains(track.trackId)
                && vividPlaybackController.containsSubtitle(appTrackID: track.trackId)
                && isSelectableSubtitle(track)
        }
        let prefs = Self.settingsSubtitlePrefs(settings)
        let languages = ReplaySubtitles.languages(
            preferred: [prefs.preferredLanguage] + prefs.additionalPreferredLanguages.map(Optional.some)
                + prefs.fallbackLanguages.map(Optional.some),
            device: Locale.preferredLanguages,
            audio: audioTracks.first(where: { $0.trackId == selectedAudioId })?.lang
        )
        return ReplaySubtitles.track(
            in: candidates, languages: languages, preferAccessibility: prefs.preferAccessibilityTracks)
    }
}
