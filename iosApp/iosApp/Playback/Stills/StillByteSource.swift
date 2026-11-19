import Foundation

/// Where a still's bytes come from: a file on a server or on the device.
///
/// One thread reads at a time (the still reader's own), and blocks while it
/// does. `cancel()` and `resume()` may come from any thread.
protocol StillByteSource: AnyObject, Sendable {
    /// Copies bytes starting at `offset` into `buffer`. Returns how many
    /// were copied, which may be fewer than the buffer holds, or 0 at the
    /// end of the file.
    func read(into buffer: UnsafeMutableRawBufferPointer, offset: Int64) throws -> Int
    /// The file's length, once known.
    var size: Int64? { get }
    /// Fails the read in flight at once, and every read after it until
    /// `resume()`. Staying cancelled closes the gap where a read starts
    /// just after it was told to stop.
    func cancel()
    func resume()
    /// A keyframe of this size was just read, so later reads can fetch
    /// enough for one in a single request.
    func noteKeyframeSize(_ bytes: Int)
}

extension StillByteSource {
    func noteKeyframeSize(_ bytes: Int) {}
}

enum StillByteSourceError: Error, Equatable {
    case cancelled
    /// The server didn't honour a byte range, so the source turned itself
    /// off for good.
    case disabled
    case failed
    case invalidRequest
}

/// Reads a file on a server in bounded byte ranges.
///
/// The demuxer asks for many small pieces, so each request fetches a block
/// and recent blocks are kept. A block starts where the read starts: a
/// keyframe read begins at the keyframe and wants what follows it.
final class HTTPStillByteSource: StillByteSource, @unchecked Sendable {
    struct Counters: Equatable, Sendable {
        var requests = 0
        /// Bytes received in range replies.
        var bytes = 0
    }

    static let minimumBlockBytes = 256 * 1024
    static let maximumBlockBytes = 1024 * 1024
    private static let blockStep = 64 * 1024
    private static let cachedBlockLimit = 6
    private static let requestTimeout: TimeInterval = 10

    private let url: URL
    private let session: URLSession
    private let ownsSession: Bool
    /// Asked before every request, so a refreshed token is always used.
    private let headers: @Sendable () -> [String: String]

    private let lock = NSLock()
    /// Most recently used last.
    private var blocks: [(offset: Int64, bytes: Data)] = []
    private var totalSize: Int64?
    private var largestKeyframe = 0
    private var isCancelled = false
    private var isDisabled = false
    private var inFlight: (task: URLSessionDataTask, receiver: RangeReceiver)?
    private var counted = Counters()

    init(url: URL, session: URLSession? = nil, headers: @escaping @Sendable () -> [String: String] = { [:] }) {
        self.url = url
        self.session = session ?? Self.makeSession()
        ownsSession = session == nil
        self.headers = headers
    }

    deinit {
        if ownsSession { session.invalidateAndCancel() }
    }

    var size: Int64? { lock.withLock { totalSize } }
    var counters: Counters { lock.withLock { counted } }
    /// True once a reply showed the server doesn't serve byte ranges.
    var hasBeenDisabled: Bool { lock.withLock { isDisabled } }

    /// How much one request asks for: twice the largest keyframe seen plus
    /// a margin, in 64 KiB steps, between 256 KiB and 1 MiB.
    var blockBytes: Int {
        let largest = lock.withLock { largestKeyframe }
        guard largest > 0 else { return Self.minimumBlockBytes }
        let wanted = min(largest, Self.maximumBlockBytes) * 2 + Self.blockStep
        let stepped = (wanted + Self.blockStep - 1) / Self.blockStep * Self.blockStep
        return min(max(stepped, Self.minimumBlockBytes), Self.maximumBlockBytes)
    }

    func noteKeyframeSize(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock { largestKeyframe = max(largestKeyframe, bytes) }
    }

    func cancel() {
        let flight = lock.withLock { () -> (task: URLSessionDataTask, receiver: RangeReceiver)? in
            isCancelled = true
            return inFlight
        }
        // Wake the reader straight away instead of waiting for the session
        // to report the cancellation.
        flight?.receiver.finish(.cancelled)
        flight?.task.cancel()
    }

