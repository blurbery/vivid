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
    /// ISO 8601 text exactly as the server sent it. It is only ever compared
    /// as text, which orders correctly for one server's own timestamps.
    let lastWatched: String?
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

/// The two Top Shelf rows for one viewer.
struct ShelfFeed: Equatable, Sendable {
    var resume: [ShelfEntry]
    var upNext: [ShelfEntry]

    var isEmpty: Bool { resume.isEmpty && upNext.isEmpty }

    /// Both rows with the most recently watched entry first. Servers don't
    /// agree on an order, and Silo can split one row over several sections.
    static func newestFirst(resume: [ShelfEntry], upNext: [ShelfEntry]) -> ShelfFeed {
        ShelfFeed(resume: resume.newestFirst(), upNext: upNext.newestFirst())
    }
}

extension Array where Element == ShelfEntry {
    /// Entries without a watch time go last. Ties keep the server's order,
    /// which the original position settles because `sorted` makes no promise
    /// about equal elements.
    func newestFirst() -> [ShelfEntry] {
        enumerated().sorted { left, right in
            switch (left.element.lastWatched, right.element.lastWatched) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }
}
