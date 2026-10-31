import Foundation

/// A downloaded item ready for the player, with no network.
struct OfflinePreparedPlayback {
    let prepared: PreparedPlayback
    let downloadId: String
    /// The leaf id: the episode, else the item itself.
    let mediaItemId: String
    let posterFileURL: URL?
}

/// Builds the player's prepared playback from what is saved on the device.
enum OfflinePlaybackBuilder {
    enum LoadError: LocalizedError {
        case recordMissing
        case manifestMissing
        case mediaMissing

        var errorDescription: String? {
            switch self {
            case .recordMissing:
                String(localized: "This download is no longer on this device.")
            case .manifestMissing:
                String(localized: "The offline playback data for this download is missing. Delete and re-download it.")
            case .mediaMissing:
                String(localized: "The downloaded video file is missing. Delete and re-download it.")
            }
        }
    }

    /// Reads only the loaded scope's records and files. The offline launch
    /// path activates the scope first.
    @MainActor
    static func loadPreparedPlayback(downloadId: String, startFromBeginning: Bool, resumePositionOverride: Double?,
                                     preferredAudioTrackIndex: Int? = nil, viewingAudioLanguage: String? = nil,
                                     audioLanguage: String? = nil) async throws -> OfflinePreparedPlayback {
        let manager = DownloadManager.shared
        guard let record = manager.record(withId: downloadId), record.isPlayableOffline else { throw LoadError.recordMissing }
        guard let manifest = await manager.readManifest(for: record) else { throw LoadError.manifestMissing }
        guard let mediaURL = manager.mediaFileURL(for: record),
              FileManager.default.fileExists(atPath: mediaURL.path) else { throw LoadError.mediaMissing }
        let leafId = record.leafMediaItemId

        var resume: Double?
        if startFromBeginning {
            resume = 0
        } else {
            let candidates = [resumePositionOverride, manager.savedProgress(for: leafId)?.position]
            resume = candidates.compactMap { $0 }.first { $0.isFinite && $0 >= 0 }
        }
        if let position = resume, let duration = manifest.durationSeconds, duration.isFinite, duration > 0,
           position >= duration - 5 {
            // As streaming does: a finished item starts again.
            resume = 0
        }

        let savedSidecars = sidecars(for: manifest, savedFiles: record.subtitleFilenames) { name in
            manager.fileURL(named: name, forRecord: record.id)
        }
        let prepared = preparedPlayback(
            manifest: manifest, leafId: leafId, mediaURL: mediaURL, sidecars: savedSidecars, resumePosition: resume,
            preferredAudioTrackIndex: preferredAudioTrackIndex, viewingAudioLanguage: viewingAudioLanguage,
            audioLanguage: audioLanguage
        )
        return OfflinePreparedPlayback(
            prepared: prepared,
            downloadId: record.id,
            mediaItemId: leafId,
            posterFileURL: record.posterFilename.flatMap { manager.fileURL(named: $0, forRecord: record.id) }
        )
    }

