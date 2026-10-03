// SPDX-License-Identifier: GPL-3.0-only
// Additional permission applies to Vivid's adapter only: LICENSE-APPLE-EXCEPTION.
import Foundation
import os

/// One direct source that Vivid reads on Lucid's behalf. Lucid never holds the
/// bearer: every request takes the current headers, so a refreshed access
/// token reaches reconnects and seeks on a live stream.
final class VividManagedStreamSource: @unchecked Sendable {
    let url: URL
    /// Asks the app for refreshed headers after a 401. Returns nil when no
    /// newer credential is available.
    let refresh: @Sendable () async -> [String: String]?
    private let lock = NSLock()
    private var headers: [String: String]
    private var cancelled = false
    private var readers: [Weak] = []
    private struct Weak { weak var reader: VividManagedStreamReader? }

    init(url: URL, headers: [String: String],
         refresh: @escaping @Sendable () async -> [String: String]?) {
        self.url = url
        self.headers = headers
        self.refresh = refresh
    }

    var currentHeaders: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return headers
    }

    func update(_ headers: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        self.headers = headers
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Ends every reader of this source, including one still connecting, so
    /// a synchronous Lucid teardown never waits on the network. Never blocks.
    func cancel() {
        lock.lock()
        cancelled = true
        let active = readers.compactMap(\.reader)
        readers = []
        lock.unlock()
        for reader in active { reader.cancel() }
    }

    /// Returns false if the source has already been cancelled.
    fileprivate func attach(_ reader: VividManagedStreamReader) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        readers.removeAll { $0.reader == nil }
        readers.append(Weak(reader: reader))
        return true
    }

    /// Only HTTPS single-file sources qualify. Plain HTTP stays on Lucid's own
    /// reader, which is not subject to App Transport Security.
    static func isEligible(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }
}

/// How a ranged response may continue the byte stream that was requested.
enum VividManagedStreamResponse: Equatable {
    case bytes(total: Int64?)
    case endOfStream
    case authentication
    case transient
    case fatal(String)

    static func classify(status: Int, requestedOffset: Int64, contentRange: String?,
                         contentLength: Int64, knownTotal: Int64?) -> Self {
        switch status {
        case 206:
            guard let range = contentRange.flatMap(ContentRange.init) else {
                return .fatal("206 without a usable Content-Range")
            }
            guard range.start == requestedOffset else {
                return .fatal("206 started at \(range.start), requested \(requestedOffset)")
            }
            return consistent(total: range.total, knownTotal: knownTotal)
        case 200:
            // A full response is only a continuation from the first byte. At
            // any other offset it means the range or If-Range was refused,
            // usually because the file changed.
            guard requestedOffset == 0 else { return .fatal("200 for a ranged request") }
            return consistent(total: contentLength >= 0 ? contentLength : nil, knownTotal: knownTotal)
        case 416:
            // A stream of unknown length can be paused right at its last byte,
            // so the next range starts at the end. `bytes */N` gives the size.
            let total = knownTotal ?? contentRange.flatMap(ContentRange.unsatisfiedTotal)
            if let total, requestedOffset >= total { return .endOfStream }
            return .fatal("416 inside the stream")
        case 401, 403:
            return .authentication
        case 408, 425, 429, 500, 502, 503, 504:
            return .transient
        default:
            return .fatal("HTTP \(status)")
        }
    }

    private static func consistent(total: Int64?, knownTotal: Int64?) -> Self {
        if let total, let knownTotal, total != knownTotal {
            return .fatal("size changed from \(knownTotal) to \(total)")
        }
        return .bytes(total: total ?? knownTotal)
    }

    struct ContentRange: Equatable {
        let start: Int64
        let total: Int64?

        /// The size from a 416's `bytes */N`.
        static func unsatisfiedTotal(_ header: String) -> Int64? {
            let trimmed = header.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("bytes */"), let total = Int64(trimmed.dropFirst(8)),
                  total >= 0 else { return nil }
            return total
        }

        init?(_ header: String) {
            let trimmed = header.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
            let spec = trimmed.dropFirst(6)
            let parts = spec.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let bounds = parts[0].split(separator: "-", maxSplits: 1)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start >= 0, end >= start else { return nil }
            self.start = start
            if parts[1] == "*" {
                total = nil
            } else {
                guard let total = Int64(parts[1]), total > end else { return nil }
                self.total = total
            }
        }
    }
}

