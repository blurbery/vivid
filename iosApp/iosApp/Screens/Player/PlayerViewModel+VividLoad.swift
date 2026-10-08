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
    func loadVivid(
        prepared: PreparedPlayback,
        streamRequest: StreamRequest,
        expectedStreamLoadGeneration: UInt64,
        resumeSourcePosition: Double? = nil,
        shouldPlayWhenReady: Bool
    ) async throws {
        try requireCurrentStreamLoad(expectedStreamLoadGeneration)
        #if os(iOS) || os(tvOS)
        removeOpenSubtitleFiles(openSubtitleFiles.prepare(contentID: prepared.watchDetail.contentId))
        #endif
        let preferredSubtitles = subtitleOrderingLanguage.map { [$0] } ?? []
        let preferredAudio = VividInitialAudioPreference.languages(
            selectedOrdinal: prepared.protocolV3?.plan.selectedTracks.audio?.index,
            tracks: prepared.selectedVersion.audioTracks ?? [],
            fallbackLanguage: settings.audioLanguage
        )
        let forwardBufferSegments = settings.bufferAhead.forwardBufferSegments
        let spec: VividLoadSpec
        if let v3 = prepared.protocolV3 {
            spec = try VividLoadSpec(
                validating: v3.plan,
                sessionID: prepared.session.sessionId,
                matchContentEnabled: VividDisplayContext.matchContentEnabled,
                sourceURLOverride: streamRequest.url,
                requestHeaders: streamRequest.headers,
                // Subtitle artifacts, inventory sidecars and font bundles stay
                // relative API-origin routes even when the media itself moved
                // to a proxy, so this resolver never accepts absolute URLs.
                resolveURL: { raw in
                    StreamRequest.resolve(
                        rawURL: raw,
                        serverURL: streamRequest.serverUrl,
                        additionalHeaders: [:],
                        accessToken: nil,
                        requiresHeaderAuthenticatedMedia: true,
                        nativeApiMajor: prepared.protocolV3?.plan.nativeApiMajor
                    )?.url
                },
                apiOriginURL: URL(string: streamRequest.serverUrl),
                preferredAudioLanguages: preferredAudio,
                forwardBufferSegments: forwardBufferSegments,

                resumeSourcePosition: resumeSourcePosition
            )
        } else if streamRequest.url.isFileURL {
            spec = try VividLoadSpec(
                offlineURL: streamRequest.url,
                startPosition: prepared.session.position,
                audioOnly: prepared.selectedVersion.codecVideo == nil,
                audioTrackOrdinal: prepared.session.audioTrackIndex,
                preferredAudioLanguages: preferredAudio,
                preferredSubtitleLanguages: preferredSubtitles,
                forwardBufferSegments: forwardBufferSegments
        )
        } else {
            spec = try VividLoadSpec(
                directURL: streamRequest.url,
                headers: streamRequest.headers,
                startPosition: prepared.session.position,
                audioOnly: prepared.selectedVersion.codecVideo == nil,
                nativeAudioStreamIndex: prepared.nativeAudioStreamIndex,
                nativeHLS: prepared.nativeHLS,
                matchContentEnabled: prepared.nativeQualityOptions == nil ? true : VividDisplayContext.matchContentEnabled,
                preferredAudioLanguages: preferredAudio,
                preferredSubtitleLanguages: preferredSubtitles,
                forwardBufferSegments: forwardBufferSegments
        )
        }

        try requireCurrentStreamLoad(expectedStreamLoadGeneration)
        isLoading = true
        isBuffering = false
        isLoadingSubtitles = false
        bufferingProgress = nil
        scrubPreviewProvider.endSession()
        #if os(tvOS)
        vividPlaybackController.engine.preferLosslessAudio = settings.preferLosslessAudio
        #endif
        vividPlaybackController.engine.transientRecoveryBudget = transientRecoveryBudget
        let loadEpoch = vividPlaybackController.beginLoad(
            spec,
            shouldPlayWhenReady: shouldPlayWhenReady
        )
        vividPlaybackController.engine.refreshSourceHeaders = { @MainActor [weak self] in
            await self?.refreshDirectSourceHeaders(epoch: loadEpoch, generation: expectedStreamLoadGeneration)
        }
        activeVividLoadEpoch = loadEpoch
        establishedVividLoadEpoch = nil
        lastVividAudioTrackSwitchFailure = nil
        committedProtocolV3LoadEpoch = nil
        pendingProtocolV3FirstFrameEpoch = nil
        do {
            try await vividPlaybackController.finishLoad(loadEpoch)
        } catch {
            let resolved = resolveAbandonedVividLoad(
                error,
                epoch: loadEpoch,
                expectedStreamLoadGeneration: expectedStreamLoadGeneration
            )
            if activeVividLoadEpoch == loadEpoch {
                activeVividLoadEpoch = nil
                establishedVividLoadEpoch = nil
                committedProtocolV3LoadEpoch = nil
                pendingProtocolV3FirstFrameEpoch = nil
            }
            if !(resolved is CancellationError),
               vividPlaybackController.activeLoadEpoch == loadEpoch {
                // The engine, not the app, abandoned this load. Nobody else
                // will tear the source down, and the load's own catch is about
                // to retire its server session.
                disposeVividPlayback()
            }
            throw resolved
        }
        do {
            try requireCurrentStreamLoad(expectedStreamLoadGeneration)
            guard activeVividLoadEpoch == loadEpoch,
                  vividPlaybackController.activeLoadEpoch == loadEpoch else {
                throw CancellationError()
            }
            if let embedded = prepared.protocolV3?.plan.subtitle.embedded {
                try vividPlaybackController.validateEmbeddedSubtitleSelection(embedded.streamIndex)
            }
        } catch {
            if vividPlaybackController.activeLoadEpoch == loadEpoch {
                disposeVividPlayback()
            }
            throw error
        }
        // Startup ran to completion on this epoch, so the decode route is now
        // settled and deferred track picks may drive the engine.
        establishedVividLoadEpoch = loadEpoch
        scrubPreviewProvider.activate(spec)
        #if os(iOS) || os(tvOS)
        // Emby and Jellyfin list subtitle files stored beside the media (and,
        // when transcoding, text streams) separately from the container.
        if MediaServerProvider.active.usesNativeUser, prepared.protocolV3 == nil, !streamRequest.url.isFileURL {
            for sidecar in prepared.session.subtitleUrls ?? [] {
                guard let url = URL(string: sidecar.url) else { continue }
                vividPlaybackController.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url,
                    name: sidecar.label ?? "External", language: sidecar.language,
                    isForced: sidecar.forced ?? false, isHearingImpaired: sidecar.hearingImpaired ?? false,
                    isDefault: sidecar.default ?? false, httpHeaders: streamRequest.headers,
                    formatHint: sidecar.codec), appTrackID: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: sidecar.index))
            }
        }
        for entry in openSubtitleFiles.entries.values {
            vividPlaybackController.addExternalSubtitleTrack(ExternalSubtitleTrack(url: entry.url,
                name: "OpenSubtitles · " + entry.name, language: entry.language,
                isHearingImpaired: entry.hearingImpaired, formatHint: "srt"), appTrackID: entry.id)
        }
        #endif
        adoptVividInventory()
        #if os(iOS) || os(tvOS)
        if let context = openSubtitleContext,
           let pending = OpenSubtitlesStore.shared.takeStaged(contentID: context.contentID, fileID: currentSelectedVersion?.fileId) {
            do { try useOpenSubtitle(pending.result, data: pending.data, expected: context) }
            catch { showNotice(title: "Subtitles", message: "Unable to load the downloaded subtitle", tone: .warning, duration: 5) }
        }
        restoreRememberedOpenSubtitle()
        if let id = openSubtitleFiles.selectedID, let track = subtitleTracks.first(where: { $0.trackId == id }) {
            selectSubtitle(track)
        }
        if let context = openSubtitleContext,
           let choice = LucidSubtitleInventory.shared.takeChoice(contentID: context.contentID, fileID: currentSelectedVersion?.fileId) {
            if let id = choice.trackID, let track = subtitleTracks.first(where: { !$0.isExternal && $0.trackId == id }) {
                selectSubtitle(track)
            } else if choice.trackID == nil { disableSubtitles() }
        }
        #endif
        reapplyVividGain()

        if vividPlaybackController.shouldPlayWhenReady {
            vividPlaybackController.play()
        } else {
            vividPlaybackController.pause()
        }
    }

    /// Whether the engine may be driven off a deferred (not user-initiated)
    /// track pick for the load that is currently active.
    var isVividLoadEstablished: Bool {
        activeVividLoadEpoch != nil && establishedVividLoadEpoch == activeVividLoadEpoch
    }

    /// Distinguishes "the app abandoned this load" from "the engine abandoned
    /// it under us".
    ///
    /// `VividEngine.load` unwinds as a cancellation whenever a newer engine
    /// generation supersedes it — including when the *engine itself* started
    /// that newer generation, as an audio-track switch's pipeline rebuild does.
    /// Treating that as an app-side abort is what leaves the player on an
    /// endless spinner: the load task returns silently, no plan failure is
    /// reported and no replan runs. If nothing on the app side asked for this
    /// load to stop, the cancellation is a failure and has to be surfaced as
    /// one so the V3 route ladder (and its server-transcode fallback) runs.
    func resolveAbandonedVividLoad(
        _ error: Error,
        epoch: VividPlaybackController.LoadEpoch,
        expectedStreamLoadGeneration: UInt64
    ) -> Error {
        guard error is CancellationError,
              !Task.isCancelled,
              !isDisposed,
              expectedStreamLoadGeneration == streamLoadGeneration,
              activeVividLoadEpoch == epoch else {
            return error
        }
        let failure = lastVividAudioTrackSwitchFailure
            ?? vividPlaybackController.engine.errorInfo
            ?? PlaybackErrorInfo(
                kind: .audioTrackSwitchFailed,
                message: "Playback could not be set up with the selected audio track."
            )
        Self.logger.error(
            "Vivid abandoned an in-flight load (kind=\(failure.kind.rawValue, privacy: .public)); treating as a load failure"
        )
        return VividPlaybackController.LoadFailure(
            failure: failure,
            underlying: error
        )
    }

    func requireCurrentStreamLoad(_ expectedGeneration: UInt64) throws {
        guard !Task.isCancelled,
              !isDisposed,
              expectedGeneration == streamLoadGeneration else {
            throw CancellationError()
        }
    }

    @MainActor
    func adoptVividInventory() {
        let engine = vividPlaybackController.engine
        let vividAudioTracks = engine.audioTracks.enumerated().map { ordinal, track in
            PlayerTrack(
                trackId: Int64(track.id),
                kind: .audio,
                title: track.name,
                lang: track.language,
                codec: track.codec,
                audioChannelCount: track.channels > 0 ? track.channels : nil,
                bitrate: track.bitrate > 0 ? track.bitrate : nil,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isExternal: track.isExternal,
                isSelected: engine.activeAudioTrackIndex == track.id,
                ffIndex: track.sourceStreamIndex ?? track.id,
                srcId: ordinal
            )
        }
        audioTracks = ApplePlaybackV3PlanAdapter.audioPickerTracks(
            vividTracks: vividAudioTracks,
            plan: activePreparedProtocolV3?.plan,
            version: currentSelectedVersion
        )
        let vividSubtitleTracks = engine.subtitleTracks.filter { track in
            #if os(iOS) || os(tvOS)
            let appTrackID = vividPlaybackController.appSubtitleID(forVividID: track.id)
            return !track.isExternal || openSubtitleIDs.contains(appTrackID) || SubtitleTrackIdSpace.isSidecar(appTrackID)
            #else
            return !track.isExternal
            #endif
        }.map { track in
            if !track.isExternal { return LucidSubtitleInventory.playerTrack(track, selectedID: engine.activeSubtitleTrackIndex) }
            let appTrackID = vividPlaybackController.appSubtitleID(forVividID: track.id)
            return PlayerTrack(
                trackId: appTrackID,
                kind: .sub,
                title: track.name,
                lang: track.language,
                codec: track.codec,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isExternal: track.isExternal,
                isSelected: engine.activeSubtitleTrackIndex == track.id,
                ffIndex: track.isExternal ? nil : (track.sourceStreamIndex ?? track.id),
                srcId: track.isExternal
                    ? SubtitleTrackIdSpace.sidecarIndex(from: appTrackID)
                    : nil
            )
        }
        let publishedSubtitleTracks = vividSubtitleTracks
        subtitleTracks = publishedSubtitleTracks
        if engine.isSessionReady, let context = openSubtitleContext {
            LucidSubtitleInventory.shared.record(contentID: context.contentID,
                fileID: currentSelectedVersion?.fileId, tracks: publishedSubtitleTracks)
        }
        let mediaChapters = engine.mediaChapters.map { chapter in
            PlayerChapterInfo(
                index: chapter.id,
                title: chapter.name,
                time: chapter.startSeconds
            )
        }
        chapters = mediaChapters

        selectedAudioId = audioTracks.first(where: \.isSelected)?.trackId
            ?? engine.activeAudioTrackIndex.map(Int64.init)
        selectedSubtitleId = engine.activeSubtitleTrackIndex.map {
            vividPlaybackController.appSubtitleID(forVividID: $0)
        }

        // Inventory arrives mid-startup, so a deferred pick applied here would
        // reach the engine before its decode route exists. Hold it until the
        // load is established; `loadVivid` re-enters this method at that point.
        let loadIsEstablished = isVividLoadEstablished

        // Catalog fallback rows are picker state for server-owned replans; only
        // a track Vivid actually published may drive its local selection API.
        if let wantedIndex = pendingAudioFfIndex,
           let match = vividAudioTracks.first(where: {
               audioSelectionIndex(for: $0) == wantedIndex
           }) {
            switch DeferredTrackSelectionGate.outcome(
                isLoadEstablished: loadIsEstablished,
                engineAlreadyMatches: engine.activeAudioTrackIndex.map(Int64.init) == match.trackId
            ) {
            case .deferUntilEstablished:
                break
            case .adoptWithoutEngineCall:
                pendingAudioFfIndex = nil
                selectedAudioId = match.trackId
            case .applyToEngine:
                pendingAudioFfIndex = nil
                selectedAudioId = match.trackId
                applyAudioTrackSelection(match.trackId, reason: "pending_audio_index")
            }
        }

        if let wantedIndex = pendingSubtitleFfIndex {
            if wantedIndex < 0 {
                switch DeferredTrackSelectionGate.outcome(
                    isLoadEstablished: loadIsEstablished,
                    engineAlreadyMatches: engine.activeSubtitleTrackIndex == nil
                ) {
                case .deferUntilEstablished:
                    break
                case .adoptWithoutEngineCall:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = nil
                case .applyToEngine:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = nil
                    applySubtitleTrackSelection(nil, reason: "pending_subtitle_off")
                }
            } else if let match = vividSubtitleTracks.first(where: { $0.ffIndex == wantedIndex }) {
                // The engine still selects an embedded stream by its raw id,
                // but under V3 the *published* row for that stream lives in
                // the plan's sidecar id space. Publishing the engine id would
                // leave the picker showing nothing selected and resolve to no
                // combined ordinal on the next replan.
                let publishedTrackID = publishedSubtitleTracks
                    .first { $0.ffIndex == wantedIndex }?
                    .trackId ?? match.trackId
                switch DeferredTrackSelectionGate.outcome(
                    isLoadEstablished: loadIsEstablished,
                    engineAlreadyMatches: engine.activeSubtitleTrackIndex == wantedIndex
                ) {
                case .deferUntilEstablished:
                    break
                case .adoptWithoutEngineCall:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = publishedTrackID
                case .applyToEngine:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = publishedTrackID
                    applySubtitleTrackSelection(match.trackId, reason: "pending_subtitle_index")
                }
            } else if let sidecar = vividSubtitleTracks.first(where: {
                $0.isExternal && SubtitleTrackIdSpace.isSidecar($0.trackId) && $0.srcId == wantedIndex
            }) {
                // An Emby or Jellyfin stream index can name a server subtitle
                // file rather than a container stream.
                switch DeferredTrackSelectionGate.outcome(
                    isLoadEstablished: loadIsEstablished,
                    engineAlreadyMatches: selectedSubtitleId == sidecar.trackId
                ) {
                case .deferUntilEstablished:
                    break
                case .adoptWithoutEngineCall:
                    pendingSubtitleFfIndex = nil
                case .applyToEngine:
                    pendingSubtitleFfIndex = nil
                    selectedSubtitleId = sidecar.trackId
                    applySubtitleTrackSelection(sidecar.trackId, reason: "pending_subtitle_sidecar")
                }
            }
        }

        // Reassert even when Vivid publishes the same synthetic id: V3 changed
        // the resource behind that reused id, and the current plan's artifact
        // URL — not id equality — is authoritative.
        if let pendingTrackID = pendingSidecarSubtitleTrackId,
           loadIsEstablished,
           subtitleTracks.contains(where: { $0.trackId == pendingTrackID }) {
            pendingSidecarSubtitleTrackId = nil
            selectedSubtitleId = pendingTrackID
            applySubtitleTrackSelection(pendingTrackID, reason: "restored_sidecar_selection")
        }
        if let pendingTrackID = pendingServerRenderedSubtitleTrackId,
           subtitleTracks.contains(where: { $0.trackId == pendingTrackID }) {
            pendingServerRenderedSubtitleTrackId = nil
            selectedSubtitleId = pendingTrackID
        }
        applyAutoSubtitlePreferencesIfNeeded()
    }

    @MainActor
    private func reapplyVividGain() {
        vividPlaybackController.setVolume(userVolume)
        vividPlaybackController.setMuted(userMuted)
        vividPlaybackController.setRate(Float(settings.playbackSpeed))
        vividPlaybackController.engine.videoGravity = settings.videoGravity.avGravity
    }

    func applyUserVolume(_ volume: Float) {
        userVolume = min(max(volume, 0), 1)
        if userVolume > 0 { userMuted = false }
        vividPlaybackController.setMuted(userMuted)
        vividPlaybackController.setVolume(userVolume)
    }

    func applyUserMuted(_ muted: Bool) {
        userMuted = muted
        vividPlaybackController.setMuted(muted)
    }

    func movieTime(for session: PlaybackSessionResponse) -> Double {
        let playerTime = session.position.isFinite ? session.position : 0
        let offset = session.timelineOffsetSeconds.isFinite ? session.timelineOffsetSeconds : 0
        return max(0, playerTime + offset)
    }
}
