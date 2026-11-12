import TVServices

/// The Top Shelf extension's entry point, named in Info.plist. tvOS calls it
/// whenever it wants fresh rows; returning nil keeps the static artwork.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> TVTopShelfContent? {
        // The language is settled first, so it's in place for the whole run.
        let strings = ShelfStrings.current()
        guard let feed = await ShelfLoad().run() else { return nil }
        return ShelfTiles.content(for: feed, strings: strings)
    }
}
