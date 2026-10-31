import Foundation

// MARK: - Capability

/// What the server lets this profile download. Decoded from the server, from
/// the Emby and Jellyfin routers' dictionaries and from the saved scope file.
struct DownloadCapability: Codable, Hashable, Sendable {
    let enabled: Bool
    let downloadAllowed: Bool
    let qualityPresets: [String]
    let transcodeEnabled: Bool
    let transcodeUserAllowed: Bool
    let seasonDownload: Bool
    let seriesMonitoring: Bool
    let monitoringModes: [String]
    let bulkQuality: Bool
    let qualityOptions: [DownloadQualityOption]
    let versionTranscodes: Bool

    init(enabled: Bool, downloadAllowed: Bool, qualityPresets: [String], transcodeEnabled: Bool,
         transcodeUserAllowed: Bool, seasonDownload: Bool, seriesMonitoring: Bool, monitoringModes: [String],
         bulkQuality: Bool = false, qualityOptions: [DownloadQualityOption] = [], versionTranscodes: Bool = true) {
        self.enabled = enabled
        self.downloadAllowed = downloadAllowed
        self.qualityPresets = qualityPresets
        self.transcodeEnabled = transcodeEnabled
        self.transcodeUserAllowed = transcodeUserAllowed
        self.seasonDownload = seasonDownload
        self.seriesMonitoring = seriesMonitoring
        self.monitoringModes = monitoringModes
        self.bulkQuality = bulkQuality
        self.qualityOptions = qualityOptions
        self.versionTranscodes = versionTranscodes
    }

    /// A server with no downloads API: everything off.
    static let unsupported = DownloadCapability(
        enabled: false, downloadAllowed: false, qualityPresets: [], transcodeEnabled: false,
        transcodeUserAllowed: false, seasonDownload: false, seriesMonitoring: false, monitoringModes: []
    )

    var isUsable: Bool { enabled && downloadAllowed }
}

extension DownloadCapability {
    private enum CodingKeys: String, CodingKey {
        case enabled, downloadAllowed, qualityPresets, formats, transcodeEnabled, transcodeUserAllowed
        case seasonDownload, seriesMonitoring, monitoringModes, bulkQuality, qualityOptions, versionTranscodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        downloadAllowed = try container.decode(Bool.self, forKey: .downloadAllowed)
        // Older servers named the presets `formats`.
        qualityPresets = try container.decodeIfPresent([String].self, forKey: .qualityPresets)
            ?? container.decodeIfPresent([String].self, forKey: .formats)
            ?? [DownloadFormat.original.rawValue]
        transcodeEnabled = try container.decodeIfPresent(Bool.self, forKey: .transcodeEnabled) ?? false
        transcodeUserAllowed = try container.decodeIfPresent(Bool.self, forKey: .transcodeUserAllowed) ?? false
        seasonDownload = try container.decodeIfPresent(Bool.self, forKey: .seasonDownload) ?? false
        seriesMonitoring = try container.decodeIfPresent(Bool.self, forKey: .seriesMonitoring) ?? false
        monitoringModes = try container.decodeIfPresent([String].self, forKey: .monitoringModes) ?? []
        bulkQuality = try container.decodeIfPresent(Bool.self, forKey: .bulkQuality) ?? false
        // A malformed option list never costs the whole capability.
        qualityOptions = (try? container.decodeIfPresent([DownloadQualityOption].self, forKey: .qualityOptions)) ?? []
        // Jellyfin's router never sends it.
        versionTranscodes = try container.decodeIfPresent(Bool.self, forKey: .versionTranscodes) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(downloadAllowed, forKey: .downloadAllowed)
        try container.encode(qualityPresets, forKey: .qualityPresets)
        try container.encode(transcodeEnabled, forKey: .transcodeEnabled)
        try container.encode(transcodeUserAllowed, forKey: .transcodeUserAllowed)
        try container.encode(seasonDownload, forKey: .seasonDownload)
        try container.encode(seriesMonitoring, forKey: .seriesMonitoring)
        try container.encode(monitoringModes, forKey: .monitoringModes)
        try container.encode(bulkQuality, forKey: .bulkQuality)
        try container.encode(qualityOptions, forKey: .qualityOptions)
        try container.encode(versionTranscodes, forKey: .versionTranscodes)
    }
}

