import Foundation

/// One thing the Top Shelf can show: a film or episode the viewer has
/// started, or the episode they'd watch next. Foundation only, so the native
/// client and these models can be checked without an Apple TV.
struct ShelfEntry: Equatable, Sendable {
    enum Kind: String, Sendable { case movie, episode, other }

    /// The item to open and play.
    let id: String
    let kind: Kind
    let title: String
    let seriesID: String?
    let seriesTitle: String?
    let season: Int?
    let episode: Int?
    /// From 0 to 1, or nil when the server gave no position or no length.
    let progress: Double?
    var poster: URL?

    /// How far through playback is. Without a position and a positive length
    /// there's nothing honest to draw, so the tile gets no progress bar.
    static func progress(positionSeconds: Double?, durationSeconds: Double?) -> Double? {
        guard let positionSeconds, let durationSeconds,
              positionSeconds.isFinite, durationSeconds.isFinite, durationSeconds > 0
        else { return nil }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }
}

/// The two Top Shelf rows for one viewer, each in the order the server sent.
/// Servers already put the most recent first, and Continue Watching mixes
/// started titles with the next episode of a show, which has no watch time
/// of its own, so sorting by watch time would push those episodes behind
/// the films.
struct ShelfFeed: Equatable, Sendable {
    var resume: [ShelfEntry]
    var upNext: [ShelfEntry]

    var isEmpty: Bool { resume.isEmpty && upNext.isEmpty }
}
