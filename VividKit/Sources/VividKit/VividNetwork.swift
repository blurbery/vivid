// SPDX-License-Identifier: Apache-2.0
import Foundation
import CVividMedia

public struct VividSource: Sendable {
    public let url: URL
    public let headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
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
        if sourceFailure == .network(401) { return .network(401) }
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
    private var accepted = false
    private var complete = true
    private var failure: VividPlaybackError?
    private var stopped = false
    private var interrupted = false
    private var validator: String?
    private(set) var transferredBytes: Int64 = 0
    private var previousRequestEnd: Int64?
    private var recoveryTimes: [TimeInterval] = []

    init(_ source: VividSource, configuration suppliedConfiguration: URLSessionConfiguration? = nil) throws {
        guard ["https", "http", "file"].contains(source.url.scheme?.lowercased() ?? "") else {
            throw VividPlaybackError.invalidSource
        }
        self.source = source
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
                let retryable: Bool
                if case let .network(code) = failure {
                    retryable = [500, 502, 503, 504, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                                 NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                                 NSURLErrorNotConnectedToInternet].contains(code)
                } else { retryable = false }
                let now = ProcessInfo.processInfo.systemUptime
                recoveryTimes.removeAll { now - $0 >= 60 }
                guard retryable, recoveryTimes.count < 2 else { return -5 }
                recoveryTimes.append(now)
                self.failure = nil
                task?.cancel()
                startRequest()
            }
            if complete { startRequest() }
            condition.wait()
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
            task?.cancel()
            task = nil
            buffer.removeAll(keepingCapacity: true)
            complete = true
            failure = nil
        }
        position = target
        return target
    }

    private func startRequest() {
        buffer.removeAll(keepingCapacity: true)
        bufferStart = position
        let chunkSize: Int64 = previousRequestEnd.map { position == $0 + 1 } == true ? 8_388_608 : 1_048_576
        requestEnd = min(position + chunkSize - 1, length.map { max(0, $0 - 1) } ?? Int64.max)
        accepted = false
        complete = false
        var request = URLRequest(url: source.url)
        for (key, value) in source.headers {
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(position)-\(requestEnd)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
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
              let range = Self.parseContentRange(value), range.start == bufferStart,
              range.end <= requestEnd,
              length == nil || length == range.total,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            failure = (response as? HTTPURLResponse).map { .network($0.statusCode) } ?? .invalidRange
            condition.broadcast()
            completionHandler(.cancel)
            return
        }
        let nextValidator = http.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        if let validator, let nextValidator, validator != nextValidator {
            failure = .invalidRange
            condition.broadcast()
            completionHandler(.cancel)
            return
        }
        validator = nextValidator ?? validator
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
