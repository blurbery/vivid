import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Downloads and decodes one file's preview sheets, and keeps what a scrub
/// is likely to need next.
///
/// A sheet is a few hundred kilobytes as a JPEG and tens of megabytes
/// decoded, so the JPEGs of recently used sheets stay in memory while only
/// two are ever held decoded. A decoded sheet answers every preview in its
/// stretch of the film at once.
///
/// Stills kept in one container file (Emby's) are fetched by byte range
/// instead: a short run of neighbouring stills per request, one request at a
/// time with the newest wanted first, held as JPEGs up to a byte limit. A
/// server that ignores the range sends the whole file, which is then kept
/// and sliced.
@MainActor
final class ScrubPreviewSheetStore {
    let sheets: ScrubPreviewSheets

    private static let scrubbingDecodedLimit = 2
    private static let dataLimit = 12
    private static let maximumSheetBytes = 16 * 1024 * 1024
    /// The longest side a sheet may decode to. Jellyfin's default sheet is
    /// 3200 by 1800.
    private static let maximumSheetSide = 8192
    /// And the most pixels: about 96 MB decoded.
    private static let maximumSheetPixels = 24_000_000
    /// How long a sheet that failed is left alone before another try.
    private static let retryDelay: TimeInterval = 30
    /// A container's stills are small, so more of them stay decoded: these
    /// many while a scrub runs and between scrubs.
    private static let scrubbingDecodedStillLimit = 24
    private static let idleDecodedStillLimit = 4
    /// The most JPEG bytes of a container's stills held at once.
    private static let stillDataByteLimit = 8 * 1024 * 1024
    /// One range request covers the wanted still, up to this many before it
    /// and after it, and no more than this many bytes.
    private static let runStillsBefore = 2
    private static let runStillsAfter = 5
    private static let runByteLimit = 512 * 1024
    /// How many range requests may wait behind the one running. An older
    /// one past that is dropped: the drag has left it behind.
    private static let rangeWaiterLimit = 3

    private let session: URLSession
    private let now: () -> Date
    /// Most recently used last.
    private var decoded: [(sheet: Int, image: CGImage)] = []
    private var data: [(sheet: Int, bytes: Data)] = []
    private var downloads: [Int: Task<Data?, Never>] = [:]
    private var decodes: [Int: Task<CGImage?, Never>] = [:]
    private var failures: [Int: Date] = [:]
    private var isShutDown = false
    /// A container file the server sent whole, sliced in place of requests.
    private var whole: Data?
    /// One range request runs at a time; the newest waiting goes next.
    private var isFetchingRange = false
    private var rangeWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Stills whose request was dropped from the line, which is no failure.
    private var skipped: Set<Int> = []
    /// How many sheets stay decoded: two while a scrub runs, one between.
    private var decodedLimit: Int
    /// These move on whenever decoded sheets or JPEGs are given back, so
    /// work that was already running then doesn't put its result back.
    private var decodedEpoch = 0
    private var dataEpoch = 0
    /// One sheet decodes at a time. A sheet that's ready while another is
    /// decoding waits here, in order, so two never decode together even
    /// when two loads of the same file overlap.
    private var isDecoding = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Tests only: how many sheets are waiting for their turn to decode.
    var decodeWaiterCount: Int { decodeWaiters.count }
    /// Tests only: runs just before a sheet is decoded, once the decode
    /// before it has finished.
    var willDecode: (@MainActor (Int) async -> Void)?

    private var observers: [NSObjectProtocol] = []