    /// The player's bridge value for a saved manifest and media file.
    @MainActor
    static func preparedPlayback(manifest: OfflineManifest, leafId: String, mediaURL: URL, sidecars: [SubtitleUrl],
                                 resumePosition: Double?, preferredAudioTrackIndex: Int?, viewingAudioLanguage: String?,
                                 audioLanguage: String?) -> PreparedPlayback {
        // The server already merged the embedded and display titles, and the
        // engine assigns stream ids itself.
        let audioTracks = manifest.audioTracks?.map { entry in
            AudioTrack(index: nil, codec: entry.codec, channels: entry.channels, channelLayout: entry.layout,
                       bitrate: entry.bitrate, sampleRate: entry.sampleRate, language: entry.language,
                       title: entry.title, embeddedTitle: nil, isDefault: entry.isDefault)
        }
        // The engine probes the file for video, subtitle and chapter tracks.
        let version = FileVersion(
            fileId: manifest.mediaFileId, fileName: nil, resolution: manifest.resolution,
            codecVideo: manifest.codecVideo, codecAudio: manifest.codecAudio, hdr: manifest.hdr,
            container: manifest.container, fileSize: manifest.fileSize, duration: manifest.durationSeconds,
            bitrate: bitrateKbps(manifest), videoTracks: nil, audioTracks: audioTracks, subtitleTracks: nil,
            chapters: nil, intro: manifest.intro, credits: manifest.credits
        )
        let detail = WatchDetail(offlineLeafContentId: leafId, manifest: manifest, version: version)

        let audioIndex: Int?
        if let tracks = audioTracks, !tracks.isEmpty, let audioLanguage {
            // Streaming's rule: a manual pick, then this viewing's language,
            // then Settings. The server's choice at download time isn't used.
            let language = VividInitialAudioPreference.preferredLanguage(
                viewing: viewingAudioLanguage, settings: audioLanguage, tracks: tracks
            )
            audioIndex = VividInitialAudioPreference.selectedOrdinal(
                manual: preferredAudioTrackIndex, tracks: tracks, preferredLanguage: language
            )
        } else {
            audioIndex = manifest.selectedAudioTrackIndex
        }

        let session = PlaybackSessionResponse(
            sessionId: "offline-\(manifest.downloadId)", userId: nil, profileId: nil,
            mediaFileId: manifest.mediaFileId, playMethod: "direct", position: resumePosition ?? 0, isPaused: false,
            streamUrl: mediaURL.absoluteString, audioTrackIndex: audioIndex, durationSeconds: manifest.durationSeconds,
            timelineOffsetSeconds: 0, subtitleUrls: sidecars.isEmpty ? nil : sidecars, playbackInfo: nil
        )
        return PreparedPlayback(watchDetail: detail, selectedVersion: version, session: session)
    }

    /// The delivered file's bitrate in kbps, else the manifest's target. A
    /// duration under a second is a corrupt manifest.
    static func bitrateKbps(_ manifest: OfflineManifest) -> Int? {
        if let size = manifest.fileSize, size > 0, let duration = manifest.durationSeconds, duration >= 1 {
            let kbps = Double(size) * 8 / duration / 1000
            if kbps.isFinite, kbps >= 1, kbps < 2_147_483_647 { return Int(kbps) }
        }
        return manifest.targetBitrateKbps
    }

    /// Saved subtitle files as the player's local sidecars, in the manifest's
    /// order. Emby and Jellyfin keep their own stream index as the id, so it
    /// matches the online sidecar; Silo uses the list position.
    static func sidecars(for manifest: OfflineManifest, savedFiles: [String: String],
                         location: (String) -> URL?) -> [SubtitleUrl] {
        var claimed: Set<Int> = []
        var sidecars: [SubtitleUrl] = []
        for item in DownloadEngine.SubtitleFiles.savable(in: manifest) {
            let id = item.entry.index ?? item.position
            guard id >= 0, claimed.insert(id).inserted else { continue }
            guard let name = savedFiles[item.entry.fetchUrl], let url = location(name), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            sidecars.append(SubtitleUrl(
                index: id, language: item.entry.language, codec: item.ext,
                label: item.entry.title ?? String(localized: "External"), source: "external",
                forced: item.entry.forced, default: item.entry.isDefault, hearingImpaired: item.entry.hearingImpaired,
                url: url.absoluteString
            ))
        }
        return sidecars
    }
}

extension WatchDetail {
    /// The watch detail of a downloaded item, from its saved manifest.
    init(offlineLeafContentId: String, manifest: OfflineManifest, version: FileVersion) {
        contentId = offlineLeafContentId
        type = manifest.type
        title = manifest.title
        year = manifest.year
        overview = manifest.overview
        versions = [version]
        subtitles = nil
        intro = manifest.intro
        credits = manifest.credits
        userData = nil
        seriesId = manifest.seriesId
        seriesTitle = manifest.seriesTitle
        seasonNumber = manifest.seasonNumber
        episodeNumber = manifest.episodeNumber
        effectiveSubtitleLanguage = nil
        effectiveSubtitleMode = nil
        effectiveShowForcedSubtitles = nil
        effectiveSubtitleTrackSignature = nil
    }
}