/// Bounds reconnects for one stalled read. Time resets once bytes flow again,
/// so a long film can reconnect as often as its connection drops.
struct VividManagedStreamRetryPolicy {
    var maxStallSeconds: Double = 45
    var maxAuthAttempts = 3

    func delay(forAttempt attempt: Int) -> Double {
        min(4, 0.25 * pow(2, Double(max(0, attempt - 1))))
    }
}

/// A blocking, seekable byte stream over HTTP ranges for Lucid's stream
/// callbacks. All state is guarded by `condition`; the URLSession callbacks
/// and Lucid's demux thread meet only there.
final class VividManagedStreamReader: NSObject, @unchecked Sendable {
    private enum TaskState: Equatable {
        case idle
        case connecting
        case streaming
        case ended(Outcome)
    }

    private enum Outcome: Equatable { case complete, transient, authentication, fatal }

    static let logger = Logger(subsystem: "com.blurbery.vivid", category: "ManagedStream")
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    let source: VividManagedStreamSource
    private let session: URLSession
    private let retry: VividManagedStreamRetryPolicy
    private let highWater: Int
    private let lowWater: Int
    private let refreshTimeout: Double
    private let condition = NSCondition()

    // Guarded by `condition`.
    private var position: Int64 = 0
    private var chunks: [Data] = []
    private var headOffset = 0
    private var buffered = 0
    private var task: URLSessionDataTask?
    private var generation = 0
    private var taskStart: Int64 = 0
    private var taskReceived: Int64 = 0
    private var state = TaskState.idle
    private var totalSize: Int64?
    private var validator: String?
    /// The request was ended at the high-water mark and continues from the
    /// next byte once Lucid drains the buffer.
    private var paused = false
    private var cancelled = false
    private var stallStarted: Double?
    private var transientAttempts = 0
    private var authAttempts = 0
    private var refreshInFlight = false
    private var refreshFinished = false

    private(set) var reconnectCount = 0

    init(source: VividManagedStreamSource, session: URLSession = VividManagedStreamReader.sharedSession,
         retry: VividManagedStreamRetryPolicy = VividManagedStreamRetryPolicy(),
         highWater: Int = 64 << 20, lowWater: Int = 16 << 20, refreshTimeout: Double = 15) {
        self.source = source
        self.session = session
        self.retry = retry
        self.highWater = highWater
        self.lowWater = lowWater
        self.refreshTimeout = refreshTimeout
    }

    deinit { task?.cancel() }

    // MARK: Lucid stream callbacks

    /// Connects at the first byte so the size is known before Lucid asks.
    func open(timeout: Double = 30) -> Bool {
        guard source.attach(self) else { return false }
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        startTaskLocked(at: 0)
        while !cancelled {
            if buffered > 0 { return true }
            switch state {
            case .streaming:
                return true
            case .ended(.authentication):
                // The bearer is fresh at load. A refusal here belongs to the
                // app's load-failure recovery, not a wait inside Lucid's open.
                return false
            case .ended(.transient):
                guard Date() < deadline else { return false }
                transientAttempts += 1
                condition.wait(until: min(deadline, Date().addingTimeInterval(retry.delay(forAttempt: transientAttempts))))
                startTaskLocked(at: nextFetchOffset)
            case .ended:
                return false
            case .idle, .connecting:
                guard condition.wait(until: deadline) || stateIsSettled else { return false }
            }
        }
        return false
    }

    /// Blocking read with read(2) semantics: bytes, 0 at the real end, -1 on error.
    func read(into destination: UnsafeMutableRawPointer, count: Int) -> Int64 {
        guard count > 0 else { return 0 }
        condition.lock(); defer { condition.unlock() }
        while true {
            if cancelled { return -1 }
            if buffered > 0 { return copyLocked(into: destination, count: count) }
            if let totalSize, position >= totalSize { return 0 }
            switch state {
            case .idle:
                startTaskLocked(at: nextFetchOffset)
            case .connecting, .streaming:
                condition.wait(until: Date().addingTimeInterval(1))
            case .ended(.complete):
                if let totalSize, position < totalSize {
                    // The body ended short of the advertised size.
                    state = .ended(.transient)
                } else {
                    return 0
                }
            case .ended(.fatal):
                return -1
            case .ended(.transient):
                let now = ProcessInfo.processInfo.systemUptime
                if stallStarted == nil { stallStarted = now }
                guard now - (stallStarted ?? now) < retry.maxStallSeconds else {
                    Self.logger.error("Managed stream stalled; giving up after \(self.retry.maxStallSeconds, privacy: .public)s")
                    return -1
                }
                transientAttempts += 1
                condition.wait(until: Date().addingTimeInterval(retry.delay(forAttempt: transientAttempts)))
                if cancelled { return -1 }
                reconnectCount += 1
                Self.logger.info("Managed stream reconnect offset=\(self.nextFetchOffset, privacy: .public) attempt=\(self.transientAttempts, privacy: .public)")
                startTaskLocked(at: nextFetchOffset)
            case .ended(.authentication):
                authAttempts += 1
                guard authAttempts <= retry.maxAuthAttempts else {
                    Self.logger.error("Managed stream credential refused after refresh")
                    return -1
                }
                guard refreshLocked(deadline: Date().addingTimeInterval(refreshTimeout)) else { return -1 }
                reconnectCount += 1
                Self.logger.info("Managed stream credential refreshed; resuming offset=\(self.nextFetchOffset, privacy: .public)")
                startTaskLocked(at: nextFetchOffset)
            }
        }
    }