/// One quality the server can make, with the height it brings the file down to.
struct DownloadQualityOption: Codable, Hashable, Sendable {
    let preset: String
    let bitrateKbps: Int?
    let maxHeight: Int?
}

// MARK: - Quality presets

/// The download quality ladder. The order is the order every menu lists.
enum DownloadFormat: String, Codable, CaseIterable, Sendable {
    case original
    case twentyMbps = "20mbps"
    case tenMbps = "10mbps"
    case fiveMbps = "5mbps"
    case twoMbps = "2mbps"
    case oneMbps = "1mbps"

    var targetBitrateKbps: Int? {
        switch self {
        case .original: nil
        case .twentyMbps: 20_000
        case .tenMbps: 10_000
        case .fiveMbps: 5_000
        case .twoMbps: 2_000
        case .oneMbps: 1_000
        }
    }

    var displayName: String {
        guard let kbps = targetBitrateKbps else {
            return String(localized: "Original", comment: "Download quality: the original file, not converted")
        }
        return String(localized: "\(kbps / 1000) Mbps", comment: "Download quality bitrate, e.g. 20 Mbps")
    }

    /// The tallest picture each preset makes on Silo's ladder.
    var ladderMaxHeight: Int? {
        switch self {
        case .original: nil
        case .twentyMbps: 2160
        case .tenMbps, .fiveMbps: 1080
        case .twoMbps: 720
        case .oneMbps: 480
        }
    }

    /// "4K · 20 Mbps", or the display name alone for the original file or
    /// when no height is known.
    func qualityLabel(maxHeight: Int?) -> String {
        guard self != .original, let height = maxHeight ?? ladderMaxHeight else { return displayName }
        let resolution = height >= 2160 ? "4K" : "\(height)p"
        return resolution + DownloadEngine.dot + displayName
    }
}

// MARK: - Server rows

/// One download row as the server reports it.
struct ServerDownloadRow: Decodable, Hashable, Sendable {
    let id: String
    let contentId: String
    let episodeId: String?
    let batchId: String?
    let deviceId: String?
    let mediaFileId: Int
    let fileSize: Int64?
    let bytesSent: Int64?
    let kind: String?
    let status: String
    let quality: String
    let effectiveQuality: String?
    let deliveryFormat: String?
    let targetBitrateKbps: Int?
    let revision: Int?
    let createdAt: Date?
    let completedAt: Date?
    let preparation: DownloadPreparationStatus?
}

extension ServerDownloadRow {
    private enum CodingKeys: String, CodingKey {
        case id, contentId, episodeId, batchId, deviceId, mediaFileId, fileSize, bytesSent, kind, status
        case quality, format, effectiveQuality, deliveryFormat, targetBitrateKbps, revision, createdAt, completedAt
        case preparation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contentId = try container.decode(String.self, forKey: .contentId)
        episodeId = try container.decodeIfPresent(String.self, forKey: .episodeId)
        batchId = try container.decodeIfPresent(String.self, forKey: .batchId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        mediaFileId = try container.decodeIfPresent(Int.self, forKey: .mediaFileId) ?? 0
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        bytesSent = try container.decodeIfPresent(Int64.self, forKey: .bytesSent)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        status = try container.decode(String.self, forKey: .status)
        quality = try container.decodeIfPresent(String.self, forKey: .quality)
            ?? container.decodeIfPresent(String.self, forKey: .format)
            ?? DownloadFormat.original.rawValue
        effectiveQuality = try container.decodeIfPresent(String.self, forKey: .effectiveQuality)
        deliveryFormat = try container.decodeIfPresent(String.self, forKey: .deliveryFormat)
        targetBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .targetBitrateKbps)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        // A report the app can't read never costs the row.
        preparation = try? container.decodeIfPresent(DownloadPreparationStatus.self, forKey: .preparation)
    }
}

/// How far the server has got making a smaller or remuxed file.
struct DownloadPreparationStatus: Codable, Hashable, Sendable {
    let state: String
    let queuePosition: Int?
    let progress: Double?
    let remainingSeconds: Int?
}

