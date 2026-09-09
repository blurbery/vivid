// SPDX-License-Identifier: Apache-2.0
import Foundation
import CVividMedia

public struct VividSource: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let recoveryBudget: VividTransientRecoveryBudget?
    public let refreshHeaders: (@Sendable () async -> [String: String]?)?
    public init(url: URL, headers: [String: String] = [:], recoveryBudget: VividTransientRecoveryBudget? = nil,
                refreshHeaders: (@Sendable () async -> [String: String]?)? = nil) {
        self.url = url
        self.headers = headers
        self.recoveryBudget = recoveryBudget
        self.refreshHeaders = refreshHeaders
    }
}

public enum VividPlaybackError: Error, Equatable {
    #if os(tvOS)
    case nativeDTSRequired(Int)
    #endif
    case invalidSource
    case cancelled
    case network(Int)
    case invalidRange
    case media(Int32)
    case unsupportedTrack
    case renderer(Int)

    static func demuxReadFailure(_ code: Int32, sourceFailure: VividPlaybackError?) -> VividPlaybackError {
        if let sourceFailure { return sourceFailure }
        return .media(code)
    }
}

final class VividNetwork: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private let source: VividSource
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var position: Int64 = 0
    private var length: Int64?
    private var buffer = Data()
    private var bufferStart: Int64 = 0
    private var requestEnd: Int64 = 0
    private var requestStart: Int64 = 0
    private var resumingRange = false
    private var lastDelivery = ProcessInfo.processInfo.systemUptime
    private var waitingForBytes = false
    private var playbackActive = false
    private var playableHeadroom: Double = 0
    private var deliveryStall = VividDeliveryStall()
    private var accepted = false
    private var complete = true
    private var failure: VividPlaybackError?
    private var stopped = false
    private var interrupted = false
    private var validator: String?
    private var recoveryValidator: VividRangeValidator?
    private(set) var transferredBytes: Int64 = 0
    private var previousRequestEnd: Int64?
    private var recoveryTimes: [TimeInterval] = []
    private var headers: [String: String]
    private var requestHeaders: [String: String] = [:]
    private var authenticationAttempted = false
    private var authenticationID: UUID?
    private var authenticationTask: Task<Void, Never>?
    private var authenticationDeadline: DispatchWorkItem?
    private let authenticationTimeout: TimeInterval

    init(_ source: VividSource, configuration suppliedConfiguration: URLSessionConfiguration? = nil,
         authenticationTimeout: TimeInterval = 6) throws {
        guard ["https", "http", "file"].contains(source.url.scheme?.lowercased() ?? "") else {
            throw VividPlaybackError.invalidSource
        }
        self.source = source
        headers = source.headers
        self.authenticationTimeout = authenticationTimeout
        super.init()
        if source.url.isFileURL {
            file = try FileHandle(forReadingFrom: source.url)
            let size = try source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            length = size.map(Int64.init)
        } else {
            let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.httpMaximumConnectionsPerHost = 1
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        }
    }

    func cancel() {
        condition.lock()
        stopped = true
        cancelAuthentication()
        task?.cancel()
        condition.broadcast()
        condition.unlock()
        session?.invalidateAndCancel()
    }

    var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return stopped || interrupted
    }
    var lastFailure: VividPlaybackError? {
        condition.lock(); defer { condition.unlock() }
        return failure
    }

    func interrupt() {
        condition.lock()
        interrupted = true
        cancelAuthentication()
        task?.cancel()
        task = nil
        complete = true
        condition.broadcast()
        condition.unlock()
    }

    func resumeReads() {
        condition.lock()
        interrupted = false
        failure = nil
        condition.broadcast()
        condition.unlock()
    }

    func read(into pointer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, !interrupted else { return vv_exit() }
        if let file {
            do {
                let data = try file.read(upToCount: count) ?? Data()
                guard !data.isEmpty else { return vv_eof() }
                data.copyBytes(to: pointer, count: data.count)
                position += Int64(data.count)
                return Int32(data.count)
            } catch { failure = .invalidSource; return -5 }
        }
        while !stopped && !interrupted {
            if let length, position >= length { return vv_eof() }
            let offset = position - bufferStart
            if offset >= 0 && offset < buffer.count {
                let size = min(count, buffer.count - Int(offset))
                buffer.withUnsafeBytes { raw in
                    pointer.update(from: raw.baseAddress!.advanced(by: Int(offset)).assumingMemoryBound(to: UInt8.self), count: size)
                }
                position += Int64(size)
                return Int32(size)
            }
            if let failure {
                if failure == .network(401), authenticationID != nil || beginAuthenticationRecovery() {
                    if authenticationID != nil { condition.wait() }
                    continue
                }
                let retryable: Bool
                if case let .network(code) = failure {
                    retryable = VividTransientRecoveryBudget.recognises(code)
                } else { retryable = false }
                let now = ProcessInfo.processInfo.systemUptime
                recoveryTimes.removeAll { now - $0 >= 60 }
                guard retryable else { return -5 }
                if let budget = source.recoveryBudget {
                    // Without an identity validator, a new range cannot be
                    // safely joined to this session's already decoded media.
                    guard length == nil || recoveryValidator != nil else { return -5 }
                    guard budget.beginNetworkRetry() else {
                        traceRecovery(failure, outcome: "network_budget_exhausted")
                        return -5
                    }
                } else {
                    guard recoveryTimes.count < 2 else { return -5 }
                }
                recoveryTimes.append(now)
                traceRecovery(failure, outcome: "network_retry")
                self.failure = nil
                task?.cancel()
                startRequest(retainingBytes: source.recoveryBudget != nil && recoveryValidator != nil
                    && bufferStart + Int64(buffer.count) <= requestEnd)
            }
            if complete { startRequest() }
            waitingForBytes = true
            condition.wait()
            waitingForBytes = false
        }
        return vv_exit()
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, !interrupted else { return Int64(vv_exit()) }
        if whence & 0x10000 != 0 {
            if let length { return length }
            if complete { startRequest() }
            while length == nil && failure == nil && !stopped && !interrupted { condition.wait() }
            return length ?? -1
        }
        let mode = whence & ~0x20000
        let base: Int64
        switch mode {
        case 0: base = 0
        case 1: base = position
        case 2:
            guard let length else { return -1 }
            base = length
        default: return -1
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0 else { return -1 }
        if let file {
            do { try file.seek(toOffset: UInt64(target)) } catch { return -1 }
        } else if target < bufferStart || target > bufferStart + Int64(buffer.count) {
            cancelAuthentication()
            task?.cancel()
            task = nil
            buffer.removeAll(keepingCapacity: true)
            complete = true
            failure = nil
        }
        position = target
        return target
    }

    func updateHeaders(_ headers: [String: String]) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, file == nil else { return false }
        self.headers = headers
        if failure == .network(401), let id = authenticationID {
            finishAuthenticationLocked(id, refreshedHeaders: nil)
        }
        return true
    }

    private static func authorization(_ headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
    }

    private func cancelAuthentication() {
        authenticationID = nil
        authenticationTask?.cancel(); authenticationTask = nil
        authenticationDeadline?.cancel(); authenticationDeadline = nil
    }

    private func beginAuthenticationRecovery() -> Bool {
        guard !stopped, !interrupted, !authenticationAttempted,
              length == nil || recoveryValidator != nil else { return false }
        let hasNewCredential = Self.authorization(headers) != nil
            && Self.authorization(headers) != Self.authorization(requestHeaders)
        guard hasNewCredential || source.refreshHeaders != nil else { return false }
        authenticationAttempted = true
        let id = UUID()
        authenticationID = id
        if hasNewCredential {
            finishAuthenticationLocked(id, refreshedHeaders: nil)
            return true
        }
        guard let refresh = source.refreshHeaders else { return false }
        traceRecovery(.network(401), outcome: "credential_refresh")
        let deadline = DispatchWorkItem { [weak self] in
            self?.finishAuthentication(id, refreshedHeaders: nil)
        }
        authenticationDeadline = deadline
        DispatchQueue.global().asyncAfter(deadline: .now() + authenticationTimeout, execute: deadline)
        authenticationTask = Task { [weak self] in
            let refreshed = await refresh()
            self?.finishAuthentication(id, refreshedHeaders: refreshed)
        }
        return true
    }

    private func finishAuthentication(_ id: UUID, refreshedHeaders: [String: String]?) {
        condition.lock(); defer { condition.unlock() }
        finishAuthenticationLocked(id, refreshedHeaders: refreshedHeaders)
    }

    private func finishAuthenticationLocked(_ id: UUID, refreshedHeaders: [String: String]?) {
        guard authenticationID == id, !stopped, !interrupted else { return }
        if Self.authorization(headers) == Self.authorization(requestHeaders), let refreshedHeaders {
            headers = refreshedHeaders
        }
        cancelAuthentication()
        guard let current = Self.authorization(headers), current != Self.authorization(requestHeaders) else {
            traceRecovery(.network(401), outcome: "credential_refresh_unavailable")
            condition.broadcast()
            return
        }
        traceRecovery(.network(401), outcome: "authenticated_resume")
        failure = nil
        task?.cancel(); task = nil
        if length != nil, bufferStart + Int64(buffer.count) > requestEnd {
            complete = true
        } else {
            startRequest(retainingBytes: length != nil)
        }
        condition.broadcast()
    }

    private func traceRecovery(_ failure: VividPlaybackError, outcome: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-VividTVProbe"), case .network(let code) = failure {
            print("[VividTVProbe] streamRecovery domain=\(code > 0 ? "HTTP" : "NSURLErrorDomain") code=\(code) outcome=\(outcome) headroom=\(playableHeadroom) stalledSeconds=\(max(0, ProcessInfo.processInfo.systemUptime - lastDelivery))")
        }
        #endif
    }

    func observeDelivery(headroom: Double, active: Bool, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        condition.lock(); defer { condition.unlock() }
        playbackActive = active && !stopped && !interrupted
        playableHeadroom = headroom.isFinite ? max(0, headroom) : 0
        guard source.recoveryBudget != nil, file == nil else { return }
        if let failure, playbackActive, resumeRetainingBytes(after: failure) { return }
        let stalled = deliveryStall.observe(headroom: playableHeadroom, uptime: uptime,
            lastDelivery: lastDelivery, eligible: playbackActive && waitingForBytes && !complete && task != nil
                && authenticationID == nil)
        if stalled { _ = resumeRetainingBytes(after: .network(NSURLErrorTimedOut)) }
    }

    private func resumeRetainingBytes(after failure: VividPlaybackError) -> Bool {
        guard playbackActive, !stopped, !interrupted,
              case .network(let code) = failure, VividTransientRecoveryBudget.recognises(code),
              recoveryValidator != nil, length != nil,
              bufferStart + Int64(buffer.count) <= requestEnd,
              let budget = source.recoveryBudget, budget.beginNetworkRetry() else { return false }
        traceRecovery(failure, outcome: "resume_missing_range")
        // Already received bytes remain available to the demuxer. The new
        // request starts after them, not at its next unread position.
        task?.cancel()
        self.failure = nil
        startRequest(retainingBytes: true)
        condition.broadcast()
        return true
    }

    private func startRequest(retainingBytes: Bool = false) {
        if !retainingBytes {
            buffer.removeAll(keepingCapacity: true)
            bufferStart = position
            let chunkSize: Int64 = previousRequestEnd.map { position == $0 + 1 } == true ? 8_388_608 : 1_048_576
            requestEnd = min(position + chunkSize - 1, length.map { max(0, $0 - 1) } ?? Int64.max)
        }
        requestStart = bufferStart + Int64(buffer.count)
        resumingRange = retainingBytes
        lastDelivery = ProcessInfo.processInfo.systemUptime
        deliveryStall = VividDeliveryStall()
        accepted = false
        complete = false
        var request = URLRequest(url: source.url)
        requestHeaders = headers
        for (key, value) in requestHeaders {
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(requestStart)-\(requestEnd)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator = retainingBytes ? recoveryValidator?.value : validator {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        task = session.dataTask(with: request)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        condition.lock(); defer { condition.unlock() }
        guard dataTask === task, !stopped else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let value = http.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.parseContentRange(value), range.start == requestStart,
              range.end <= requestEnd,
              length == nil || length == range.total,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            failure = (response as? HTTPURLResponse).map { .network($0.statusCode) } ?? .invalidRange
            if failure == .network(401) { _ = beginAuthenticationRecovery() }
            condition.broadcast()
            completionHandler(.cancel)
            return
        }
        let nextValidator = http.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        if (resumingRange && recoveryValidator?.matches(http) != true) ||
            (validator != nil && nextValidator != nil && validator != nextValidator) {
            failure = .invalidRange
            condition.broadcast()
            completionHandler(.cancel)
            return
        }
        validator = nextValidator ?? validator
        recoveryValidator = VividRangeValidator(http)
        length = range.total
        requestEnd = range.end
        accepted = true
        condition.broadcast()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard dataTask === task, !stopped, accepted else { return }
        guard buffer.count + data.count <= requestEnd - bufferStart + 1 else {
            failure = .invalidRange
            dataTask.cancel()
            condition.broadcast()
            return
        }
        buffer.append(data)
        transferredBytes += Int64(data.count)
        if !data.isEmpty {
            authenticationAttempted = false
            if resumingRange {
                traceRecovery(.network(0), outcome: "delivery_resumed")
                resumingRange = false
            }
            lastDelivery = ProcessInfo.processInfo.systemUptime
        }
        condition.broadcast()
    }

    func urlSession(_ session: URLSession, task completedTask: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock(); defer { condition.unlock() }
        guard completedTask === task else { return }
        complete = true
        if accepted && error == nil { previousRequestEnd = requestEnd }
        if !stopped && failure == nil && (error != nil || !accepted || buffer.count != requestEnd - bufferStart + 1) {
            failure = .network((error as NSError?)?.code ?? -1)
        }
        if let failure, playbackActive { _ = resumeRetainingBytes(after: failure) }
        condition.broadcast()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              url.scheme == source.url.scheme, url.host == source.url.host,
              url.port == source.url.port else { completionHandler(nil); return }
        completionHandler(request)
    }

    static func parseContentRange(_ text: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard text.hasPrefix("bytes ") else { return nil }
        func decimal(_ value: Substring) -> Int64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(value)
        }
        let parts = text.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = decimal(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = decimal(bounds[0]), let end = decimal(bounds[1]),
              start >= 0, start <= end, end < total else { return nil }
        return (start, end, total)
    }

    deinit { try? file?.close() }
}
