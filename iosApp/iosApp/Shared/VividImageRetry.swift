import Foundation

/// Retry a transient artwork transport failure once, without retrying HTTP,
/// decoding or cancellation errors. The same policy covers Silo and Emby.
enum VividImageRetry {
    static func load<Value>(operation: () async throws -> Value) async throws -> Value {
        do { return try await operation() }
        catch {
            try Task.checkCancellation()
            let failure = error as NSError
            guard failure.domain == NSURLErrorDomain,
                  [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                   NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
                   NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost].contains(failure.code) else {
                throw error
            }
            try await Task.sleep(for: .milliseconds(500))
            try Task.checkCancellation()
            return try await operation()
        }
    }
}

/// Preserve HTTP status so temporary server failures can recover without
/// retrying missing artwork, authentication errors or rate limits.
struct VividImageHTTPError: Error {
    let statusCode: Int
}

extension VividImageRetry {
    /// Only demand-loaded views use this budget; prefetching keeps its existing
    /// single transport retry. Four load rounds allow at most eight transport
    /// attempts, or four HTTP attempts. SwiftUI cancellation cancels the backoff.
    static func recover<Value>(operation: () async throws -> Value) async throws -> Value {
        let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
        var retries = 0
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard retries < delays.count, isRecoverable(error) else { throw error }
                let delay = delays[retries]
                retries += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    static func isRecoverable(_ error: Error) -> Bool {
        if let http = error as? VividImageHTTPError {
            return [408, 500, 502, 503, 504].contains(http.statusCode)
        }
        let failure = error as NSError
        return failure.domain == NSURLErrorDomain &&
            [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost].contains(failure.code)
    }
}
