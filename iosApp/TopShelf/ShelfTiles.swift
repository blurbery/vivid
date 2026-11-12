import Foundation
import TVServices

/// Turns a feed into what tvOS draws: one row of poster tiles per list.
enum ShelfTiles {
    static func content(for feed: ShelfFeed, strings: ShelfStrings) -> TVTopShelfSectionedContent? {
        let rows = [
            row(titled: strings.continueWatching, entries: feed.resume, strings: strings),
            row(titled: strings.nextUp, entries: feed.upNext, strings: strings),
        ].compactMap { $0 }
        return rows.isEmpty ? nil : TVTopShelfSectionedContent(sections: rows)
    }

    /// Nil for an empty row, so tvOS doesn't show a heading with nothing
    /// under it.
    private static func row(
        titled title: String,
        entries: [ShelfEntry],
        strings: ShelfStrings
    ) -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? {
        let tiles = entries.compactMap { tile(for: $0, strings: strings) }
        guard !tiles.isEmpty else { return nil }
        let row = TVTopShelfItemCollection(items: tiles)
        row.title = title
        return row
    }

    /// Nil when the entry can't be linked back into Vivid, because a tile
    /// that does nothing when pressed is worse than no tile.
    private static func tile(for entry: ShelfEntry, strings: ShelfStrings) -> TVTopShelfSectionedItem? {
        guard let open = link("item", entry.id), let play = link("play", entry.id) else { return nil }
        let tile = TVTopShelfSectionedItem(identifier: entry.id)
        tile.title = strings.title(for: entry)
        tile.imageShape = .poster
        if let progress = entry.progress { tile.playbackProgress = progress }
        tile.displayAction = TVTopShelfAction(url: open)
        tile.playAction = TVTopShelfAction(url: play)
        if let poster = entry.poster {
            tile.setImageURL(poster, for: .screenScale1x)
            tile.setImageURL(poster, for: .screenScale2x)
        }
        return tile
    }

    /// `vivid://<action>/<id>`, with the ID escaped to stay one path segment.
    private static func link(_ action: String, _ id: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard !id.isEmpty, let segment = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "vivid://\(action)/\(segment)")
    }
}