    func resume() {
        lock.withLock { isCancelled = false }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, offset: Int64) throws -> Int {
        guard offset >= 0, let base = buffer.baseAddress, buffer.count > 0 else { throw StillByteSourceError.invalidRequest }
        let known = try lock.withLock { () -> Int64? in
            if isDisabled { throw StillByteSourceError.disabled }
            if isCancelled { throw StillByteSourceError.cancelled }
            return totalSize
        }
        if let known, offset >= known { return 0 }
        if let copied = copyFromBlocks(to: base, count: buffer.count, offset: offset) { return copied }

        var length = Int64(blockBytes)
        if let known { length = min(length, known - offset) }
        guard length > 0, offset <= Int64.max - length else { throw StillByteSourceError.invalidRequest }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        let fields = headers()
        for (name, value) in fields { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        // A compressed reply would make the byte counts meaningless.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        // Headers carry the account's credentials, and a redirect would
        // take them to wherever the server points.
        let followsRedirects = fields.isEmpty
        let receiver = RangeReceiver(start: offset, limit: Int(length)) { from, to in
            followsRedirects && PlainHTTPRedirectGuard.allows(from: from, to: to)
        }
        let task = session.dataTask(with: request)
        task.delegate = receiver
        try lock.withLock {
            if isCancelled { throw StillByteSourceError.cancelled }
            inFlight = (task, receiver)
            counted.requests += 1
        }
        task.resume()
        let outcome = receiver.wait(seconds: Self.requestTimeout + 2)
        task.cancel()

        return try lock.withLock {
            inFlight = nil
            switch outcome {
            case .cancelled:
                throw StillByteSourceError.cancelled
            case .failed:
                throw isCancelled ? StillByteSourceError.cancelled : StillByteSourceError.failed
            case .refused:
                isDisabled = true
                blocks = []
                throw StillByteSourceError.disabled
            case let .received(bytes, total):
                if let total {
                    // A file that changes length under the reader can't be
                    // trusted with the offsets already learnt.
                    if let totalSize, totalSize != total {
                        isDisabled = true
                        blocks = []
                        throw StillByteSourceError.disabled
                    }
                    totalSize = total
                }
                counted.bytes += bytes.count
                blocks.append((offset, bytes))
                if blocks.count > Self.cachedBlockLimit { blocks.removeFirst(blocks.count - Self.cachedBlockLimit) }
                let count = min(buffer.count, bytes.count)
                bytes.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), count: count)
                return count
            }
        }
    }

    private func copyFromBlocks(to base: UnsafeMutableRawPointer, count: Int, offset: Int64) -> Int? {
        lock.withLock {
            guard let position = blocks.firstIndex(where: { offset >= $0.offset && offset < $0.offset + Int64($0.bytes.count) })
            else { return nil }
            let block = blocks.remove(at: position)
            blocks.append(block)
            let skip = Int(offset - block.offset)
            let available = min(count, block.bytes.count - skip)
            let start = block.bytes.startIndex + skip
            block.bytes.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), from: start..<(start + available))
            return available
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        // One connection: previews must never crowd the film's own reads.
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// One range request. The session calls it on its delegate queue while the
/// reader's thread waits on it, and it answers once.
private final class RangeReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome {
        case received(Data, total: Int64?)
        /// Not a proper range reply: the source turns itself off.
        case refused
        case failed
        case cancelled
    }

    private let start: Int64
    private let limit: Int
    private let allowsRedirect: @Sendable (URL?, URL?) -> Bool
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Outcome?
    private var body = Data()
    private var total: Int64?
    private var isRefused = false

    init(start: Int64, limit: Int, allowsRedirect: @escaping @Sendable (URL?, URL?) -> Bool) {
        self.start = start
        self.limit = limit
        self.allowsRedirect = allowsRedirect
    }

    /// The first answer wins. Later ones are dropped.
    func finish(_ result: Outcome) {
        let isFirst = lock.withLock { () -> Bool in
            guard outcome == nil else { return false }
            outcome = result
            return true
        }
        if isFirst { done.signal() }
    }

    func wait(seconds: TimeInterval) -> Outcome {
        _ = done.wait(timeout: .now() + seconds)
        return lock.withLock {
            let result = outcome ?? .failed
            outcome = result
            return result
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A refused redirect ends the task with the redirect reply, which
        // isn't a range reply, so the source turns itself off.
        completionHandler(allowsRedirect(response.url, request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // 200 means the server ignored the range and is sending the whole
        // file, which must never be downloaded for a preview.
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
              range.first == start, range.last - range.first < Int64(limit)
        else {
            isRefused = true
            completionHandler(.cancel)
            finish(.refused)
            return
        }
        total = range.total
        body.reserveCapacity(Int(range.last - range.first + 1))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isRefused else { return }
        body.append(data)
        if body.count > limit {
            isRefused = true
            body = Data()
            dataTask.cancel()
            finish(.refused)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if isRefused {
            finish(.refused)
        } else if error != nil || body.isEmpty {
            // A redirect that was refused completes without an error and
            // without a body reaching here: its reply was never a 206.
            finish(error == nil && (task.response as? HTTPURLResponse)?.statusCode != 206 ? .refused : .failed)
        } else {
            finish(.received(body, total: total))
        }
        body = Data()
    }

    /// Reads `bytes first-last/total`. The total may be `*`.
    static func contentRange(_ value: String?) -> (first: Int64, last: Int64, total: Int64?)? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let ends = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count == 2, let first = Int64(ends[0]), let last = Int64(ends[1]), first >= 0, last >= first else { return nil }
        if parts[1] == "*" { return (first, last, nil) }
        guard let total = Int64(parts[1]), total > last else { return nil }
        return (first, last, total)
    }
}

/// Reads a file on the device, such as a download.
final class FileStillByteSource: StillByteSource, @unchecked Sendable {
    private let descriptor: Int32
    private let length: Int64
    private let lock = NSLock()
    private var isCancelled = false

    /// Nil when the file can't be opened or isn't a regular file.
    init?(url: URL) {
        guard url.isFileURL else { return nil }
        let opened = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard opened >= 0 else { return nil }
        var status = stat()
        guard fstat(opened, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            close(opened)
            return nil
        }
        descriptor = opened
        length = Int64(status.st_size)
    }

    deinit {
        close(descriptor)
    }

    var size: Int64? { length }

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    func resume() {
        lock.withLock { isCancelled = false }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, offset: Int64) throws -> Int {
        guard offset >= 0, let base = buffer.baseAddress, buffer.count > 0 else { throw StillByteSourceError.invalidRequest }
        if lock.withLock({ isCancelled }) { throw StillByteSourceError.cancelled }
        if offset >= length { return 0 }
        let count = pread(descriptor, base, buffer.count, off_t(offset))
        guard count >= 0 else { throw StillByteSourceError.failed }
        return count
    }
}
