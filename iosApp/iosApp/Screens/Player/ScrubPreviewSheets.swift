import CoreGraphics
import Foundation

/// A server's seek-bar previews for one file: JPEG sheets, each a grid of
/// small stills taken at a fixed interval ("trickplay").
///
/// Silo publishes them through `GET /api/v2/watch/{id}/trickplay` and
/// Jellyfin (10.9 and later) through an item's `Trickplay` member. The server
/// made the stills ahead of time, so a preview is a crop of a sheet already in
/// memory: nothing is decoded from the stream. Stills are indexed by source
/// media time, the axis the scrub bar uses, so a target the loaded transport
/// can't reach still has one.
///
/// Emby keeps a file's stills differently: one container file holding a JPEG
/// per still (``Container``). It's described here too, as sheets of a single
/// cell each, so both shapes share the store and the provider.
struct ScrubPreviewSheets: Equatable, Sendable {
    /// One still's place: which sheet, and its cell in that sheet's grid.
    struct Tile: Equatable, Sendable {
        let index: Int
        let sheet: Int
        let column: Int
        let row: Int
    }

    /// One file holding every still as a JPEG of its own, each addressed by
    /// a byte range and shown from its own start time. Still `i` is "sheet"
    /// `i`, a grid of one cell.
    struct Container: Equatable, Sendable {
        let url: URL
        /// When each still starts, in milliseconds, strictly ascending.
        let startsMilliseconds: [Int]
        /// Where each still's JPEG starts in the file, then where the last
        /// one ends: one more entry than there are stills.
        let offsets: [Int]
        /// The whole file, when the server sent all of it in answer to the
        /// request for its index. The store takes it over.
        var whole: Data?

        /// The most one container file may weigh when it has to be fetched
        /// whole.
        static let maximumFileBytes = 16 * 1024 * 1024
        /// The most one still's JPEG may weigh.
        static let maximumStillBytes = 2 * 1024 * 1024

        func range(ofStill still: Int) -> Range<Int> {
            offsets[still]..<offsets[still + 1]
        }
    }

    /// The server, item and file the sheets belong to. A new load of the
    /// same file keeps the sheets it already has.
    let key: String
    let intervalMilliseconds: Int
    let columns: Int
    let rows: Int
    let thumbnailCount: Int
    let sheetURLs: [URL]
    /// Sent with every sheet request. Empty when the URLs carry their own
    /// authorisation, as Silo's do.
    let headers: [String: String]
    /// When the sheet URLs stop working, if they do.
    let expiresAt: Date?
    /// Set when the stills live in one container file instead of on sheets.
    var container: Container?

    /// How many separately fetched pieces there are: sheets, or stills in a
    /// container.
    var sheetCount: Int { container?.offsets.count.advanced(by: -1) ?? sheetURLs.count }

    /// The most cells one sheet may have on a side. Silo uses up to 10 and
    /// Jellyfin 10 by default.
    static let maximumGridSide = 32
    static let maximumThumbnailCount = 100_000

    /// Nil when the description can't address every still it promises.
    init?(
        key: String,
        intervalMilliseconds: Int,
        columns: Int,
        rows: Int,
        thumbnailCount: Int,
        sheetURLs: [URL],
        headers: [String: String],
        expiresAt: Date?
    ) {
        guard intervalMilliseconds > 0,
              (1...Self.maximumGridSide).contains(columns),
              (1...Self.maximumGridSide).contains(rows),
              (1...Self.maximumThumbnailCount).contains(thumbnailCount)
        else { return nil }
        let perSheet = columns * rows
        let sheetsNeeded = (thumbnailCount + perSheet - 1) / perSheet
        guard sheetURLs.count >= sheetsNeeded else { return nil }
        self.key = key
        self.intervalMilliseconds = intervalMilliseconds
        self.columns = columns
        self.rows = rows
        self.thumbnailCount = thumbnailCount
        self.sheetURLs = Array(sheetURLs.prefix(sheetsNeeded))
        self.headers = headers
        self.expiresAt = expiresAt
        self.container = nil
    }