extension DownloadPreparationStatus {
    var statusText: String {
        switch state {
        case "queued":
            guard let queuePosition, queuePosition > 0 else { return String(localized: "Waiting on server…") }
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            let place = formatter.string(from: NSNumber(value: queuePosition)) ?? String(queuePosition)
            return String(localized: "Waiting on server · \(place) in line",
                          comment: "Place in the server's download queue, e.g. Waiting on server · 2nd in line")
        case "retrying":
            return String(localized: "Retrying on server…")
        case "paused":
            return String(localized: "Paused on server")
        default:
            var parts: [String] = []
            if let progress, progress.isFinite {
                let percent = Int((min(max(progress, 0), 1) * 100).rounded(.down))
                parts.append(percent.formatted(.percent))
            }
            if let remainingSeconds, remainingSeconds >= 0 {
                parts.append(Self.timeLeft(remainingSeconds))
            }
            guard !parts.isEmpty else { return String(localized: "Preparing on server…") }
            return ([String(localized: "Preparing on server")] + parts).joined(separator: DownloadEngine.dot)
        }
    }

    private static func timeLeft(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 1 { return String(localized: "under 1 min left") }
        if minutes < 60 { return String(localized: "\(minutes) min left") }
        return String(localized: "\(minutes / 60) hr \(minutes % 60) min left")
    }
}

// MARK: - Device decode caps

/// What this device can play from a lasting file, sent with every
/// registration so the server prepares something it will play.
struct DownloadCaps: Encodable, Sendable {
    let clientFeatures: [String]
    let videoEvidence: String
    let codecsVideo: [String]
    let codecsAudio: [String]
    let audioPassthroughCodecs: [String]?
    let containers: [String]
    let maxResolution: String?
    let hdr: Bool
    let videoDecode: [PlaybackV3VideoDecodeCapability]

    /// Downloads outlive the current display route, so HDR is the device's
    /// decode ability rather than what the screen shows right now.
    static func current() -> DownloadCaps {
        let simulator = AppleDecodeCapabilities.isSimulator
        return DownloadCaps(
            clientFeatures: [PlaybackProtocolV3.softwareVideoDecodeFeature],
            videoEvidence: PlaybackProtocolV3.Evidence.platformAttested,
            codecsVideo: AppleDecodeCapabilities.hardwareVideoCodecs,
            codecsAudio: AppleDecodeCapabilities.audioCodecs,
            audioPassthroughCodecs: simulator ? [] : ["ac3", "eac3"],
            containers: AppleDecodeCapabilities.containers,
            maxResolution: "1080p",
            hdr: !simulator,
            videoDecode: AppleDecodeCapabilities.playbackV3VideoDecodeAttestation()
        )
    }
}

// MARK: - Offline manifest

/// Everything the app needs to play one download with no network. Comes from
/// the server, from the Emby and Jellyfin routers and from `manifest.json`.
struct OfflineManifest: Codable, Hashable, Sendable {
    struct Artwork: Codable, Hashable, Sendable {
        let poster: String?
        let backdrop: String?
        let logo: String?
    }

    struct AudioEntry: Codable, Hashable, Sendable {
        /// The position in this list, not a stream index.
        let index: Int?
        let title: String?
        let language: String?
        let codec: String?
        let layout: String?
        let channels: Int?
        let bitrate: Int?
        let sampleRate: Int?
        let isDefault: Bool?

        private enum CodingKeys: String, CodingKey {
            case index, title, language, codec, layout, channels, bitrate, sampleRate
            case isDefault = "default"
        }
    }

    struct SubtitleEntry: Codable, Hashable, Sendable {
        let language: String?
        let title: String?
        let index: Int?
        let isDefault: Bool?
        let format: String?
        let forced: Bool?
        let hearingImpaired: Bool?
        let external: Bool?
        let fetchUrl: String
        let fileSize: Int64?
    }

    struct StableIdentity: Codable, Hashable, Sendable {
        let stableType: String?
        let providerIds: [String: String]?
        let season: Int?
        let episode: Int?
    }

    struct Integrity: Codable, Hashable, Sendable {
        let expectedBytes: Int64?
        let mediaFileHash: String?
        let metadataEtag: String?
    }

    let downloadId: String
    let contentId: String
    let episodeId: String?
    let type: String
    let revision: Int?
    let quality: String
    let effectiveQuality: String?
    let deliveryFormat: String?
    let targetBitrateKbps: Int?
    let mediaFileId: Int
    let fileSize: Int64?
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let contentRating: String?
    let genres: [String]?
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let posterThumbhash: String?
    let backdropThumbhash: String?
    let artworkUrls: Artwork?
    let container: String?
    let codecVideo: String?
    let codecAudio: String?
    let resolution: String?
    let hdr: Bool?
    let durationSeconds: Double?
    let selectedAudioTrackIndex: Int?
    let audioTracks: [AudioEntry]?
    let chapters: [VersionChapter]?
    let intro: TimeRange?
    let credits: TimeRange?
    let recap: TimeRange?
    let preview: TimeRange?
    let subtitles: [SubtitleEntry]?
    let stableIdentity: StableIdentity?
    let integrity: Integrity?
    let manifestVersion: Int?
    let generatedAt: Date?
}

