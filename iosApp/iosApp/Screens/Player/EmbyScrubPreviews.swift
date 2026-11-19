import Foundation

/// Where one file's container of preview stills is, before anything has been
/// asked of the server: built when playback is prepared, read only after the
/// load's first frame.
struct ScrubPreviewContainerSource: Equatable, Sendable {
    /// The server, item, file and width, as ``ScrubPreviewSheets/key``.
    let key: String
    let url: URL
    /// Sent with every request for the file.
    let headers: [String: String]
}

/// The index of a BIF file, the container Emby keeps a video's seek preview
/// stills in.
///
/// Every number is an unsigned 32-bit little-endian integer. The file opens
/// with eight identifying bytes, then a version at byte 8, the number of
/// stills at 12 and, at 16, how many milliseconds one timestamp unit is (0
/// means 1000). The header is padded to 64 bytes. From there come one more
/// index entries than there are stills, each a timestamp and an offset from
/// the start of the file; the extra entry has the timestamp `0xFFFFFFFF` and
/// marks where the last still ends. Still `i` is the JPEG from its offset to
/// the next entry's, shown from its timestamp times the unit.
struct BIFIndex: Equatable, Sendable {
    /// When each still starts, in milliseconds.
    let startsMilliseconds: [Int]
    /// Each still's offset, then the end of the last one.
    let offsets: [Int]

    enum Outcome: Equatable {
        case index(BIFIndex)
        /// The header is sound but the index runs past the bytes given: this
        /// many bytes from the start of the file hold all of it.
        case needs(Int)
        case invalid
    }

    static let headerLength = 64
    private static let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
    /// A timestamp unit of more than a minute isn't a seek preview.
    private static let maximumUnitMilliseconds = 60_000

    /// Reads the index from the start of a file. `totalLength` is the whole
    /// file's length when it's known. `isWholeFile` says `data` is all there
    /// is, so an index that runs past it is broken, not merely cut short.
    static func parse(_ data: Data, totalLength: Int?, isWholeFile: Bool) -> Outcome {
        guard data.count >= headerLength, data.prefix(magic.count).elementsEqual(magic) else { return .invalid }
        let count = Int(word(data, at: 12))
        let unit = Int(word(data, at: 16))
        guard (1...ScrubPreviewSheets.maximumThumbnailCount).contains(count),
              unit <= maximumUnitMilliseconds
        else { return .invalid }
        let multiplier = unit == 0 ? 1000 : unit
        let indexEnd = headerLength + 8 * (count + 1)
        let fileLength = isWholeFile ? data.count : totalLength
        if let fileLength, fileLength <= indexEnd { return .invalid }
        guard data.count >= indexEnd else { return isWholeFile ? .invalid : .needs(indexEnd) }

        var starts: [Int] = []
        var offsets: [Int] = []
        starts.reserveCapacity(count)
        offsets.reserveCapacity(count + 1)
        for entry in 0...count {
            let position = headerLength + 8 * entry
            let timestamp = Int(word(data, at: position))
            let offset = Int(word(data, at: position + 4))
            // Stills sit after the index, each after the one before it, and
            // none is bigger than a preview could be.
            guard offset >= (offsets.last.map { $0 + 1 } ?? indexEnd),
                  offset - (offsets.last ?? offset) <= ScrubPreviewSheets.Container.maximumStillBytes
            else { return .invalid }
            offsets.append(offset)
            guard entry < count else { break }
            let start = timestamp * multiplier
            guard timestamp != 0xFFFF_FFFF, start > (starts.last ?? -1) else { return .invalid }
            starts.append(start)
        }
        if let fileLength, offsets[count] > fileLength { return .invalid }
        return .index(BIFIndex(startsMilliseconds: starts, offsets: offsets))
    }

    private static func word(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}

/// Emby's seek preview stills. Emby makes them per video, when its library is
/// set to, as one BIF file per width and serves it from
/// `GET /Videos/{item}/index.bif?Width=`, to a signed-in user. The route names
/// an item, not a media source, so a file gets previews only when it's the
/// item's own.
enum EmbyScrubPreviews {
    /// The width Emby makes by default.
    static let width = 320
    /// Asked for first: the header and, for all but the longest films, the
    /// whole index (about 8,000 stills' worth).
    static let firstRangeLength = 64 * 1024

    /// The description of the playing file's stills, with nothing asked of
    /// the server. Nil for an alternate version of an item, which the route
    /// can't name.
    static func source(
        item: [String: Any],
        itemID: String,
        sourceID: String,
        serverURL: String,
        headers: [String: String]
    ) -> ScrubPreviewContainerSource? {
        let sourceCount = (item["MediaSources"] as? [[String: Any]])?.count ?? 0
        guard sourceCount <= 1 || sourceID == "mediasource_\(itemID)",
              let pathID = try? EmbyConnection.id(itemID),
              let url = try? EmbyConnection.url(
                  serverURL: serverURL, path: "/Videos/\(pathID)/index.bif", query: ["Width": String(width)])
        else { return nil }
        return ScrubPreviewContainerSource(
            key: "emby|\(serverURL)|\(itemID)|\(sourceID)|\(width)", url: url, headers: headers)
    }

    /// Reads one file's index when the provider asks, which is after the
    /// load's first frame: one small range request, a second only when the
    /// index is longer than the first covered. A server that ignores the
    /// range sends the whole file, which is kept if it's small enough.
    @MainActor
    final class Loader {
        private let source: ScrubPreviewContainerSource
        private let session: URLSession
        /// The server said this file has no previews. It isn't asked again.
        private var isAbsent = false

        init(_ source: ScrubPreviewContainerSource, session: URLSession? = nil) {
            self.source = source
            self.session = session ?? EmbyScrubPreviews.session
        }

        func load() async -> ScrubPreviewSheets? {
            guard !isAbsent else { return nil }
            let first = await fetch(length: EmbyScrubPreviews.firstRangeLength)
            if first.status == 404 {
                isAbsent = true
                return nil
            }
            guard let body = first.body else { return nil }
            if first.status == 200 {
                return sheets(BIFIndex.parse(body, totalLength: nil, isWholeFile: true), whole: body)
            }
            guard first.status == 206, first.rangeStart == 0 else { return nil }
            let outcome = BIFIndex.parse(body, totalLength: first.totalLength, isWholeFile: false)
            guard case let .needs(length) = outcome else { return sheets(outcome, whole: nil) }
            let second = await fetch(length: length)
            guard second.status == 206, second.rangeStart == 0, let longer = second.body else { return nil }
            return sheets(BIFIndex.parse(longer, totalLength: second.totalLength, isWholeFile: false), whole: nil)
        }

        private func sheets(_ outcome: BIFIndex.Outcome, whole: Data?) -> ScrubPreviewSheets? {
            guard case let .index(index) = outcome else { return nil }
            return ScrubPreviewSheets(
                key: source.key,
                container: .init(
                    url: source.url, startsMilliseconds: index.startsMilliseconds, offsets: index.offsets, whole: whole),
                headers: source.headers)
        }

        /// The first `length` bytes of the file. The request carries the
        /// account's headers, so it never follows a redirect.
        private func fetch(length: Int) async -> ScrubPreviewFetch.Reply {
            var request = URLRequest(url: source.url)
            for (name, value) in source.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            return await ScrubPreviewFetch.fetch(
                request, session: session, limit: ScrubPreviewSheets.Container.maximumFileBytes
            ) { _, _ in false }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