    init(sheets: ScrubPreviewSheets, session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        var sheets = sheets
        // A file that came whole is held here, where it can be given back.
        whole = sheets.container?.whole
        sheets.container?.whole = nil
        self.sheets = sheets
        self.session = session ?? Self.makeSession()
        self.now = now
        decodedLimit = sheets.container == nil ? Self.scrubbingDecodedLimit : Self.scrubbingDecodedStillLimit
        let centre = NotificationCenter.default
        observers = [
            centre.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseMemory() }
            },
            // In the background only the small JPEGs are worth holding.
            centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredBackground() }
            },
        ]
    }

    /// Drops everything decoded and downloaded; it's fetched again on demand.
    func releaseMemory() {
        decodedEpoch &+= 1
        dataEpoch &+= 1
        decoded = []
        data = []
        whole = nil
    }

    private func enteredBackground() {
        decodedEpoch &+= 1
        decoded = []
        // A whole container file is too much to sit on in the background.
        if whole != nil {
            dataEpoch &+= 1
            whole = nil
        }
    }

    /// While a scrub runs two sheets stay decoded. Between scrubs only the
    /// one last used does, so the next scrub near it still answers at once;
    /// a sheet that lands after the scrub ended is held to the same limit.
    func setScrubbing(_ scrubbing: Bool) {
        if sheets.container == nil {
            decodedLimit = scrubbing ? Self.scrubbingDecodedLimit : 1
        } else {
            decodedLimit = scrubbing ? Self.scrubbingDecodedStillLimit : Self.idleDecodedStillLimit
        }
        trimDecoded()
    }

    private func trimDecoded() {
        if decoded.count > decodedLimit { decoded.removeFirst(decoded.count - decodedLimit) }
    }

    /// Leaves a sheet alone for the retry delay, and forgets its bytes.
    func markFailed(_ sheet: Int) {
        failures[sheet] = now()
        decoded.removeAll { $0.sheet == sheet }
        data.removeAll { $0.sheet == sheet }
    }

    /// The decoded sheet, if it's already in memory.
    func cached(_ sheet: Int) -> CGImage? {
        guard let position = decoded.firstIndex(where: { $0.sheet == sheet }) else { return nil }
        let entry = decoded.remove(at: position)
        decoded.append(entry)
        return entry.image
    }

    /// True while a sheet that couldn't be fetched or decoded is waiting out
    /// its retry delay.
    func hasFailed(_ sheet: Int) -> Bool {
        guard let failedAt = failures[sheet] else { return false }
        if now().timeIntervalSince(failedAt) < Self.retryDelay { return true }
        failures[sheet] = nil
        return false
    }

    /// The decoded sheet, downloading and decoding it as needed. Callers
    /// asking for the same sheet share one download and one decode.
    func image(_ sheet: Int) async -> CGImage? {
        if let image = cached(sheet) { return image }
        guard !isShutDown, (0..<sheets.sheetCount).contains(sheet), !hasFailed(sheet) else { return nil }
        if let running = decodes[sheet] { return await running.value }
        let epoch = decodedEpoch
        let task = Task { @MainActor [weak self] () -> CGImage? in
            guard let self, let bytes = await self.bytes(sheet) else { return nil }
            await self.enterDecode()
            defer { self.leaveDecode() }
            guard !self.isShutDown, !Task.isCancelled else { return nil }
            await self.willDecode?(sheet)
            let side = Self.maximumSheetSide
            let pixels = Self.maximumSheetPixels
            return await Task.detached(priority: .userInitiated) {
                Self.decode(bytes, maximumSide: side, maximumPixels: pixels)
            }.value
        }
        decodes[sheet] = task
        let image = await task.value
        decodes[sheet] = nil
        if let image {
            // Memory given back while this decoded stays given back; the
            // caller still gets its still.
            if epoch == decodedEpoch { remember(image, for: sheet) }
        } else if !isShutDown, skipped.remove(sheet) == nil {
            markFailed(sheet)
        }
        return image
    }

    /// Takes the decode turn, waiting in line if a sheet is decoding.
    private func enterDecode() async {
        if !isDecoding {
            isDecoding = true
            return
        }
        await withCheckedContinuation { decodeWaiters.append($0) }
    }

    /// Hands the turn to the sheet that has waited longest, if any.
    private func leaveDecode() {
        if decodeWaiters.isEmpty {
            isDecoding = false
        } else {
            decodeWaiters.removeFirst().resume()
        }
    }

    /// Starts downloading a sheet's JPEG without decoding it, so reaching it
    /// later costs a decode and no request. A container's still that is
    /// already downloaded is decoded, so the drag reaching it is answered
    /// at once.
    func prefetch(_ sheet: Int) {
        guard !isShutDown, (0..<sheets.sheetCount).contains(sheet), !hasFailed(sheet),
              !decoded.contains(where: { $0.sheet == sheet })
        else { return }
        guard !data.contains(where: { $0.sheet == sheet }), whole == nil else {
            if sheets.container != nil, decodes[sheet] == nil {
                Task { @MainActor [weak self] in _ = await self?.image(sheet) }
            }
            return
        }
        _ = download(sheet)
    }

    /// Stops every request and drops everything held.
    func shutdown() {
        isShutDown = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        downloads.values.forEach { $0.cancel() }
        decodes.values.forEach { $0.cancel() }
        downloads = [:]
        decodes = [:]
        // Everyone in line is let through; they see the shutdown and stop.
        let waiting = decodeWaiters
        decodeWaiters = []
        waiting.forEach { $0.resume() }
        let waitingRanges = rangeWaiters
        rangeWaiters = []
        waitingRanges.forEach { $0.resume(returning: false) }
        decoded = []
        data = []
        whole = nil
        session.invalidateAndCancel()
    }

    // MARK: - Fetching

    private func bytes(_ sheet: Int) async -> Data? {
        if let whole, let container = sheets.container {
            return Self.slice(whole, container.range(ofStill: sheet))
        }
        if let position = data.firstIndex(where: { $0.sheet == sheet }) {
            let entry = data.remove(at: position)
            data.append(entry)
            return entry.bytes
        }
        return await download(sheet).value
    }

    private func download(_ sheet: Int) -> Task<Data?, Never> {
        if let running = downloads[sheet] { return running }
        if let container = sheets.container { return downloadRun(around: sheet, in: container) }
        var request = URLRequest(url: sheets.sheetURLs[sheet])
        for (name, value) in sheets.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("image/jpeg, image/*;q=0.8", forHTTPHeaderField: "Accept")
        let session = session
        // A request carrying the account's header must never follow a
        // redirect to somewhere else. A signed URL may be redirected, but
        // not from HTTPS down to public plain HTTP.
        let carriesHeaders = !sheets.headers.isEmpty
        let limit = Self.maximumSheetBytes
        let epoch = dataEpoch
        let task = Task { @MainActor [weak self] () -> Data? in
            let fetched = await ScrubPreviewFetch.fetch(request, session: session, limit: limit) { from, to in
                !carriesHeaders && PlainHTTPRedirectGuard.allows(from: from, to: to)
            }.body
            guard let self, !Task.isCancelled else { return nil }
            self.downloads[sheet] = nil
            if let fetched {
                if epoch == self.dataEpoch { self.remember(fetched, for: sheet) }
            } else {
                self.failures[sheet] = self.now()
            }
            return fetched
        }
        downloads[sheet] = task
        return task
    }

    // MARK: - Stills in a container file

    /// One range request for the wanted still and the neighbours around it
    /// that aren't held, on their way or failed. Every still in the run
    /// shares the request, so asking for a neighbour starts nothing new.
    private func downloadRun(around sheet: Int, in container: ScrubPreviewSheets.Container) -> Task<Data?, Never> {
        func size(_ still: Int) -> Int { container.range(ofStill: still).count }
        func isWanted(_ still: Int) -> Bool {
            (0..<sheets.sheetCount).contains(still) && downloads[still] == nil && failures[still] == nil
                && !data.contains { $0.sheet == still }
        }
        var first = sheet
        var last = sheet
        var total = size(sheet)
        while last - sheet < Self.runStillsAfter, isWanted(last + 1), total + size(last + 1) <= Self.runByteLimit {
            last += 1
            total += size(last)
        }
        while sheet - first < Self.runStillsBefore, isWanted(first - 1), total + size(first - 1) <= Self.runByteLimit {
            first -= 1
            total += size(first)
        }
        let members = first...last
        let lower = container.offsets[first]
        let upper = container.offsets[last + 1]
        var request = URLRequest(url: container.url)
        for (name, value) in sheets.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("bytes=\(lower)-\(upper - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let session = session
        let carriesHeaders = !sheets.headers.isEmpty
        let fileEnd = container.offsets[container.offsets.count - 1]
        let epoch = dataEpoch
        skipped.subtract(members)

        let run = Task { @MainActor [weak self] () -> [Int: Data]? in
            guard let self else { return nil }
            guard await self.enterRange() else {
                // Dropped from the line. Not a failure: the still is asked
                // for again when a target next needs it.
                guard !self.isShutDown else { return nil }
                for member in members {
                    self.downloads[member] = nil
                    self.skipped.insert(member)
                }
                return nil
            }
            defer { self.leaveRange() }
            guard !self.isShutDown else { return nil }
            var stills: [Int: Data] = [:]
            var wholeFile = self.whole
            if wholeFile == nil {
                // The limit allows for a server that ignores the range and
                // sends the whole file.
                let reply = await ScrubPreviewFetch.fetch(
                    request, session: session, limit: ScrubPreviewSheets.Container.maximumFileBytes
                ) { from, to in
                    !carriesHeaders && PlainHTTPRedirectGuard.allows(from: from, to: to)
                }
                guard !self.isShutDown else { return nil }
                if let body = reply.body {
                    if reply.status == 206, reply.rangeStart == lower, body.count == upper - lower {
                        for member in members {
                            let range = container.range(ofStill: member)
                            stills[member] = Self.slice(body, (range.lowerBound - lower)..<(range.upperBound - lower))
                        }
                    } else if reply.status == 200, body.count >= fileEnd {
                        wholeFile = body
                        if epoch == self.dataEpoch { self.whole = body }
                    }
                }
            }
            if let wholeFile {
                for member in members {
                    stills[member] = Self.slice(wholeFile, container.range(ofStill: member))
                }
            }
            for member in members { self.downloads[member] = nil }
            guard stills.count == members.count else {
                let failedAt = self.now()
                for member in members { self.failures[member] = failedAt }
                return nil
            }
            if self.whole == nil, epoch == self.dataEpoch {
                // The wanted still last, so it's the most recently used.
                for member in members where member != sheet {
                    if let bytes = stills[member] { self.remember(bytes, for: member) }
                }
                if let bytes = stills[sheet] { self.remember(bytes, for: sheet) }
            }
            return stills
        }
        let wanted = Task { @MainActor in await run.value?[sheet] }
        for member in members {
            downloads[member] = member == sheet ? wanted : Task { @MainActor in await run.value?[member] }
        }
        return wanted
    }

    /// Takes the range request turn. False when this request was dropped
    /// from the line, or the store shut down, before its turn came.
    private func enterRange() async -> Bool {
        if !isFetchingRange {
            isFetchingRange = true
            return true
        }
        if rangeWaiters.count >= Self.rangeWaiterLimit {
            rangeWaiters.removeFirst().resume(returning: false)
        }
        return await withCheckedContinuation { rangeWaiters.append($0) }
    }

    /// Hands the turn to the request that joined the line last, if any.
    private func leaveRange() {
        if let next = rangeWaiters.popLast() {
            next.resume(returning: true)
        } else {
            isFetchingRange = false
        }
    }

    /// A copy of `range` of `data`, counted from its first byte. Nil when
    /// the data doesn't reach that far.
    nonisolated private static func slice(_ data: Data, _ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= data.count, !range.isEmpty else { return nil }
        return data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
    }

    private func remember(_ image: CGImage, for sheet: Int) {
        guard !isShutDown else { return }
        decoded.removeAll { $0.sheet == sheet }
        decoded.append((sheet, image))
        trimDecoded()
    }

    private func remember(_ bytes: Data, for sheet: Int) {
        guard !isShutDown else { return }
        data.removeAll { $0.sheet == sheet }
        data.append((sheet, bytes))
        if sheets.container != nil {
            var total = data.reduce(0) { $0 + $1.bytes.count }
            while total > Self.stillDataByteLimit, data.count > 1 {
                total -= data.removeFirst().bytes.count
            }
        } else if data.count > Self.dataLimit {
            data.removeFirst(data.count - Self.dataLimit)
        }
    }

    /// Decodes the whole sheet now, off the main actor, so cropping it later
    /// is free. Nil for anything that isn't an image of a sane size.
    nonisolated private static func decode(_ bytes: Data, maximumSide: Int, maximumPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumSide).contains(width), (1...maximumSide).contains(height),
              width * height <= maximumPixels
        else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// One bounded download for the preview store and the container index.
enum ScrubPreviewFetch {
    struct Reply: Sendable {
        /// The reply's status, or nil when there was no reply.
        let status: Int?
        /// The body of a 2xx reply that stayed within the limit.
        let body: Data?
        /// From a `Content-Range` header: where the body starts in the
        /// file, and the file's whole length when the server gave it.
        let rangeStart: Int?
        let totalLength: Int?
    }

    /// Receives the body in the chunks the session delivers, on its own
    /// queue, and cancels as soon as it passes `limit`, so an oversized
    /// reply is never held whole.
    static func fetch(
        _ request: URLRequest,
        session: URLSession,
        limit: Int,
        allowsRedirect: @escaping @Sendable (URL?, URL?) -> Bool
    ) async -> Reply {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            task.delegate = SheetReceiver(limit: limit, allowsRedirect: allowsRedirect, continuation: continuation)
            task.resume()
        }
    }

    /// `bytes 0-99/1234` gives (0, 1234); `bytes 0-99/*` gives (0, nil).
    static func contentRange(_ header: String?) -> (start: Int, total: Int?)? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let sides = parts[1].split(separator: "/", maxSplits: 1)
        guard sides.count == 2,
              let start = sides[0].split(separator: "-").first.flatMap({ Int($0) }), start >= 0
        else { return nil }
        return (start, Int(sides[1]).flatMap { $0 > 0 ? $0 : nil })
    }
}

