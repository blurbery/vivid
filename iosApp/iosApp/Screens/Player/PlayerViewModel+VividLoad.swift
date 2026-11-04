import Foundation
import OSLog

/// Opening a prepared session in Lucid Engine and publishing what it reports
/// back: its audio, subtitle and chapter inventory, and the track picks held
/// until the load is established.
extension PlayerViewModel {
    // MARK: Opening a source

    /// Opens `prepared` in the engine and waits for its startup to finish.
    ///
    /// Every load goes through here: fresh loads, replans and same-route
    /// reloads. It throws `CancellationError` when a newer load replaced this
    /// one, and the engine's failure otherwise. Once the load is established
    /// it mounts the session's subtitle files, publishes the inventory,
    /// restores subtitle picks, and re-applies volume, rate, gravity and
    /// subtitle style to the new engine.
    func loadVivid(
        prepared: PreparedPlayback,
        streamRequest: StreamRequest,
        expectedStreamLoadGeneration: UInt64,
        resumeSourcePosition: Double? = nil,
        shouldPlayWhenReady: Bool
    ) async throws {
        try requireCurrentStreamLoad(expectedStreamLoadGeneration)
        lazySubtitleSidecars = [:]
        lazySubtitleSidecarRequest = nil
        #if os(iOS) || os(tvOS)
        PlaybackSessionRecorder.shared.setPlayMethod(prepared.session.playMethod)
        removeOpenSubtitleFiles(openSubtitleFiles.prepare(contentID: prepared.watchDetail.contentId))
        // Files kept for the same item take the offset saved for this version.
        refreshOpenSubtitleOffsets(contentID: prepared.watchDetail.contentId, fileID: prepared.selectedVersion.fileId)
        #endif
        loadAudioOrdinal = prepared.session.audioTrackIndex
        if let seed = viewingAudioSeedOrdinal {
            viewingAudioSeedOrdinal = nil
            viewingAudioLanguage = Self.viewingAudioLanguage(
                stream: nil,
                catalog: prepared.selectedVersion.audioTracks ?? [],
                ordinal: seed
            )
        }
        let spec = try makeVividLoadSpec(
            prepared: prepared,
            streamRequest: streamRequest,
            resumeSourcePosition: resumeSourcePosition
        )

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
        let loadEpoch = vividPlaybackController.beginLoad(spec, shouldPlayWhenReady: shouldPlayWhenReady)
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
            if !(resolved is CancellationError), vividPlaybackController.activeLoadEpoch == loadEpoch {
                // The engine abandoned this load, not the app. Nothing else
                // tears the source down, and the caller is about to retire
                // its server session.
                disposeVividPlayback()
            }
            throw resolved
        }
        do {
            try requireCurrentStreamLoad(expectedStreamLoadGeneration)
            guard activeVividLoadEpoch == loadEpoch, vividPlaybackController.activeLoadEpoch == loadEpoch else {
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
        // Startup finished on this epoch, so the decode route is settled and
        // deferred track picks may drive the engine.
        establishedVividLoadEpoch = loadEpoch
        scrubPreviewProvider.activate(spec)
        #if os(iOS) || os(tvOS)
        mountSessionSubtitleFiles(prepared: prepared, streamRequest: streamRequest)
        #endif
        adoptVividInventory()
        #if os(iOS) || os(tvOS)
        restoreSubtitleChoicesAfterLoad(prepared: prepared)
        #endif
        restoreLocalExternalSubtitlePick(prepared: prepared)
        reapplyVividGain()
        // A new engine starts with Settings' style and the plain subtitle
        // delay. Re-apply the current ones, including an OpenSubtitles file's
        // own offset, which no view change would otherwise send after a reload.
        applySubtitleAppearanceToPlayer()

        if vividPlaybackController.shouldPlayWhenReady {
            vividPlaybackController.play()
        } else {
            vividPlaybackController.pause()
        }
    }

    /// The engine spec for a prepared session: a Silo plan, a download's
    /// local file, or an Emby or Jellyfin URL played directly.
    private func makeVividLoadSpec(
        prepared: PreparedPlayback,
        streamRequest: StreamRequest,
        resumeSourcePosition: Double?
    ) throws -> VividLoadSpec {
        let preferredSubtitles = subtitleOrderingLanguage.map { [$0] } ?? []
        let catalogAudio = prepared.selectedVersion.audioTracks ?? []
        let preferredAudio = VividInitialAudioPreference.languages(
            selectedOrdinal: prepared.protocolV3?.plan.selectedTracks.audio?.index,
            tracks: catalogAudio,
            fallbackLanguage: VividInitialAudioPreference.preferredLanguage(
                viewing: viewingAudioLanguage,
                settings: settings.audioLanguage,
                tracks: catalogAudio
            )
        )
        let forwardBufferSegments = settings.bufferAhead.forwardBufferSegments
        if let v3 = prepared.protocolV3 {
            return try VividLoadSpec(
                validating: v3.plan,
                sessionID: prepared.session.sessionId,
                matchContentEnabled: VividDisplayContext.matchContentEnabled,
                sourceURLOverride: streamRequest.url,
                requestHeaders: streamRequest.headers,
                // Subtitle artefacts, inventory sidecars and font bundles stay
                // relative API-origin routes even when the media moved to a
                // proxy, so this resolver never accepts absolute URLs.
                resolveURL: { raw in
                    StreamRequest.resolve(
                        rawURL: raw,
                        serverURL: streamRequest.serverUrl,
                        additionalHeaders: [:],
                        accessToken: nil,
                        requiresHeaderAuthenticatedMedia: true,
                        nativeApiMajor: v3.plan.nativeApiMajor
                    )?.url
                },
                apiOriginURL: URL(string: streamRequest.serverUrl),
                preferredAudioLanguages: preferredAudio,
                forwardBufferSegments: forwardBufferSegments,
                resumeSourcePosition: resumeSourcePosition
            )
        }
        if streamRequest.url.isFileURL {
            return try VividLoadSpec(
                offlineURL: streamRequest.url,
                startPosition: prepared.session.position,
                audioOnly: prepared.selectedVersion.codecVideo == nil,
                audioTrackOrdinal: prepared.session.audioTrackIndex,
                preferredAudioLanguages: preferredAudio,
                preferredSubtitleLanguages: preferredSubtitles,
                forwardBufferSegments: forwardBufferSegments
            )
        }
        return try VividLoadSpec(
            directURL: streamRequest.url,
            headers: streamRequest.headers,
            startPosition: prepared.session.position,
            audioOnly: prepared.selectedVersion.codecVideo == nil,
            nativeAudioStreamIndex: prepared.nativeAudioStreamIndex,
            nativeHLS: prepared.nativeHLS,
            // A provider with its own quality menu follows Match Content;
            // anything else always matches.
            matchContentEnabled: prepared.nativeQualityOptions == nil ? true : VividDisplayContext.matchContentEnabled,
            preferredAudioLanguages: preferredAudio,
            preferredSubtitleLanguages: preferredSubtitles,
            forwardBufferSegments: forwardBufferSegments
        )
    }

    #if os(iOS) || os(tvOS)
    /// Adds the session's subtitle files to the engine, or offers them as
    /// rows: Emby and Jellyfin files beside the media (and text streams while
    /// transcoding), a download's files, Silo's files and stored subtitles,
    /// and this item's OpenSubtitles files.
    private func mountSessionSubtitleFiles(prepared: PreparedPlayback, streamRequest: StreamRequest) {
        if MediaServerProvider.active.usesNativeUser, prepared.protocolV3 == nil, !streamRequest.url.isFileURL {
            for sidecar in prepared.session.subtitleUrls ?? [] {
                guard let url = URL(string: sidecar.url) else { continue }
                vividPlaybackController.addExternalSubtitleTrack(
                    Self.externalSubtitleTrack(sidecar, url: url, headers: streamRequest.headers),
                    appTrackID: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: sidecar.index)
                )
            }
        }
        // A download keeps its subtitle files beside the media. Only local
        // files inside the downloads folder are added, with no headers.
        if streamRequest.url.isFileURL {
            let downloads = DownloadFilePaths.rootDirectory().standardizedFileURL.path + "/"
            for sidecar in prepared.session.subtitleUrls ?? [] {
                guard let url = URL(string: sidecar.url), url.isFileURL,
                      url.standardizedFileURL.path.hasPrefix(downloads) else { continue }
                vividPlaybackController.addExternalSubtitleTrack(
                    Self.externalSubtitleTrack(sidecar, url: url, headers: nil),
                    appTrackID: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: sidecar.index)
                )
            }
        }
        // Silo's files are offered as rows and fetched only when chosen;
        // Silo is never told.
        if let v3 = prepared.protocolV3, !streamRequest.url.isFileURL {
            lazySubtitleSidecarRequest = streamRequest
            for item in v3.plan.subtitle.inventory {
                offerSiloSidecar(item, request: streamRequest, nativeApiMajor: v3.plan.nativeApiMajor)
            }
        }
        for entry in openSubtitleFiles.entries.values {
            vividPlaybackController.addExternalSubtitleTrack(
                ExternalSubtitleTrack(
                    url: entry.url, name: "OpenSubtitles · " + entry.name, language: entry.language,
                    isHearingImpaired: entry.hearingImpaired, formatHint: "srt"
                ),
                appTrackID: entry.id
            )
        }
    }

    private static func externalSubtitleTrack(
        _ sidecar: SubtitleUrl,
        url: URL,
        headers: [String: String]?
    ) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(
            url: url,
            name: sidecar.label ?? String(localized: "External"),
            language: sidecar.language,
            isForced: sidecar.forced ?? false,
            isHearingImpaired: sidecar.hearingImpaired ?? false,
            isDefault: sidecar.default ?? false,
            httpHeaders: headers,
            formatHint: sidecar.codec
        )
    }

    /// Applies, in order: an OpenSubtitles file downloaded on the detail page,
    /// a remembered OpenSubtitles file, the selected OpenSubtitles file, and a
    /// subtitle choice made on the detail page.
    private func restoreSubtitleChoicesAfterLoad(prepared: PreparedPlayback) {
        if let context = openSubtitleContext,
           let pending = OpenSubtitlesStore.shared.takeStaged(contentID: context.contentID, fileID: currentSelectedVersion?.fileId) {
            do {
                try useOpenSubtitle(pending.result, data: pending.data, expected: context)
            } catch {
                showNotice(
                    title: String(localized: "Subtitles"),
                    message: String(localized: "Unable to load the downloaded subtitle"),
                    tone: .warning,
                    duration: 5
                )
            }
        }
        restoreRememberedOpenSubtitle()
        if let id = openSubtitleFiles.selectedID, let track = subtitleTracks.first(where: { $0.trackId == id }) {
            selectSubtitle(track)
        }
        guard let context = openSubtitleContext,
              let choice = LucidSubtitleInventory.shared.takeChoice(
                  contentID: context.contentID, fileID: currentSelectedVersion?.fileId
              ) else { return }
        if let storedID = choice.storedSubtitleID {
            // A subtitle Silo stores is found by its row, not its position.
            if let id = ServerSubtitleSidecars.sidecarTrackID(storedSubtitleID: storedID, in: lazySubtitleSidecars),
               let track = subtitleTracks.first(where: { $0.trackId == id }) {
                selectSubtitle(track)
            }
        } else if let id = choice.trackID, let track = subtitleTracks.first(where: {
            $0.trackId == id && (!$0.isExternal || (isServerSidecarSubtitle($0.trackId)
                && ServerSubtitleSidecars.siloOrdinalAgrees(
                    id, plan: prepared.protocolV3?.plan, catalog: currentSelectedVersion?.subtitleTracks
                )))
        }) {
            selectSubtitle(track)
        } else if choice.trackID == nil {
            disableSubtitles()
        }
    }
    #endif

    /// Re-applies a Silo subtitle file picked on this device when the reload
    /// is of the same file, or forgets it otherwise. A stored subtitle can sit
    /// at another index in the new plan, so it's found by its stored ID.
    private func restoreLocalExternalSubtitlePick(prepared: PreparedPlayback) {
        guard let pick = localExternalSubtitlePick else { return }
        var trackID: Int64? = pick.trackID
        if let storedID = pick.storedID {
            trackID = ServerSubtitleSidecars.sidecarTrackID(storedSubtitleID: storedID, in: lazySubtitleSidecars)
        }
        if pick.contentID == prepared.watchDetail.contentId, pick.fileID == currentSelectedVersion?.fileId,
           let trackID, lazySubtitleSidecars[trackID] != nil {
            selectedSubtitleId = trackID
            applySubtitleTrackSelection(trackID, reason: "restored_local_external")
        } else {
            localExternalSubtitlePick = nil
        }
    }

    private func reapplyVividGain() {
        vividPlaybackController.setVolume(userVolume)
        vividPlaybackController.setMuted(userMuted)
        vividPlaybackController.setRate(Float(settings.playbackSpeed))
        vividPlaybackController.engine.videoGravity = settings.videoGravity.avGravity
    }

    // MARK: Silo subtitle files

    /// Offers a Silo inventory item the player fetches itself (a text file
    /// beside the media, or a text subtitle Silo stores) as a subtitle row.
    /// Any other item, or one at an index already offered, is left alone.
    @discardableResult
    func offerSiloSidecar(_ item: PlaybackV3SubtitleInventoryItem, request: StreamRequest, nativeApiMajor: Int?) -> Bool {
        let trackID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: item.combinedIndex)
        guard ServerSubtitleSidecars.isSiloLocalSidecar(item), item.combinedIndex >= 0,
              lazySubtitleSidecars[trackID] == nil,
              let raw = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = StreamRequest.resolve(
                  rawURL: raw, serverURL: request.serverUrl,
                  additionalHeaders: [:], accessToken: nil, requiresHeaderAuthenticatedMedia: true,
                  nativeApiMajor: nativeApiMajor
              )?.url else { return false }
        let apiOrigin = URL(string: request.serverUrl)
        lazySubtitleSidecars[trackID] = ExternalSubtitleTrack(
            url: url,
            name: item.label ?? String(localized: "External"),
            language: item.language,
            isForced: item.forced,
            isHearingImpaired: item.hearingImpaired,
            isDefault: item.default,
            httpHeaders: VividLoadSpec.subtitleRequestHeaders(
                request.headers, resourceURL: url, trustedOriginURLs: [apiOrigin].compactMap { $0 }
            ),
            formatHint: url.pathExtension.lowercased()
        )
        return true
    }

    /// Picker rows for Silo subtitle files not fetched yet, in combined index
    /// order: files beside the media, then stored subtitles. They follow the
    /// engine's own tracks in the list Auto reads.
    static func siloSidecarRows(_ sidecars: [Int64: ExternalSubtitleTrack]) -> [PlayerTrack] {
        sidecars.sorted { $0.key < $1.key }.map { id, sidecar in
            PlayerTrack(
                trackId: id, kind: .sub, title: sidecar.name, lang: sidecar.language, codec: nil,
                audioChannelCount: nil, bitrate: nil, isDefault: sidecar.isDefault, isForced: sidecar.isForced,
                isHearingImpaired: sidecar.isHearingImpaired, isExternal: true, isSelected: false,
                ffIndex: nil, srcId: SubtitleTrackIdSpace.sidecarIndex(from: id)
            )
        }
    }

    // MARK: Load state

    /// Whether the engine may be driven off a deferred (not user-initiated)
    /// track pick for the active load.
    var isVividLoadEstablished: Bool {
        activeVividLoadEpoch != nil && establishedVividLoadEpoch == activeVividLoadEpoch
    }

    /// Tells "the app abandoned this load" from "the engine abandoned it".
    ///
    /// The engine's load unwinds as a cancellation whenever a newer engine
    /// generation replaces it, including one the engine started itself, as an
    /// audio track switch's pipeline rebuild does. Treating that as the app's
    /// own abort left the player on an endless spinner: no plan failure was
    /// reported and no replan ran. When nothing on the app side asked the
    /// load to stop, the cancellation is a failure, so the Silo route ladder
    /// (and its server transcode) gets to run.
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
        return VividPlaybackController.LoadFailure(failure: failure, underlying: error)
    }

    /// Throws `CancellationError` once the task is cancelled, the player is
    /// gone or a newer load or replan moved the stream generation on.
    func requireCurrentStreamLoad(_ expectedGeneration: UInt64) throws {
        guard !Task.isCancelled, !isDisposed, expectedGeneration == streamLoadGeneration else {
            throw CancellationError()
        }
    }

    /// The source position a session starts at, on the movie timeline.
    func movieTime(for session: PlaybackSessionResponse) -> Double {
        let playerTime = session.position.isFinite ? session.position : 0
        let offset = session.timelineOffsetSeconds.isFinite ? session.timelineOffsetSeconds : 0
        return max(0, playerTime + offset)
    }

    // MARK: Inventory

    /// Publishes the engine's audio, subtitle and chapter lists and its
    /// selection, then applies the picks held for this load. Runs on every
    /// inventory change and once more when the load is established.
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
        // External tracks the engine holds are listed only when they're ours:
        // an OpenSubtitles file or a server file in the sidecar ID space.
        let vividSubtitleTracks = engine.subtitleTracks.filter { track in
            #if os(iOS) || os(tvOS)
            let appTrackID = vividPlaybackController.appSubtitleID(forVividID: track.id)
            return !track.isExternal || openSubtitleIDs.contains(appTrackID) || SubtitleTrackIdSpace.isSidecar(appTrackID)
            #endif
        }.map { track in
            if !track.isExternal {
                return LucidSubtitleInventory.playerTrack(track, selectedID: engine.activeSubtitleTrackIndex)
            }
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
                srcId: track.isExternal ? SubtitleTrackIdSpace.sidecarIndex(from: appTrackID) : nil
            )
        }
        let lazySidecarRows = Self.siloSidecarRows(lazySubtitleSidecars.filter {
            !vividPlaybackController.containsSubtitle(appTrackID: $0.key)
        })
        let publishedSubtitleTracks = vividSubtitleTracks + lazySidecarRows
        // Bitmap tracks an Emby or Jellyfin transcode can draw in come last,
        // so a text track in the same language wins an automatic pick.
        subtitleTracks = publishedSubtitleTracks + refreshServerBurnInRows()
        if engine.isSessionReady, let context = openSubtitleContext {
            LucidSubtitleInventory.shared.record(
                contentID: context.contentID,
                fileID: currentSelectedVersion?.fileId,
                tracks: publishedSubtitleTracks
            )
        }
        chapters = engine.mediaChapters.map { chapter in
            PlayerChapterInfo(index: chapter.id, title: chapter.name, time: chapter.startSeconds)
        }

        selectedAudioId = audioTracks.first(where: \.isSelected)?.trackId
            ?? engine.activeAudioTrackIndex.map(Int64.init)
        selectedSubtitleId = engine.activeSubtitleTrackIndex.map {
            vividPlaybackController.appSubtitleID(forVividID: $0)
        }

        // The inventory arrives mid-startup, so a deferred pick applied now
        // would reach the engine before its decode route exists. It's held
        // until the load is established; `loadVivid` calls this again then.
        let loadIsEstablished = isVividLoadEstablished
        reassertServerBurnedInSubtitle(loadIsEstablished: loadIsEstablished)
        applyPendingAudioPick(from: vividAudioTracks, loadIsEstablished: loadIsEstablished)
        applyPendingSubtitlePick(
            from: vividSubtitleTracks,
            published: publishedSubtitleTracks,
            loadIsEstablished: loadIsEstablished
        )

        // Reassert even when the engine publishes the same synthetic ID: a
        // Silo replan can change the file behind a reused ID, and the current
        // plan's URL, not ID equality, decides.
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

    /// Applies the held audio pick once the engine lists a matching track.
    /// Catalogue fallback rows are picker state for server replans; only a
    /// track the engine actually published may drive its selection.
    private func applyPendingAudioPick(from vividAudioTracks: [PlayerTrack], loadIsEstablished: Bool) {
        guard let wantedIndex = pendingAudioFfIndex,
              let match = vividAudioTracks.first(where: { audioSelectionIndex(for: $0) == wantedIndex }) else {
            return
        }
        switch DeferredTrackSelectionGate.outcome(
            isLoadEstablished: loadIsEstablished,
            engineAlreadyMatches: vividPlaybackController.engine.activeAudioTrackIndex.map(Int64.init) == match.trackId
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

    /// Applies the held subtitle pick: Off (a negative index), an embedded
    /// stream by its FFmpeg index, or for Emby and Jellyfin a server file by
    /// its stream index.
    private func applyPendingSubtitlePick(
        from vividSubtitleTracks: [PlayerTrack],
        published publishedSubtitleTracks: [PlayerTrack],
        loadIsEstablished: Bool
    ) {
        guard let wantedIndex = pendingSubtitleFfIndex else { return }
        let engine = vividPlaybackController.engine
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
            // The engine selects an embedded stream by its own ID, but under a
            // Silo plan the published row for it lives in the plan's sidecar
            // ID space. Publishing the engine ID would leave the picker with
            // nothing ticked and no combined index for the next replan.
            let publishedTrackID = publishedSubtitleTracks.first { $0.ffIndex == wantedIndex }?.trackId
                ?? match.trackId
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
        } else if activePreparedProtocolV3 == nil, let sidecar = vividSubtitleTracks.first(where: {
            $0.isExternal && SubtitleTrackIdSpace.isSidecar($0.trackId) && $0.srcId == wantedIndex
        }) {
            // An Emby or Jellyfin stream index can name a server subtitle file
            // rather than a container stream.
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
}
