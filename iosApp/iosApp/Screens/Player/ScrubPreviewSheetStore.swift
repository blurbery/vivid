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

    private let session: URLSession
    private let now: () -> Date
    /// Most recently used last.
    private var decoded: [(sheet: Int, image: CGImage)] = []
    private var data: [(sheet: Int, bytes: Data)] = []
    private var downloads: [Int: Task<Data?, Never>] = [:]
    private var decodes: [Int: Task<CGImage?, Never>] = [:]
    private var failures: [Int: Date] = [:]
    private var isShutDown = false
    /// How many sheets stay decoded: two while a scrub runs, one between.
    private var decodedLimit = ScrubPreviewSheetStore.scrubbingDecodedLimit
    /// These move on whenever decoded sheets or JPEGs are given back, so
    /// work that was already running then doesn't put its result back.
    private var decodedEpoch = 0
    private var dataEpoch = 0
    /// The newest decode. The next waits for it, so two sheets never decode
    /// together even when two loads of the same file overlap.
    private var lastDecode: Task<Void, Never>?
    /// Tests only: runs just before a sheet is decoded, once the decode
    /// before it has finished.
    var willDecode: (@MainActor (Int) async -> Void)?

    private var observers: [NSObjectProtocol] = []

    init(sheets: ScrubPreviewSheets, session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        self.sheets = sheets
        self.session = session ?? Self.makeSession()
        self.now = now
        let centre = NotificationCenter.default
        observers = [
            centre.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseMemory() }
            },
            // In the background only the small JPEGs are worth holding.
            centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseDecoded() }
            },
        ]
    }

    /// Drops everything decoded and downloaded; it's fetched again on demand.
    func releaseMemory() {
        decodedEpoch &+= 1
        dataEpoch &+= 1
        decoded = []
        data = []
    }

    private func releaseDecoded() {
        decodedEpoch &+= 1
        decoded = []
    }

    /// While a scrub runs two sheets stay decoded. Between scrubs only the
    /// one last used does, so the next scrub near it still answers at once;
    /// a sheet that lands after the scrub ended is held to the same limit.
    func setScrubbing(_ scrubbing: Bool) {
        decodedLimit = scrubbing ? Self.scrubbingDecodedLimit : 1
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
        guard !isShutDown, sheets.sheetURLs.indices.contains(sheet), !hasFailed(sheet) else { return nil }
        if let running = decodes[sheet] { return await running.value }
        let epoch = decodedEpoch
        let previous = lastDecode
        let task = Task { @MainActor [weak self] () -> CGImage? in
            guard let self else { return nil }
            let bytes = await self.bytes(sheet)
            // Waited for even when this sheet has nothing to decode, so the
            // one after it can't start while the one before still runs.
            await previous?.value
            guard let bytes, !Task.isCancelled else { return nil }
            await self.willDecode?(sheet)
            let side = Self.maximumSheetSide
            let pixels = Self.maximumSheetPixels
            return await Task.detached(priority: .userInitiated) {
                Self.decode(bytes, maximumSide: side, maximumPixels: pixels)
            }.value
        }
        decodes[sheet] = task
        lastDecode = Task { _ = await task.value }
        let image = await task.value
        decodes[sheet] = nil
        if let image {
            // Memory given back while this decoded stays given back; the
            // caller still gets its still.
            if epoch == decodedEpoch { remember(image, for: sheet) }
        } else if !isShutDown {
            markFailed(sheet)
        }
        return image
    }

    /// Starts downloading a sheet's JPEG without decoding it, so reaching it
    /// later costs a decode and no request.
    func prefetch(_ sheet: Int) {
        guard !isShutDown, sheets.sheetURLs.indices.contains(sheet), !hasFailed(sheet),
              !decoded.contains(where: { $0.sheet == sheet }), !data.contains(where: { $0.sheet == sheet })
        else { return }
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
        lastDecode = nil
        decoded = []
        data = []
        session.invalidateAndCancel()
    }

    // MARK: - Fetching

    private func bytes(_ sheet: Int) async -> Data? {
        if let position = data.firstIndex(where: { $0.sheet == sheet }) {
            let entry = data.remove(at: position)
            data.append(entry)
            return entry.bytes
        }
        return await download(sheet).value
    }

    private func download(_ sheet: Int) -> Task<Data?, Never> {
        if let running = downloads[sheet] { return running }
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
            let fetched = await Self.fetch(request, session: session, limit: limit) { from, to in
                !carriesHeaders && PlainHTTPRedirectGuard.allows(from: from, to: to)
            }
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

    /// Receives the body in the chunks the session delivers, on its own
    /// queue, and cancels as soon as it passes `limit`, so an oversized
    /// reply is never held whole.
    nonisolated private static func fetch(
        _ request: URLRequest,
        session: URLSession,
        limit: Int,
        allowsRedirect: @escaping @Sendable (URL?, URL?) -> Bool
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            task.delegate = SheetReceiver(limit: limit, allowsRedirect: allowsRedirect, continuation: continuation)
            task.resume()
        }
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
        if data.count > Self.dataLimit {
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

/// One sheet download. The session calls it on its delegate queue, one
/// call at a time, and it answers exactly once, when the task completes.
private final class SheetReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let allowsRedirect: @Sendable (URL?, URL?) -> Bool
    private var continuation: CheckedContinuation<Data?, Never>?
    private var body = Data()
    private var refused = false

    init(limit: Int, allowsRedirect: @escaping @Sendable (URL?, URL?) -> Bool, continuation: CheckedContinuation<Data?, Never>) {
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
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
        continuation?.resume(returning: received)
        continuation = nil
    }
}