extension OfflineManifest {
    private enum CodingKeys: String, CodingKey {
        case downloadId, contentId, episodeId, type, revision, quality, format, effectiveQuality, deliveryFormat
        case targetBitrateKbps, mediaFileId, fileSize, title, year, overview, runtime, contentRating, genres
        case seriesId, seriesTitle, seasonNumber, episodeNumber, posterThumbhash, backdropThumbhash, artworkUrls
        case container, codecVideo, codecAudio, resolution, hdr, durationSeconds, selectedAudioTrackIndex
        case audioTracks, chapters, intro, credits, recap, preview, subtitles, stableIdentity, integrity
        case manifestVersion, generatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadId = try c.decode(String.self, forKey: .downloadId)
        contentId = try c.decode(String.self, forKey: .contentId)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
        type = try c.decode(String.self, forKey: .type)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        quality = try c.decodeIfPresent(String.self, forKey: .quality)
            ?? c.decodeIfPresent(String.self, forKey: .format)
            ?? DownloadFormat.original.rawValue
        effectiveQuality = try c.decodeIfPresent(String.self, forKey: .effectiveQuality)
        deliveryFormat = try c.decodeIfPresent(String.self, forKey: .deliveryFormat)
        targetBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .targetBitrateKbps)
        mediaFileId = try c.decodeIfPresent(Int.self, forKey: .mediaFileId) ?? 0
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime)
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        seriesTitle = try c.decodeIfPresent(String.self, forKey: .seriesTitle)
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        posterThumbhash = try c.decodeIfPresent(String.self, forKey: .posterThumbhash)
        backdropThumbhash = try c.decodeIfPresent(String.self, forKey: .backdropThumbhash)
        artworkUrls = try c.decodeIfPresent(Artwork.self, forKey: .artworkUrls)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        codecVideo = try c.decodeIfPresent(String.self, forKey: .codecVideo)
        codecAudio = try c.decodeIfPresent(String.self, forKey: .codecAudio)
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution)
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        selectedAudioTrackIndex = try c.decodeIfPresent(Int.self, forKey: .selectedAudioTrackIndex)
        audioTracks = try c.decodeIfPresent([AudioEntry].self, forKey: .audioTracks)
        chapters = try c.decodeIfPresent([VersionChapter].self, forKey: .chapters)
        intro = try c.decodeIfPresent(TimeRange.self, forKey: .intro)
        credits = try c.decodeIfPresent(TimeRange.self, forKey: .credits)
        recap = try c.decodeIfPresent(TimeRange.self, forKey: .recap)
        preview = try c.decodeIfPresent(TimeRange.self, forKey: .preview)
        subtitles = try c.decodeIfPresent([SubtitleEntry].self, forKey: .subtitles)
        stableIdentity = try c.decodeIfPresent(StableIdentity.self, forKey: .stableIdentity)
        integrity = try c.decodeIfPresent(Integrity.self, forKey: .integrity)
        manifestVersion = try c.decodeIfPresent(Int.self, forKey: .manifestVersion)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(downloadId, forKey: .downloadId)
        try c.encode(contentId, forKey: .contentId)
        try c.encodeIfPresent(episodeId, forKey: .episodeId)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encode(quality, forKey: .quality)
        try c.encodeIfPresent(effectiveQuality, forKey: .effectiveQuality)
        try c.encodeIfPresent(deliveryFormat, forKey: .deliveryFormat)
        try c.encodeIfPresent(targetBitrateKbps, forKey: .targetBitrateKbps)
        try c.encode(mediaFileId, forKey: .mediaFileId)
        try c.encodeIfPresent(fileSize, forKey: .fileSize)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(contentRating, forKey: .contentRating)
        try c.encodeIfPresent(genres, forKey: .genres)
        try c.encodeIfPresent(seriesId, forKey: .seriesId)
        try c.encodeIfPresent(seriesTitle, forKey: .seriesTitle)
        try c.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
        try c.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
        try c.encodeIfPresent(posterThumbhash, forKey: .posterThumbhash)
        try c.encodeIfPresent(backdropThumbhash, forKey: .backdropThumbhash)
        try c.encodeIfPresent(artworkUrls, forKey: .artworkUrls)
        try c.encodeIfPresent(container, forKey: .container)
        try c.encodeIfPresent(codecVideo, forKey: .codecVideo)
        try c.encodeIfPresent(codecAudio, forKey: .codecAudio)
        try c.encodeIfPresent(resolution, forKey: .resolution)
        try c.encodeIfPresent(hdr, forKey: .hdr)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(selectedAudioTrackIndex, forKey: .selectedAudioTrackIndex)
        try c.encodeIfPresent(audioTracks, forKey: .audioTracks)
        try c.encodeIfPresent(chapters, forKey: .chapters)
        try c.encodeIfPresent(intro, forKey: .intro)
        try c.encodeIfPresent(credits, forKey: .credits)
        try c.encodeIfPresent(recap, forKey: .recap)
        try c.encodeIfPresent(preview, forKey: .preview)
        try c.encodeIfPresent(subtitles, forKey: .subtitles)
        try c.encodeIfPresent(stableIdentity, forKey: .stableIdentity)
        try c.encodeIfPresent(integrity, forKey: .integrity)
        try c.encodeIfPresent(manifestVersion, forKey: .manifestVersion)
        try c.encodeIfPresent(generatedAt, forKey: .generatedAt)
    }
}

