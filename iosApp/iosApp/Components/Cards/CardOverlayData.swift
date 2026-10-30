import Foundation

/// Technical and catalogue facts about a title, passed along with cards.
struct OverlayData: Hashable {
    var resolution: String?
    var hdr: String?
    var audio: String?
    var audioChannels: String?
    var videoCodec: String?
    var container: String?
    var aspectRatio: String?
    var releaseType: String?
    var edition: String?
    var multiAudio: Bool?
    var multiSub: Bool?
    var ratingImdb: Double?
    var ratingTmdb: Double?
    var ratingRtCritic: Int?
    var ratingRtAudience: Int?
    var contentRating: String?
    var year: Int?
    var runtime: Int?
    var originalLanguage: String?
    var studio: String?
    var network: String?
    var showStatus: String?

    init() {}

    static func from(_ item: BrowseItem) -> OverlayData {
        OverlayData(
            summary: item.overlaySummary,
            ratingImdb: item.ratingImdb,
            ratingTmdb: item.ratingTmdb,
            ratingRtCritic: item.ratingRtCritic,
            ratingRtAudience: item.ratingRtAudience,
            contentRating: item.contentRating,
            year: item.year,
            runtime: item.runtime,
            originalLanguage: item.originalLanguage,
            studios: item.studios,
            networks: item.networks,
            showStatus: item.showStatus
        )
    }

    static func from(_ item: SectionItem) -> OverlayData {
        OverlayData(
            summary: item.overlaySummary,
            ratingImdb: item.ratingImdb,
            ratingTmdb: item.ratingTmdb,
            ratingRtCritic: item.ratingRtCritic,
            ratingRtAudience: item.ratingRtAudience,
            contentRating: item.contentRating,
            year: item.year,
            runtime: item.runtime,
            originalLanguage: item.originalLanguage,
            studios: item.studios,
            networks: item.networks,
            showStatus: item.showStatus
        )
    }

    static func from(_ detail: ItemDetail) -> OverlayData {
        OverlayData(
            summary: detail.overlaySummary,
            ratingImdb: detail.ratingImdb,
            ratingTmdb: detail.ratingTmdb,
            ratingRtCritic: detail.ratingRtCritic,
            ratingRtAudience: detail.ratingRtAudience,
            contentRating: detail.contentRating,
            year: detail.year,
            runtime: detail.runtime,
            originalLanguage: detail.originalLanguage,
            studios: detail.studios,
            networks: detail.networks,
            showStatus: detail.showStatus
        )
    }

    private init(
        summary: OverlaySummary?,
        ratingImdb: Double?,
        ratingTmdb: Double?,
        ratingRtCritic: Int?,
        ratingRtAudience: Int?,
        contentRating: String?,
        year: Int?,
        runtime: Int?,
        originalLanguage: String?,
        studios: [String]?,
        networks: [String]?,
        showStatus: String?
    ) {
        if let summary {
            resolution = summary.resolution
            hdr = summary.hdr
            audio = summary.audio
            audioChannels = summary.audioChannels
            videoCodec = summary.videoCodec
            container = summary.container
            aspectRatio = summary.aspectRatio
            releaseType = summary.releaseType
            edition = summary.edition
            multiAudio = summary.multiAudio
            multiSub = summary.multiSub
        }
        self.ratingImdb = ratingImdb
        self.ratingTmdb = ratingTmdb
        self.ratingRtCritic = ratingRtCritic
        self.ratingRtAudience = ratingRtAudience
        self.contentRating = contentRating
        self.year = year
        self.runtime = runtime
        self.originalLanguage = originalLanguage
        studio = studios?.first { !$0.isEmpty }
        network = networks?.first { !$0.isEmpty }
        self.showStatus = showStatus
    }
}
