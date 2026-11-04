import Foundation

/// Everything the player needs to open one playback: the item, the file the
/// server chose, the session it allocated and, for Silo, the Protocol V3 plan.
struct PreparedPlayback {
    let watchDetail: WatchDetail
    let selectedVersion: FileVersion
    let session: PlaybackSessionResponse
    let activeQualityId: String
    /// The bandwidth cap this playback was requested with. Loads that carry
    /// `activeQualityId` forward repeat it rather than working a cap out from
    /// the id again.
    let bandwidthCap: CarriedBandwidthCap
    let protocolV3: PreparedPlaybackV3?
    let nativeAudioStreamIndex: Int32?
    let nativeHLS: Bool
    /// Emby and Jellyfin transcodes only: bitmap subtitle burn-in.
    let transcodeSubtitles: ServerTranscodeSubtitles?
    let nativeQualityOptions: [ApplePlaybackQualityOption]?

    init(
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse,
        activeQualityId: String = ApplePlaybackQuality.autoId,
        bandwidthCap: CarriedBandwidthCap = .savedSetting,
        protocolV3: PreparedPlaybackV3? = nil,
        nativeAudioStreamIndex: Int32? = nil,
        nativeHLS: Bool = false,
        transcodeSubtitles: ServerTranscodeSubtitles? = nil,
        nativeQualityOptions: [ApplePlaybackQualityOption]? = nil
    ) {
        self.watchDetail = watchDetail
        self.selectedVersion = selectedVersion
        self.session = session
        self.activeQualityId = activeQualityId
        self.bandwidthCap = bandwidthCap
        self.protocolV3 = protocolV3
        self.nativeAudioStreamIndex = nativeAudioStreamIndex
        self.nativeHLS = nativeHLS
        self.transcodeSubtitles = transcodeSubtitles
        self.nativeQualityOptions = nativeQualityOptions
    }

    /// "Series • S2E3 • Episode" for an episode with a series title and a
    /// season or episode number, otherwise the item's own title.
    var displayTitle: String {
        if watchDetail.type == "episode" {
            let episodeTag = seasonAndEpisodeLabels.joined()
            if let seriesTitle = watchDetail.seriesTitle, !seriesTitle.isEmpty, !episodeTag.isEmpty {
                return "\(seriesTitle) • \(episodeTag) • \(watchDetail.title)"
            }
        }
        return watchDetail.title
    }

    /// The Apple TV overlay's hero strip, built from the `WatchDetail` and
    /// `FileVersion` already fetched, so it needs no other request.
    func playerMetadata() -> PlayerMetadata {
        let isEpisode = watchDetail.type == "episode"
        let episodeTag = isEpisode ? seasonAndEpisodeLabels.joined(separator: " · ") : ""

        var videoBadges: [String] = []
        if let resolution = selectedVersion.resolution, !resolution.isEmpty {
            videoBadges.append(PlayerMetadata.badgeLabel(forResolution: resolution))
        }
        if let dynamicRange = PlayerStreamBadges.dynamicRange(selectedVersion) {
            videoBadges.append(dynamicRange)
        }
        if let codec = selectedVersion.codecVideo?.uppercased(), !codec.isEmpty {
            videoBadges.append(codec)
        }
        let fileAudioCodec = selectedVersion.codecAudio?.uppercased()

        return PlayerMetadata(
            seriesTitle: isEpisode ? watchDetail.seriesTitle : nil,
            episodeTag: episodeTag.isEmpty ? nil : episodeTag,
            primaryTitle: watchDetail.title,
            year: isEpisode ? nil : watchDetail.year,
            overview: watchDetail.overview,
            videoBadges: videoBadges,
            fileAudioCodec: fileAudioCodec?.isEmpty == false ? fileAudioCodec : nil
        )
    }

    /// "S2" and "E3", leaving out whichever number the item lacks.
    private var seasonAndEpisodeLabels: [String] {
        [
            watchDetail.seasonNumber.map { String(localized: "S\(String($0))", comment: "Season number, abbreviated, for example S2") },
            watchDetail.episodeNumber.map { String(localized: "E\(String($0))", comment: "Episode number, abbreviated, for example E3") },
        ].compactMap { $0 }
    }
}

enum PlaybackProgressReportResult: Equatable {
    case success
    case deferred
    case missingSession
    case transientFailure
}

enum PlaybackProgressCommitPolicy {
    /// Completions count as confirmed once either the last progress write or
    /// the stop write reached the server.
    static func confirmedCompletedContentIds(
        _ candidates: Set<String>,
        initialResult: PlaybackProgressReportResult,
        stopResult: PlaybackProgressReportResult
    ) -> Set<String> {
        initialResult == .success || stopResult == .success ? candidates : []
    }
}

/// A playback start or replan the server (or this client) refused for good.
/// `reason` is the server's stable token; `message` is shown to the user.
struct PlaybackV3TerminalFailure: LocalizedError, Equatable {
    let reason: String
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}

/// The secondary details in the Apple TV player overlay's hero strip, filled
/// from `PreparedPlayback.playerMetadata()` when playback loads.
struct PlayerMetadata: Equatable {
    /// Episodes only: the series title, for example "Foundation".
    var seriesTitle: String?
    /// Episodes only: a compact tag such as "S2 · E3".
    var episodeTag: String?
    /// The episode's title, or for a movie the only title, shown as the hero.
    var primaryTitle: String
    /// Movies only: the release year.
    var year: Int?
    /// A short plot summary shown below the title.
    var overview: String?
    /// The selected file's video pills, in display order: resolution,
    /// dynamic range and video codec ("4K", "DV P8.1", "HEVC").
    var videoBadges: [String]
    /// The file's main audio codec as the server lists it ("TRUEHD"). Only
    /// shown until the engine reports which audio track is playing.
    var fileAudioCodec: String?

    static let empty = PlayerMetadata(
        seriesTitle: nil,
        episodeTag: nil,
        primaryTitle: "",
        year: nil,
        overview: nil,
        videoBadges: [],
        fileAudioCodec: nil
    )

    /// Every Stream pill: the video pills, then the codec of the audio track
    /// that's playing, so it follows an audio switch and matches the Audio
    /// row. Before the engine reports a selected track, the file's main audio
    /// codec stands in. A selected track without a codec shows no audio pill,
    /// like the Audio row.
    func streamBadges(playingAudio: PlayerTrack?) -> [String] {
        let audio = playingAudio == nil ? fileAudioCodec : PlayerStreamBadges.audioCodec(playingAudio)
        guard let audio else { return videoBadges }
        return videoBadges + [audio]
    }

    /// The short label for a raw resolution ("1920x1080", "1080p", "2160p"):
    /// "4K", "QHD", "FHD", "HD" or "SD", or the raw value in capitals.
    static func badgeLabel(forResolution raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("2160") || lower.contains("4k") { return "4K" }
        if lower.contains("1440") { return "QHD" }
        if lower.contains("1080") { return "FHD" }
        if lower.contains("720") { return "HD" }
        if lower.contains("480") { return "SD" }
        return raw.uppercased()
    }
}

enum PlaybackDeliveryStrategy {
    case direct
    case remux
    case transcode

    var name: String {
        switch self {
        case .direct: "direct"
        case .remux: "remux"
        case .transcode: "transcode"
        }
    }

    /// Direct play and remuxes keep the source file's video stream, so its
    /// HDR and frame rate metadata still apply.
    var preservesSourceVideoMetadata: Bool {
        switch self {
        case .direct, .remux: true
        case .transcode: false
        }
    }
}