// MARK: - Progress sync

struct ProgressPullResponse: Codable, Sendable {
    let progress: [ProgressPullItem]
    let nextCursor: String?
}

struct ProgressPullItem: Codable, Sendable {
    let mediaItemId: String
    let positionSeconds: Double
    let durationSeconds: Double
    let completed: Bool
    let updatedAt: Date?
}

struct SyncProgressResultsResponse: Codable, Sendable {
    let results: [SyncProgressResult]
}

struct SyncProgressResult: Codable, Sendable {
    let mediaItemId: String
    let status: String
    let error: String?

    var isOK: Bool { status == "ok" }
}

// MARK: - Requests the endpoints take

/// The body of a registration. Every nil field is left out.
struct CreateDownloadRequest: Encodable, Sendable {
    let contentId: String
    let episodeId: String?
    let fileId: Int?
    let quality: String?
    let series: Bool?
    let seasonNumber: Int?
    let caps: DownloadCaps?
    let expectedRevision: Int?
    let expectedDownloadId: String?
    let batchId: String?
}

struct CreateSubscriptionRequest: Encodable, Sendable {
    let seriesId: String
    let mode: String
    let seasonNumbers: [Int]?
    let deleteWatched: Bool
    let maxStorageBytes: Int64
}

/// Only the given fields are sent.
struct UpdateSubscriptionRequest: Encodable, Sendable {
    let mode: String?
    let seasonNumbers: [Int]?
    let deleteWatched: Bool?
    let maxStorageBytes: Int64?
    let active: Bool?
}

struct CreateSubscriptionResponse: Decodable, Sendable {
    let subscription: DownloadEngine.ServerSubscription
    let registered: Int
}

extension DownloadEngine {
    /// A series monitoring subscription as the server reports it.
    struct ServerSubscription: Codable, Hashable, Sendable {
        let id: String
        let seriesId: String
        let mode: String
        let targetSeason: Int?
        let seasonNumbers: [Int]?
        let deleteWatched: Bool
        let maxStorageBytes: Int64
        let active: Bool
        let createdAt: Date?
        let updatedAt: Date?
    }

    /// A registration answers with `{"downloads": [...]}` or one bare row.
    struct CreatedRows: Decodable, Sendable {
        let rows: [ServerDownloadRow]

        private enum CodingKeys: String, CodingKey { case downloads }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let rows = try? container.decode([ServerDownloadRow].self, forKey: .downloads) {
                self.rows = rows
            } else {
                rows = [try ServerDownloadRow(from: decoder)]
            }
        }
    }

    struct RowList: Decodable, Sendable {
        let downloads: [ServerDownloadRow]
    }

    struct SubscriptionSync: Decodable, Sendable {
        let registered: Int
    }

    /// The body of a status report: `downloading` or `completed`.
    struct StatusUpdate: Encodable, Sendable {
        let status: String
        let revision: Int?
        let updatedAt: Date
    }
}
