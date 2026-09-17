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