    /// Stills in one container file. Nil unless every still has a start time
    /// later than the one before and a byte range of a sane size after it.
    init?(key: String, container: Container, headers: [String: String]) {
        let starts = container.startsMilliseconds
        let offsets = container.offsets
        guard (1...Self.maximumThumbnailCount).contains(starts.count),
              offsets.count == starts.count + 1,
              starts[0] >= 0, offsets[0] >= 0,
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(offsets, offsets.dropFirst()).allSatisfy({
                  $0 < $1 && $1 - $0 <= Container.maximumStillBytes
              })
        else { return nil }
        self.key = key
        intervalMilliseconds = max(1, starts.count > 1 ? (starts[starts.count - 1] - starts[0]) / (starts.count - 1) : 1)
        columns = 1
        rows = 1
        thumbnailCount = starts.count
        sheetURLs = []
        self.headers = headers
        expiresAt = nil
        self.container = container
    }

    /// The still covering `sourceTime`: still `i` shows what plays from
    /// `i * interval` up to the next one. Nil for a time more than one
    /// interval past the last still, which means the sheets were made from a
    /// shorter file than the one playing.
    func tile(atSourceTime sourceTime: Double) -> Tile? {
        guard sourceTime.isFinite, sourceTime >= 0 else { return nil }
        if let container { return Self.tile(atSourceTime: sourceTime, starts: container.startsMilliseconds) }
        let position = sourceTime * 1000 / Double(intervalMilliseconds)
        guard position < Double(thumbnailCount + 1) else { return nil }
        let index = min(Int(position), thumbnailCount - 1)
        let perSheet = columns * rows
        let cell = index % perSheet
        return Tile(index: index, sheet: index / perSheet, column: cell % columns, row: cell / columns)
    }

    /// A container's stills carry their own start times, so nothing assumes
    /// an even interval: the still is the last one starting at or before the
    /// target, or the first for a target before them all. Nil for a time more
    /// than two typical gaps past the last still's start, the same allowance
    /// a grid gets.
    private static func tile(atSourceTime sourceTime: Double, starts: [Int]) -> Tile? {
        guard let first = starts.first, let last = starts.last else { return nil }
        let target = sourceTime * 1000
        if starts.count > 1 {
            let typicalGap = Double(last - first) / Double(starts.count - 1)
            guard target < Double(last) + 2 * typicalGap else { return nil }
        }
        // The first still that starts after the target; the one before it
        // covers the target.
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if Double(starts[middle]) <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = max(low - 1, 0)
        return Tile(index: index, sheet: index, column: 0, row: 0)
    }

    /// True once the URLs have expired or are about to.
    func isExpiring(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }

    /// The tile's pixels in a decoded sheet. The cell size comes from the
    /// image itself, so a sheet the server scaled still crops on its grid.
    /// Nil when the image is too small to hold the grid.
    func crop(_ tile: Tile, from sheet: CGImage) -> CGImage? {
        let cellWidth = sheet.width / columns
        let cellHeight = sheet.height / rows
        guard cellWidth >= 8, cellHeight >= 8 else { return nil }
        return sheet.cropping(to: CGRect(
            x: tile.column * cellWidth,
            y: tile.row * cellHeight,
            width: cellWidth,
            height: cellHeight
        ))
    }
}

// MARK: - Silo

/// Silo's seek-bar previews ("getWatchTrickplay" in Silo's v2 API). Only v2
/// servers have them, and only for files in a library with previews turned
/// on. The request goes through `HTTPClient.optionalSiloV2Request`, which
/// never starts a token refresh, so a refusal can't sign anyone out. A 404 is
/// the ordinary answer for a file with no previews.
enum SiloScrubPreviews {
    static func key(contentID: String, fileID: Int) -> String {
        "silo|\(contentID)|\(fileID)"
    }

    static func load(contentID: String, fileID: Int, http: HTTPClient = .shared) async -> ScrubPreviewSheets? {
        guard let id = SiloThemeMusic.pathSegment(contentID) else { return nil }
        let response = try? await http.optionalSiloV2Request(
            method: "GET",
            path: "/api/v2/watch/\(id)/trickplay",
            query: ["file_id": String(fileID)],
            quietStatuses: [404]
        )
        guard let response else { return nil }
        return decode(response.data, serverURL: response.serverURL, key: key(contentID: contentID, fileID: fileID))
    }

    private struct Manifest: Decodable {
        struct Sheet: Decodable {
            let index: Int
            let url: String
        }

        let intervalMs: Int
        let tileColumns: Int
        let tileRows: Int
        let thumbnailCount: Int
        let sheets: [Sheet]
        let expiresAt: String?
    }