/// One download. The session calls it on its delegate queue, one call at a
/// time, and it answers exactly once, when the task completes.
private final class SheetReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let allowsRedirect: @Sendable (URL?, URL?) -> Bool
    private var continuation: CheckedContinuation<ScrubPreviewFetch.Reply, Never>?
    private var body = Data()
    private var refused = false
    private var status: Int?
    private var range: (start: Int, total: Int?)?

    init(limit: Int, allowsRedirect: @escaping @Sendable (URL?, URL?) -> Bool,
         continuation: CheckedContinuation<ScrubPreviewFetch.Reply, Never>) {
        self.limit = limit
        self.allowsRedirect = allowsRedirect
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A refused redirect ends the task with the redirect response.
        completionHandler(allowsRedirect(response.url, request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        status = http?.statusCode
        range = ScrubPreviewFetch.contentRange(http?.value(forHTTPHeaderField: "Content-Range"))
        guard let http, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= Int64(limit)
        else {
            refused = true
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0 {
            body.reserveCapacity(Int(response.expectedContentLength))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !refused else { return }
        body.append(data)
        if body.count > limit {
            refused = true
            body = Data()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let received = error == nil && !refused && !body.isEmpty ? body : nil
        body = Data()
        continuation?.resume(returning: .init(
            status: status, body: received, rangeStart: range?.start, totalLength: range?.total))
        continuation = nil
    }
}