    func seek(to offset: Int64) -> Int64? {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled, offset >= 0 else { return nil }
        if let totalSize, offset > totalSize { return nil }
        if offset == position { return offset }
        if offset > position, offset < position + Int64(buffered) {
            dropLocked(Int(offset - position))
            position = offset
            resumeIfDrainedLocked()
            return offset
        }
        cancelTaskLocked()
        clearBufferLocked()
        position = offset
        state = .idle
        stallStarted = nil
        transientAttempts = 0
        return offset
    }

    var size: Int64? {
        condition.lock(); defer { condition.unlock() }
        return totalSize
    }

    /// Bytes received and not yet read by Lucid.
    var bufferedBytes: Int {
        condition.lock(); defer { condition.unlock() }
        return buffered
    }

    /// Interrupts current and future reads. Never blocks.
    func cancel() {
        condition.lock()
        cancelled = true
        cancelTaskLocked()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Transport

    /// The first byte not yet received. Buffered bytes are never fetched twice,
    /// so a reconnect continues the stream exactly where the body stopped.
    private var nextFetchOffset: Int64 { position + Int64(buffered) }

    private var stateIsSettled: Bool {
        if case .connecting = state { return false }
        return true
    }

    private func startTaskLocked(at offset: Int64) {
        cancelTaskLocked()
        generation += 1
        var request = URLRequest(url: source.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in source.currentHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        let next = session.dataTask(with: request)
        next.delegate = TaskDelegate(reader: self, generation: generation)
        task = next
        taskStart = offset
        taskReceived = 0
        paused = false
        state = .connecting
        next.resume()
    }

    private func cancelTaskLocked() {
        generation += 1
        task?.cancel()
        task = nil
        paused = false
    }

    /// Waits, unlocked from the transport, for the app to refresh the bearer.
    /// A nil result still retries: progress may already have rotated it.
    private func refreshLocked(deadline: Date) -> Bool {
        guard !refreshInFlight else { return false }
        refreshInFlight = true
        refreshFinished = false
        let source = source
        Task.detached { [weak self] in
            let headers = await source.refresh()
            if let headers { source.update(headers) }
            guard let self else { return }
            self.condition.lock()
            self.refreshFinished = true
            self.condition.broadcast()
            self.condition.unlock()
        }
        while !refreshFinished, !cancelled {
            guard condition.wait(until: deadline) else { break }
        }
        let finished = refreshFinished
        refreshInFlight = false
        return finished && !cancelled
    }

    fileprivate func receive(response: URLResponse, generation: Int) -> URLSession.ResponseDisposition {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        guard generation == self.generation, !cancelled else { return .cancel }
        guard let http = response as? HTTPURLResponse else {
            state = .ended(.fatal)
            return .cancel
        }
        let result = VividManagedStreamResponse.classify(
            status: http.statusCode, requestedOffset: taskStart,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: http.expectedContentLength, knownTotal: totalSize)
        switch result {
        case .bytes(let total):
            // Check the entity ourselves too: a restart from the first byte
            // can legitimately get a 200, and not every origin honours If-Range.
            // Only a strong tag can become the If-Range validator, but once one
            // is stored, any later tag (weak included) must name the same file.
            let tag = http.value(forHTTPHeaderField: "ETag")
            if let validator, let tag, Self.opaqueTag(tag) != Self.opaqueTag(validator) {
                Self.logger.error("Managed stream refused: the file changed during playback")
                state = .ended(.fatal)
            } else {
                totalSize = total
                if validator == nil, let tag, !tag.hasPrefix("W/") { validator = tag }
                state = .streaming
                return .allow
            }
        case .endOfStream:
            state = .ended(.complete)
        case .authentication:
            Self.logger.warning("Managed stream HTTP \(http.statusCode, privacy: .public) at offset=\(self.taskStart, privacy: .public)")
            state = .ended(.authentication)
        case .transient:
            state = .ended(.transient)
        case .fatal(let reason):
            Self.logger.error("Managed stream refused: \(reason, privacy: .public)")
            state = .ended(.fatal)
        }
        task = nil
        return .cancel
    }

    /// A redirect to another origin is refused, and retrying the same URL would
    /// only be redirected again, so the stream fails instead of reconnecting.
    fileprivate func refuseRedirect(generation: Int) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        guard generation == self.generation else { return }
        Self.logger.error("Managed stream refused a redirect to another origin")
        state = .ended(.fatal)
        task = nil
    }

    static func opaqueTag(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("W/") ? String(trimmed.dropFirst(2)) : trimmed
    }

    fileprivate func receive(data: Data, generation: Int) {
        condition.lock(); defer { condition.unlock() }
        guard generation == self.generation, !cancelled, !data.isEmpty else { return }
        // URLSession can hand over many megabytes in one delivery when it has
        // read ahead of us, so keep only what fits; the rest is fetched again
        // with the next range.
        let kept = buffered + data.count > highWater ? data.prefix(max(highWater - buffered, 0)) : data
        if !kept.isEmpty {
            chunks.append(Data(kept))
            buffered += kept.count
            taskReceived += Int64(kept.count)
        }
        stallStarted = nil
        transientAttempts = 0
        authAttempts = 0
        if buffered >= highWater, task != nil {
            // Back-pressure: Lucid's own demux cache is the real buffer. End
            // the request rather than suspending it: URLSession keeps
            // delivering a fast transfer after suspend(), which let one
            // stream buffer gigabytes and the system close the app.
            cancelTaskLocked()
            paused = true
            state = .idle
        }
        condition.broadcast()
    }

    fileprivate func complete(error: Error?, generation: Int) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        guard generation == self.generation else { return }
        task = nil
        guard case .streaming = state else {
            if case .connecting = state { state = .ended(.transient) }
            return
        }
        if error != nil {
            state = .ended(.transient)
        } else if let totalSize, taskStart + taskReceived < totalSize {
            state = .ended(.transient)
        } else {
            state = .ended(.complete)
        }
    }