    /// Sheet URLs are root-relative on the server or absolute on its storage,
    /// and carry their own authorisation, so they're fetched with no headers.
    /// One URL that can't be used drops the whole set.
    static func decode(_ data: Data, serverURL: String, key: String) -> ScrubPreviewSheets? {
        guard let manifest = try? HTTPClient.makeJSONDecoder().decode(Manifest.self, from: data) else { return nil }
        let ordered = manifest.sheets.sorted { $0.index < $1.index }
        guard ordered.enumerated().allSatisfy({ $0.offset == $0.element.index }) else { return nil }
        var urls: [URL] = []
        for sheet in ordered {
            guard let url = SiloThemeMusic.resolveGrantURL(sheet.url, serverURL: serverURL) else { return nil }
            urls.append(url)
        }
        return ScrubPreviewSheets(
            key: key,
            intervalMilliseconds: manifest.intervalMs,
            columns: manifest.tileColumns,
            rows: manifest.tileRows,
            thumbnailCount: manifest.thumbnailCount,
            sheetURLs: urls,
            headers: [:],
            expiresAt: manifest.expiresAt.flatMap(parseInstant)
        )
    }

    private static func parseInstant(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

// MARK: - Jellyfin

/// Jellyfin's trickplay sheets, read from the item's `Trickplay` member:
/// media source ID, then width, then the grid. `TileWidth` and `TileHeight`
/// count cells, not pixels. Sheets are fetched from
/// `/Videos/{source}/Trickplay/{width}/{sheet}.jpg` with the session's header.
enum JellyfinScrubPreviews {
    /// The width a preview is drawn at on the largest screen, in pixels.
    /// The narrowest set at least this wide is used, else the widest.
    private static let wantedWidth = 480

    static func sheets(
        item: [String: Any],
        itemID: String,
        sourceID: String,
        serverURL: String,
        headers: [String: String]
    ) -> ScrubPreviewSheets? {
        guard let bySource = item["Trickplay"] as? [String: Any] else { return nil }
        // Jellyfin writes the ID as a GUID with or without dashes.
        let wanted = normalised(sourceID)
        guard let widths = bySource.first(where: { normalised($0.key) == wanted })?.value as? [String: Any] else { return nil }
        let sets: [(width: Int, info: [String: Any])] = widths.compactMap { key, value in
            guard let width = Int(key), width > 0, let info = value as? [String: Any] else { return nil }
            return (width, info)
        }.sorted { $0.width < $1.width }
        guard let chosen = sets.first(where: { $0.width >= wantedWidth }) ?? sets.last,
              let interval = chosen.info["Interval"] as? Int,
              let columns = chosen.info["TileWidth"] as? Int,
              let rows = chosen.info["TileHeight"] as? Int,
              let count = chosen.info["ThumbnailCount"] as? Int,
              // Checked before any arithmetic, so a bogus reply can't overflow.
              (1...ScrubPreviewSheets.maximumGridSide).contains(columns),
              (1...ScrubPreviewSheets.maximumGridSide).contains(rows),
              (1...ScrubPreviewSheets.maximumThumbnailCount).contains(count),
              // An alternate version is an item of its own, with the source's
              // ID, and its sheets belong to that item. Jellyfin 10.9 looks
              // the path's item up and ignores `mediaSourceId`.
              let pathID = (try? JellyfinConnection.id(sourceID)) ?? (try? JellyfinConnection.id(itemID))
        else { return nil }
        let perSheet = columns * rows
        let sheetCount = (count + perSheet - 1) / perSheet
        var urls: [URL] = []
        for sheet in 0..<sheetCount {
            guard let url = try? JellyfinConnection.url(
                serverURL: serverURL,
                path: "/Videos/\(pathID)/Trickplay/\(chosen.width)/\(sheet).jpg",
                query: ["mediaSourceId": sourceID]
            ) else { return nil }
            urls.append(url)
        }
        return ScrubPreviewSheets(
            key: "jellyfin|\(serverURL)|\(itemID)|\(sourceID)|\(chosen.width)",
            intervalMilliseconds: interval,
            columns: columns,
            rows: rows,
            thumbnailCount: count,
            sheetURLs: urls,
            headers: headers,
            expiresAt: nil
        )
    }

    private static func normalised(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
