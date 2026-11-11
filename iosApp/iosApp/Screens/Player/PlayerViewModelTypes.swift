import Foundation

/// Chapters read from the media by Lucid Engine.
struct PlayerChapterInfo: Equatable, Identifiable, Sendable {
    let index: Int
    let title: String?
    let time: Double
    var id: Int { index }
}

/// Whether the credits setting should skip now.
///
/// Kept outside the player so every edge can be tested: the view model owns
/// the seek, and this decides whether the current time is the first eligible
/// visit to this session, file and marker.
enum CreditsAutoSkipPolicy {
    static func target(
        enabled: Bool,
        playbackEligible: Bool,
        time: Double,
        range: TimeRange?,
        markerKey: String?,
        lastSkippedKey: String?
    ) -> Double? {
        guard enabled,
              playbackEligible,
              time.isFinite,
              let range,
              range.start.isFinite,
              range.end.isFinite,
              range.start >= 0,
              range.end > range.start,
              let markerKey,
              markerKey != lastSkippedKey,
              time >= range.start,
              time < range.end else {
            return nil
        }
        return range.end
    }
}

/// The episode Next Up offers after the current one.
struct PlayerNextUpEpisode: Identifiable, Hashable {
    let contentId: String
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String
    let overview: String?
    let runtime: Int?
    let stillUrl: String?
    let stillThumbhash: String?
    let airDate: String?

    var id: String { contentId }
    var episodeLabel: String {
        String(localized: "S\(String(seasonNumber)):E\(String(episodeNumber))", comment: "Season and episode number, for example S1:E3")
    }

    init(episode: EpisodeListItem, seriesId: String?, seriesTitle: String?) {
        contentId = episode.contentId
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        seasonNumber = episode.seasonNumber
        episodeNumber = episode.episodeNumber
        let trimmedTitle = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            title = trimmedTitle
        } else {
            title = String(localized: "Episode \(String(episode.episodeNumber))", comment: "Fallback title for an untitled episode")
        }
        overview = episode.overview
        runtime = episode.runtime
        stillUrl = episode.stillUrl
        stillThumbhash = episode.stillThumbhash
        airDate = episode.airDate
    }
}

/// The logo and background of the series or movie being played, shown on
/// Next Up.
struct PlayerNextUpTitleArtwork: Hashable {
    /// The series for an episode, otherwise the movie itself.
    let titleId: String
    let title: String
    let logoUrl: String?
    let backdropUrl: String?
    let backdropThumbhash: String?
}

/// An item in the player's On Deck row.
struct PlayerOnDeckItem: Identifiable, Hashable {
    let sectionItem: SectionItem
    let contentId: String
    let title: String
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let positionSeconds: Double?
    let durationSeconds: Double?
    let artworkUrl: String?
    let artworkThumbhash: String?

    var id: String { contentId }

    var primaryTitle: String {
        if let seriesTitle, !seriesTitle.isEmpty {
            return seriesTitle
        }
        return title
    }

    init(
        item: SectionItem,
        artworkUrl preferredArtworkUrl: String? = nil,
        artworkThumbhash preferredArtworkThumbhash: String? = nil
    ) {
        sectionItem = item
        contentId = item.contentId
        title = item.title
        seriesTitle = item.seriesTitle
        seasonNumber = item.seasonNumber
        episodeNumber = item.episodeNumber
        positionSeconds = item.positionSeconds
        durationSeconds = item.durationSeconds
        artworkUrl = preferredArtworkUrl ?? item.backdropUrl
        artworkThumbhash = preferredArtworkThumbhash ?? item.backdropThumbhash
    }
}

/// What the player's controls may offer for the active load.
struct PlayerBackendCapabilities: Equatable {
    let supportsBufferedAhead: Bool
    let supportsSecondarySubtitles: Bool
    let supportsChapters: Bool
    let supportsVideoGravity: Bool
    let supportsSubtitleDelay: Bool
    let supportsSubtitleStyling: Bool

    static func vivid(
        subtitleOverlayControls: Bool,
        hasTextSubtitleTrack: Bool
    ) -> PlayerBackendCapabilities {
        PlayerBackendCapabilities(
            supportsBufferedAhead: true,
            supportsSecondarySubtitles: hasTextSubtitleTrack,
            supportsChapters: true,
            supportsVideoGravity: true,
            supportsSubtitleDelay: true,
            supportsSubtitleStyling: subtitleOverlayControls
        )
    }
}

/// Ends video playback at an app identity boundary: sign-out, a server or
/// profile switch, or a cleared session.
///
/// Those transitions replace the signed-in view tree, which removes the
/// player cover, and that path deliberately defers the player's `cleanup()`
/// while Picture in Picture is engaged. Nothing else ends an engaged video
/// session, so without this the previous identity's engine, its open server
/// session and a live PiP window would all carry on into the next identity.
///
/// Callable from the shared sign-in paths on every platform; it does nothing
/// where video Picture in Picture isn't hosted.
enum PlayerIdentityBoundary {
    static func endEngagedVideoPictureInPicture() {
        #if os(iOS)
        PictureInPictureCoordinator.endEngagedSessionForIdentityChange()
        #endif
    }
}

#if DEBUG
/// What the player asked the server, the engine and the offline store to do,
/// recorded for XCTest. Only a test installs one. While it's installed,
/// offline progress is recorded here instead of being written to the
/// download store, so tests never touch saved downloads.
@MainActor
final class PlayerTestRecorder {
    enum Entry: Equatable {
        /// An early end asked to reopen the same route. Whether the reopen
        /// started shows in what follows it.
        case sameRouteReopenRequest
        case serverReplan(classification: String)
        case terminalError(String)
        case postroll(videoEnded: Bool)
        case watchedMutation(contentId: String)
        case progressReport(position: Double, completedContentId: String?)
        case offlineProgress(position: Double, completed: Bool)
    }

    private(set) var entries: [Entry] = []

    func record(_ entry: Entry) {
        entries.append(entry)
    }
}
#endif

/// Marker ranges containing the playhead. Ranges are start-inclusive and
/// end-exclusive, matching the skip buttons and auto-skip checks.
struct PlayerSkipWindow: Equatable {
    var inRecap = false
    var inIntro = false
    var inCredits = false

    init() {}

    init(time: Double, recap: TimeRange?, intro: TimeRange?, credits: TimeRange?) {
        func contains(_ range: TimeRange?) -> Bool {
            guard let range else { return false }
            return time >= range.start && time < range.end
        }
        inRecap = contains(recap)
        inIntro = contains(intro)
        inCredits = contains(credits)
    }
}