    // MARK: Buffer

    private func copyLocked(into destination: UnsafeMutableRawPointer, count: Int) -> Int64 {
        var copied = 0
        while copied < count, let head = chunks.first {
            let available = head.count - headOffset
            let take = min(available, count - copied)
            head.withUnsafeBytes { bytes in
                (destination + copied).copyMemory(from: bytes.baseAddress! + headOffset, byteCount: take)
            }
            copied += take
            headOffset += take
            if headOffset == head.count {
                chunks.removeFirst()
                headOffset = 0
            }
        }
        buffered -= copied
        position += Int64(copied)
        resumeIfDrainedLocked()
        return Int64(copied)
    }

    private func dropLocked(_ count: Int) {
        var remaining = count
        while remaining > 0, let head = chunks.first {
            let available = head.count - headOffset
            if remaining >= available {
                remaining -= available
                chunks.removeFirst()
                headOffset = 0
            } else {
                headOffset += remaining
                remaining = 0
            }
        }
        buffered -= count
    }

    private func clearBufferLocked() {
        chunks.removeAll(keepingCapacity: true)
        headOffset = 0
        buffered = 0
    }

    private func resumeIfDrainedLocked() {
        guard paused, buffered <= lowWater, !cancelled else { return }
        if let totalSize, nextFetchOffset >= totalSize {
            paused = false
            return
        }
        startTaskLocked(at: nextFetchOffset)
    }
}

private final class TaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var reader: VividManagedStreamReader?
    private let generation: Int

    init(reader: VividManagedStreamReader, generation: Int) {
        self.reader = reader
        self.generation = generation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(reader?.receive(response: response, generation: generation) ?? .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        reader?.receive(data: data, generation: generation)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        reader?.complete(error: error, generation: generation)
    }

    // Credentials travel in headers only; never follow a redirect that would
    // send them to another origin.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let sameOrigin = request.url?.scheme == original?.scheme && request.url?.host == original?.host
            && request.url?.port == original?.port
        if !sameOrigin { reader?.refuseRedirect(generation: generation) }
        completionHandler(sameOrigin ? request : nil)
    }
}
