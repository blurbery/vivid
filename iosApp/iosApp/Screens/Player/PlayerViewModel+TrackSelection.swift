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
    // MARK: - Track selection
    //
    // Lucid Engine owns embedded subtitle selection.

    func selectAudio(_ track: PlayerTrack) {
        if activePreparedProtocolV3 != nil {
            // The server owns the switch on this path, so the track must not
            // be applied locally before its plan arrives. The selection is
            // published optimistically because the replan reads it back, but
            // nothing is kept or recorded until the replan is actually under
            // way — a dropped switch must not be filed as a success.
            let priorAudioId = selectedAudioId
            let priorPendingAudioFfIndex = pendingAudioFfIndex
            let priorAudioPicked = audioPickedForCurrentItem
            pendingAudioFfIndex = nil
            selectedAudioId = track.trackId
            audioPickedForCurrentItem = true
            reapplyAutomaticSubtitlePolicy()
            guard attemptProtocolV3Replan(
                position: currentTime,
                classification: "audio_track_changed",
                message: "User selected audio track \(track.title ?? String(track.trackId)).",
                requeueWhenBusy: true,
                trackTarget: queuedTrackTarget(forAudio: track)
            ) else {
                selectedAudioId = priorAudioId
                pendingAudioFfIndex = priorPendingAudioFfIndex
                audioPickedForCurrentItem = priorAudioPicked
                reapplyAutomaticSubtitlePolicy()
                showNotice(
                    title: "Couldn't change audio",
                    message: "The audio track couldn't be switched. Try again.",
                    tone: .warning,
                    duration: 5
                )
                scheduleHideControls()
                return
            }
            recordAudioTrackSelectionBreadcrumb(
                track.trackId,
                reason: "user_selection",
                viaServerReplan: true
            )
            scheduleHideControls()
            return
        }
        pendingAudioFfIndex = nil
        selectedAudioId = track.trackId
        audioPickedForCurrentItem = true
        reapplyAutomaticSubtitlePolicy()
        applyAudioTrackSelection(track.trackId, reason: "user_selection")
        scheduleHideControls()
    }

    #if os(iOS) || os(tvOS)
    static let openSubtitleTrackIDBase: Int64 = 9_000_000_000
    var openSubtitleIDs: Set<Int64> { Set(openSubtitleFiles.entries.keys) }
    func removeOpenSubtitleFiles(_ files: [URL]) {
        for url in files { try? FileManager.default.removeItem(at: url) }
    }
    var openSubtitleContext: OpenSubtitlePlaybackContext? {
        guard !isDisposed, !isAudioOnlyVividLoad, let detail = currentWatchDetail else { return nil }
        return OpenSubtitlePlaybackContext(contentID: detail.contentId, generation: streamLoadGeneration,
            query: OpenSubtitleQuery(title: detail.type == "episode" ? (detail.seriesTitle ?? detail.title) : detail.title,
                type: detail.type, season: detail.seasonNumber, episode: detail.episodeNumber))
    }
    func useOpenSubtitle(_ result: OpenSubtitleResult, data: Data, expected: OpenSubtitlePlaybackContext) throws {
        guard openSubtitleContext == expected else { throw OpenSubtitlesError.context }
        guard OpenSubtitlesClient.isSubtitle(data), let text = String(data: data, encoding: .utf8),
              !VividSubtitleLoader.parse(text).isEmpty else { throw OpenSubtitlesError.file }
        let id = Self.openSubtitleTrackIDBase + Int64(result.id)
        if openSubtitleIDs.contains(id), let track = subtitleTracks.first(where: { $0.trackId == id }), isSelectableSubtitle(track) {
            selectSubtitle(track)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vivid-opensubtitles-" + UUID().uuidString + ".srt")
        try data.write(to: url, options: .atomic)
        removeOpenSubtitleFiles(openSubtitleFiles.prepare(contentID: expected.contentID))
        let offset = OpenSubtitlesStore.shared.rememberedOffset(contentID: expected.contentID,
            fileID: currentSelectedVersion?.fileId, resultID: result.id)
        let replaced = openSubtitleFiles.register(.init(id: id, url: url, name: result.name,
            language: result.language, hearingImpaired: result.hearingImpaired, offsetMs: offset))
        if let replaced { removeOpenSubtitleFiles([replaced]) }
        vividPlaybackController.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: "OpenSubtitles · " + result.name,
            language: result.language, isHearingImpaired: result.hearingImpaired, formatHint: "srt"), appTrackID: id)
        adoptVividInventory()
        if let track = subtitleTracks.first(where: { $0.trackId == id }) { selectSubtitle(track) }
    }

    /// The OpenSubtitles file shown as the main subtitle, if one is.
    var selectedOpenSubtitle: OpenSubtitleSessionFiles.Entry? {
        guard let id = selectedSubtitleId, openSubtitleFiles.selectedID == id else { return nil }
        return openSubtitleFiles.entries[id]
    }

    /// Offsets are saved per file version, so a version switch for the same
    /// item reloads each kept file's offset (zero when none was saved).
    func refreshOpenSubtitleOffsets(contentID: String, fileID: Int?) {
        for entry in openSubtitleFiles.entries.values {
            openSubtitleFiles.setOffset(OpenSubtitlesStore.shared.rememberedOffset(contentID: contentID, fileID: fileID,
                resultID: Int(entry.id - Self.openSubtitleTrackIDBase)), for: entry.id)
        }
    }

    /// Changes the selected OpenSubtitles file's own offset. `save` also
    /// keeps it with the remembered file, once the change is committed.
    func setOpenSubtitleOffset(_ milliseconds: Int, save: Bool) {
        guard let entry = selectedOpenSubtitle else { return }
        let clamped = max(-10_000, min(milliseconds, 10_000))
        openSubtitleFiles.setOffset(clamped, for: entry.id)
        applySubtitleAppearanceToPlayer()
        guard save, let context = openSubtitleContext else { return }
        OpenSubtitlesStore.shared.rememberOffset(clamped, contentID: context.contentID,
            fileID: currentSelectedVersion?.fileId, resultID: Int(entry.id - Self.openSubtitleTrackIDBase))
    }

    /// Keeps the item's remembered OpenSubtitles file in step with the latest
    /// explicit choice, so resuming later restores it.
    private func rememberOpenSubtitleChoice(_ trackID: Int64?) {
        guard let context = openSubtitleContext else { return }
        let fileID = currentSelectedVersion?.fileId
        guard let trackID, let entry = openSubtitleFiles.entries[trackID] else {
            OpenSubtitlesStore.shared.forgetSelection(contentID: context.contentID, fileID: fileID)
            return
        }
        guard let data = try? Data(contentsOf: entry.url) else { return }
        let result = OpenSubtitleResult(id: Int(entry.id - Self.openSubtitleTrackIDBase), name: entry.name,
            language: entry.language, hearingImpaired: entry.hearingImpaired)
        OpenSubtitlesStore.shared.rememberSelection(result, data: data, contentID: context.contentID, fileID: fileID)
    }

    /// Restores the OpenSubtitles file chosen when this item last played.
    func restoreRememberedOpenSubtitle() {
        guard openSubtitleFiles.entries.isEmpty, let context = openSubtitleContext else { return }
        let fileID = currentSelectedVersion?.fileId
        guard let saved = OpenSubtitlesStore.shared.rememberedSelection(contentID: context.contentID, fileID: fileID) else { return }
        do { try useOpenSubtitle(saved.result, data: saved.data, expected: context) }
        catch { OpenSubtitlesStore.shared.forgetSelection(contentID: context.contentID, fileID: fileID) }
    }
    #endif

    /// Server subtitle files beside the media: mounted for Emby and Jellyfin,
    /// or offered for Silo and mounted when chosen.
    func isServerSidecarSubtitle(_ trackID: Int64) -> Bool {
        SubtitleTrackIdSpace.isSidecar(trackID)
            && (vividPlaybackController.containsSubtitle(appTrackID: trackID) || lazySubtitleSidecars[trackID] != nil)
    }

    private func isSelectableSubtitle(_ track: PlayerTrack) -> Bool {
        #if os(iOS) || os(tvOS)
        if track.isExternal {
            return (openSubtitleIDs.contains(track.trackId) && vividPlaybackController.containsSubtitle(appTrackID: track.trackId))
                || isServerSidecarSubtitle(track.trackId)
        }
        #endif
        return !track.isExternal && vividPlaybackController.containsSubtitle(appTrackID: track.trackId)
    }

    func selectSubtitle(_ track: PlayerTrack) {
        guard isSelectableSubtitle(track) else { return }
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
        if !track.isExternal || SubtitleTrackIdSpace.isSidecar(track.trackId) { persistSubtitleSelection(track) }
        applySubtitleTrackSelection(track.trackId, reason: "user_selection")
        scheduleHideControls()
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
        persistSubtitleSelection(nil)
        applySubtitleTrackSelection(nil, reason: "user_selection")
        scheduleHideControls()
    }

    /// Keeps an explicit subtitle pick (or "Off" when `track` is nil) for
    /// the rest of this viewing. Settings > Subtitles is left alone: one pick
    /// must not turn Auto into Always, or Off, for everything played later.
    private func persistSubtitleSelection(_ track: PlayerTrack?) {
        viewingSubtitlePrefs = Self.viewingSubtitlePrefs(for: track)
    }

    /// The pick as preferences the next episode can resolve against its own
    /// tracks: the same language and kind of track (forced, CC/SDH, title),
    /// or Off.
    static func viewingSubtitlePrefs(for track: PlayerTrack?) -> PrefsSnapshot {
        guard let track else {
            return PrefsSnapshot(
                preferredLanguage: nil, additionalPreferredLanguages: [], mode: .off,
                showForced: false, forcedOnly: false, preferAccessibilityTracks: false,
                disableWhenNoLanguageMatch: true, trackSignature: nil
            )
        }
        let language = track.normalizedLanguageCode
        let isForced = SubtitleAutoResolver.isForced(track)
        return PrefsSnapshot(
            preferredLanguage: language,
            additionalPreferredLanguages: [],
            mode: .always,
            showForced: isForced,
            // A forced pick stays forced: an episode without a forced track in
            // that language plays without subtitles rather than the full track.
            forcedOnly: isForced,
            preferAccessibilityTracks: track.isHearingImpaired,
            // A pick without a language still means "subtitles on".
            disableWhenNoLanguageMatch: language != nil,
            trackSignature: SubtitleTrackSignature(
                source: track.isExternal ? "external" : "embedded",
                language: language,
                codec: track.codec,
                label: track.normalizedTitle,
                forced: isForced,
                hearingImpaired: track.isHearingImpaired
            )
        )
    }

    /// What drives the automatic pick for the item being loaded: this
    /// viewing's player choice first, then Settings > Subtitles, or the
    /// device's caption settings when Vivid follows them.
    func automaticSubtitlePrefsSnapshot(_ watchDetail: WatchDetail? = nil) -> PrefsSnapshot {
        viewingSubtitlePrefs ?? Self.settingsSubtitlePrefs(settings)
    }

    /// Settings > Subtitles, or the device's caption settings when Vivid
    /// follows them. This is the only source of the automatic subtitle pick,
    /// on Silo, Emby and Jellyfin alike: the player resolves it against the
    /// tracks it plays and the detail pages against the catalogue's, so both
    /// show the same choice. No server-side subtitle setting takes part.
    static func settingsSubtitlePrefs(_ settings: PlayerSettings) -> PrefsSnapshot {
        settings.subtitleMatchesSystemAppearance
            ? systemCaptionPrefs(settings.subtitleSystemSelectionPreferences)
            : localSubtitlePrefs(settings)
    }

    func selectSecondarySubtitle(_ track: PlayerTrack) {
        guard backendCapabilities.supportsSecondarySubtitles else { return }
        guard !SubtitleCodecClassifier.isBitmap(track.codec) else { return }
        // Secondary sub cannot equal the primary sid; guard at the UI layer
        // so the user gets an immediate no-op rather than seeing stale state.
        guard track.trackId != selectedSubtitleId else { return }
        guard canRenderAsSecondarySubtitle(track) else { return }
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


    enum ProtocolV3SidecarRestoreIntent: Equatable {
        case renderLocally(Int64)
        case serverRendered(Int64)
    }

    static func protocolV3SidecarRestoreIntent(
        snapshot: Int64?,
        selectedSubtitleIndex: Int?,
        subtitleMode: String?,
        isEmbedded: Bool = false
    ) -> ProtocolV3SidecarRestoreIntent? {
        guard !isEmbedded else { return nil }
        guard let snapshot,
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

    static func isCurrentStreamCallback(
        _ callbackGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        callbackGeneration == currentGeneration
    }

    static func isUnexpectedBackwardPlaybackTime(
        _ candidate: Double,
        currentTime: Double,
        explicitSeekInFlight: Bool
    ) -> Bool {
        guard !explicitSeekInFlight,
              candidate.isFinite,
              currentTime.isFinite else {
            return false
        }
        return candidate + 0.75 < currentTime
    }

    struct ProtocolV3PendingTrackIntent: Equatable {
        let audioIndex: Int?
        let embeddedSubtitleIndex: Int?
        let sidecarSubtitleTrackId: Int64?
        let serverRenderedSubtitleTrackId: Int64?
    }

    static func protocolV3PendingTrackIntent(
        plan: PlaybackV3Plan,
        request: LoadRequest
    ) -> ProtocolV3PendingTrackIntent {
        let rendersSubtitleLocally = PlaybackProtocolV3.SubtitleMode.locallyRendered
            .contains(plan.subtitle.mode)
        return ProtocolV3PendingTrackIntent(
            audioIndex: request.preferredAudioTrackIndex,
            embeddedSubtitleIndex: rendersSubtitleLocally
                ? (plan.subtitle.embedded?.streamIndex ?? request.preferredSubtitleTrackIndex)
                : -1,
            sidecarSubtitleTrackId: rendersSubtitleLocally && plan.subtitle.embedded == nil
                ? request.preferredSidecarSubtitleTrackId
                : nil,
            serverRenderedSubtitleTrackId: plan.subtitle.mode == PlaybackProtocolV3.SubtitleMode.burnIn
                ? plan.selectedSubtitleCombinedIndex.map { SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0) }
                : nil
        )
    }

    func cycleAudioTrack() {
        guard !audioTracks.isEmpty else { return }
        let nextIndex: Int
        if let selectedAudioId,
           let currentIndex = audioTracks.firstIndex(where: { $0.trackId == selectedAudioId }) {
            nextIndex = audioTracks.index(after: currentIndex) % audioTracks.count
        } else {
            nextIndex = 0
        }
        selectAudio(audioTracks[nextIndex])
    }

    func cycleSubtitleTrack() {
        guard !subtitleTracks.isEmpty else { return }

        if selectedSubtitleId == nil {
            selectSubtitle(subtitleTracks[0])
            return
        }

        guard let selectedSubtitleId,
              let currentIndex = subtitleTracks.firstIndex(where: { $0.trackId == selectedSubtitleId }) else {
            disableSubtitles()
            return
        }

        let nextIndex = subtitleTracks.index(after: currentIndex)
        if nextIndex < subtitleTracks.count {
            selectSubtitle(subtitleTracks[nextIndex])
        } else {
            disableSubtitles()
        }
    }

    func toggleSubtitles() {
        if selectedSubtitleId != nil {
            disableSubtitles()
        } else if let first = subtitleTracks.first {
            selectSubtitle(first)
        }
    }

    func audioSelectionIndex(for track: PlayerTrack) -> Int? {
        track.srcId ?? track.ffIndex
    }

    /// Every audio-track change — user pick, resume of a persisted or
    /// detail-screen choice, post-route-switch restore — reaches the backend
    /// through here, so `reason` is required rather than defaulted: a report
    /// that cannot tell "the user chose this" from "we restored this" cannot
    /// answer the question these breadcrumbs exist for.
    func applyAudioTrackSelection(_ trackId: Int64, reason: String) {
        recordAudioTrackSelectionBreadcrumb(trackId, reason: reason, viaServerReplan: false)
        guard let id = Int(exactly: trackId) else { return }
        vividPlaybackController.selectAudioTrack(id: id)
    }

    /// Same contract as `applyAudioTrackSelection`: the one funnel every
    /// primary-subtitle change passes through, with an explicit `reason`.
    /// `nil` means subtitles off.
    func applySubtitleTrackSelection(_ trackId: Int64?, reason: String) {
        Self.logger.info(
            "[CMP-SUB] apply primary selection trackId=\(trackId.map(String.init) ?? "nil", privacy: .public) route=\(self.activeRouteLabel, privacy: .public)"
        )
        recordSubtitleTrackSelectionBreadcrumb(trackId, reason: reason, viaServerReplan: false)
        // A Silo external file is fetched only once it's actually chosen, and
        // remembered so replacement loads re-apply it. A reload's interim Off
        // (nil) leaves the pick alone; an explicit Off clears it.
        if let trackId {
            if let sidecar = lazySubtitleSidecars[trackId] {
                if !vividPlaybackController.containsSubtitle(appTrackID: trackId) {
                    vividPlaybackController.addExternalSubtitleTrack(sidecar, appTrackID: trackId)
                }
                localExternalSubtitlePick = currentWatchDetail.map { (trackId, $0.contentId, currentSelectedVersion?.fileId) }
            } else {
                localExternalSubtitlePick = nil
            }
        }
        vividPlaybackController.selectSubtitleTrack(id: trackId)
    }

    // MARK: - Track-selection breadcrumbs
    //
    // Split out of the two apply funnels because the funnels are not the only
    // way a track change happens: when a Protocol V3 plan is active the change
    // is executed by the *server* — the pick is sent up as a replan and comes
    // back as a new plan — so `selectAudio`/`selectSubtitle`/`disableSubtitles`
    // return before ever reaching an apply call. Without these helpers the only
    // trace of a server-side track change is the bridge's replan breadcrumb,
    // whose `reason` is the coarse classification (`audio_track_changed`) and
    // which knows nothing about the ordinal or the subtitle source.
    //
    // Both are strictly side-effect free — they read state and emit, nothing
    // else. That is the invariant that lets them be called on the replan path:
    // recording an intent must not apply it, because applying a track locally
    // before the server's replacement plan lands is exactly the desync these
    // breadcrumbs exist to diagnose.

    /// Records an audio pick. `viaServerReplan` distinguishes "the engine was
    /// told to switch" from "the pick was sent to the server and playback
    /// reloads" — a real difference in what the user sees (an instant switch
    /// versus a rebuffer), and one no registered key expresses, so it goes in
    /// the free-text message.
    private func recordAudioTrackSelectionBreadcrumb(
        _ trackId: Int64,
        reason: String,
        viaServerReplan: Bool
    ) {
        #if os(iOS) || os(tvOS)
        // The track's title and language are user-visible content metadata,
        // not diagnostics; the registry offers no key for them and they are
        // deliberately not smuggled into `msg`. The ordinal is enough to
        // correlate against the plan's selected_tracks.
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "Player",
            message: viaServerReplan
                ? "audio track selected, requesting server replan"
                : "audio track selected",
            attrs: [
                "reason": .string(reason),
                "sink": .string(
                    audioTracks.first(where: { $0.trackId == trackId })
                        .flatMap(audioSelectionIndex(for:))
                        .map { "audio_ordinal_\($0)" } ?? "audio_ordinal_unknown"
                ),
                "play_method": .string(activeRouteLabel),
            ]
        )
        #endif
    }

    /// Records a primary-subtitle pick, or an explicit "off" when `trackId` is
    /// nil. Same `viaServerReplan` contract as the audio helper.
    private func recordSubtitleTrackSelectionBreadcrumb(
        _ trackId: Int64?,
        reason: String,
        viaServerReplan: Bool
    ) {
        #if os(iOS) || os(tvOS)
        // Record the source kind without logging subtitle titles.
        let action = trackId == nil ? "subtitles disabled" : "subtitle track selected"
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "Player",
            message: viaServerReplan ? "\(action), requesting server replan" : action,
            attrs: [
                "reason": .string(reason),
                "sink": .string(trackId.map(Self.subtitleTrackKind) ?? "none"),
                "play_method": .string(activeRouteLabel),
            ]
        )
        #endif
    }

    /// Which subtitle source a track id names. The id space is the only
    /// classifier available at the funnel, and it is exactly the distinction
    /// worth recording.
    private static func subtitleTrackKind(_ trackId: Int64) -> String {
        if SubtitleTrackIdSpace.isSidecar(trackId) { return "sidecar" }
        return "embedded"
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
        // Only a track Vivid actually holds can be rendered as the secondary
        // one. Under V3 the plan mounts a single artifact, so an inventory row
        // that could not be registered above has no engine id at all — showing
        // it checked while nothing renders is worse than refusing the pick.
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



    /// Whether a picker row can actually be rendered as the secondary
    /// subtitle: it is either already mounted in Vivid or can be mounted from
    /// the plan inventory on demand.
    func canRenderAsSecondarySubtitle(_ track: PlayerTrack) -> Bool {
        !track.isExternal && vividPlaybackController.containsSubtitle(appTrackID: track.trackId)
    }

    func applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: Bool = false) {
        guard !hasExplicitSubtitleChoice, let prefs = prefsForCurrentItem else { return }
        if prefsResolvedForCurrentItem && !forceReevaluation {
            return
        }

        // Startup inventory can list subtitles before the engine has picked
        // an audio track, and before server subtitle files are mounted.
        // Resolving then sees no audio language, so Auto falls through to the
        // full track, and the latch below keeps that answer for the whole
        // item. Wait for the established load, as deferred picks do;
        // `loadVivid` re-enters `adoptVividInventory` once it is.
        guard isVividLoadEstablished else { return }

        let allSubs = subtitleTracks
        guard !allSubs.isEmpty else {
            prefsResolvedForCurrentItem = false
            return
        }

        let audioLang = SubtitleAutoResolver.policyAudioLanguage(
            live: audioTracks.first(where: { $0.trackId == selectedAudioId })?.lang,
            catalog: currentSelectedVersion?.audioTracks ?? [],
            ordinal: catalogAudioOrdinalForSubtitlePolicy
        )
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: prefs.preferredLanguage,
            additionalPreferredLanguages: prefs.additionalPreferredLanguages,
            mode: prefs.mode,
            showForced: prefs.showForced,
            forcedOnly: prefs.forcedOnly,
            preferAccessibilityTracks: prefs.preferAccessibilityTracks,
            disableWhenNoLanguageMatch: prefs.disableWhenNoLanguageMatch,
            trackSignature: prefs.trackSignature,
            fallbackLanguages: prefs.fallbackLanguages,
            availableSubtitles: allSubs,
            currentAudioLanguage: audioLang
        ))
        // An empty callback still has to clear a server-seeded automatic
        // selection in device-settings mode, but it must not latch the
        // resolver: embedded or sidecar tracks can arrive in a later update.
        prefsResolvedForCurrentItem = !allSubs.isEmpty
        applyAutoSubtitle(pick)
    }

    /// The catalogue ordinal of the audio that's playing. The engine's ordinal
    /// counts only when its list lines up with the catalogue's, since a
    /// transcode can carry fewer audio tracks than the file.
    private var catalogAudioOrdinalForSubtitlePolicy: Int? {
        if let selected = audioTracks.first(where: { $0.trackId == selectedAudioId }),
           audioTracks.count == (currentSelectedVersion?.audioTracks?.count ?? 0),
           let ordinal = audioSelectionIndex(for: selected) {
            return ordinal
        }
        // The plan and the load request describe the audio the item started
        // with, not a track the viewer has switched to since.
        guard !audioPickedForCurrentItem else { return nil }
        return activePreparedProtocolV3?.plan.selectedTracks.audio?.index
            ?? lastLoadRequest?.preferredAudioTrackIndex
    }

    /// Answer VividEngine's `systemCaptionRequest` (upstream api.md, "The
    /// system asks for captions").
    ///
    /// iOS 26's Automatic Subtitles turn captions on with no read API behind
    /// them, so the engine forwarding the ask is the only observable signal.
    /// Vivid has already deselected its own rendition by the time this lands —
    /// a fullscreen native caption box would draw over Vivid's overlay — so the
    /// host answers by selecting its own matching track. No match is a no-op:
    /// the contract is "select a matching track", not "turn something on".
    func handleSystemCaptionRequest(
        epoch: VividPlaybackController.LoadEpoch,
        request: SystemCaptionRequest
    ) {
        // Track lists and V3 plans are per-load; a request that crossed a
        // reload seam names a language against inventory that no longer exists.
        guard epoch == vividPlaybackController.activeLoadEpoch else { return }
        guard let language = request.language, !language.isEmpty else { return }
        guard !subtitleTracks.isEmpty else { return }

        // `.always` because the system already decided captions should be on;
        // `disableWhenNoLanguageMatch: false` keeps an unmatched language a
        // no-op rather than clearing a selection the user can see.
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: language,
            mode: .always,
            showForced: false,
            disableWhenNoLanguageMatch: false,
            trackSignature: nil,
            availableSubtitles: subtitleTracks,
            currentAudioLanguage: audioTracks
                .first(where: { $0.trackId == selectedAudioId })?
                .lang
        ))
        guard case .select(let track) = pick else { return }
        Self.logger.info(
            "[CMP-SUB] system caption request answered language=\(language, privacy: .public) trackId=\(track.trackId, privacy: .public)"
        )
        // Routed through the shared applier so a V3 session replans server-side
        // instead of drifting from `selected_tracks`.
        applyAutoSubtitle(.select(track))
    }

    /// Re-run the automatic pick for the current item. Auto's answer depends
    /// on the audio's language, so an audio switch needs this in every mode.
    /// A pick made for this item stays.
    func reapplyAutomaticSubtitlePolicy() {
        guard !hasExplicitSubtitleChoice else { return }
        prefsForCurrentItem = automaticSubtitlePrefsSnapshot()
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    func systemCaptionPrefsSnapshot() -> PrefsSnapshot {
        Self.systemCaptionPrefs(settings.subtitleSystemSelectionPreferences)
    }

    static func systemCaptionPrefs(_ system: SystemCaptionSelectionPreferences) -> PrefsSnapshot {
        let firstLanguage = system.preferredLanguages.first
        let remainingLanguages = Array(system.preferredLanguages.dropFirst())
        switch system.displayMode {
        case .forcedOnly:
            return PrefsSnapshot(
                preferredLanguage: firstLanguage,
                additionalPreferredLanguages: remainingLanguages,
                mode: .auto,
                showForced: true,
                forcedOnly: true,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil
            )
        case .automatic:
            return PrefsSnapshot(
                preferredLanguage: firstLanguage,
                additionalPreferredLanguages: remainingLanguages,
                mode: .auto,
                showForced: true,
                forcedOnly: false,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil
            )
        case .alwaysOn:
            // Always On prefers the full track, but a language whose only
            // track is forced still gets that track rather than nothing.
            return PrefsSnapshot(
                preferredLanguage: firstLanguage,
                additionalPreferredLanguages: remainingLanguages,
                mode: .always,
                showForced: true,
                forcedOnly: false,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil
            )
        }
    }

    func localSubtitlePrefsSnapshot(_ watchDetail: WatchDetail? = nil) -> PrefsSnapshot {
        Self.localSubtitlePrefs(settings)
    }

    static func localSubtitlePrefs(_ settings: PlayerSettings) -> PrefsSnapshot {
        let language = settings.preferredSubtitleLanguage == PlaybackPrefSentinel.none
            ? nil : settings.preferredSubtitleLanguage
        let backup = settings.preferredSubtitleBackupLanguage
        // A backup only stands in for a chosen language.
        let fallback = language != nil && !backup.isEmpty && backup != PlaybackPrefSentinel.none ? [backup] : []
        return PrefsSnapshot(
            preferredLanguage: language,
            additionalPreferredLanguages: [],
            mode: SubtitleMode(rawValue: settings.preferredSubtitleMode),
            showForced: settings.showForcedSubtitles,
            forcedOnly: false, preferAccessibilityTracks: false,
            disableWhenNoLanguageMatch: true, trackSignature: nil,
            fallbackLanguages: fallback
        )
    }

    /// Apply a resolver verdict. `noChange` is the "leave the player
    /// alone" case (no preference points anywhere); `disable` and
    /// `select` actually mutate state.
    private func applyAutoSubtitle(_ pick: SubtitleAutoSelection) {
        switch pick {
        case .noChange:
            return
        case .disable:
            localExternalSubtitlePick = nil
            if selectedSubtitleId != nil {
                selectedSubtitleId = nil
                applySubtitleTrackSelection(nil, reason: "auto_preference")
            }
        case .select(let track):
            if selectedSubtitleId != track.trackId {
                selectedSubtitleId = track.trackId
                applySubtitleTrackSelection(track.trackId, reason: "auto_preference")
            }
        }
    }
}
